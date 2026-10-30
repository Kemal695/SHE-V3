// =============================================================================
// SHE V3 — Local control (offline device control over Wi-Fi)
// =============================================================================
// V3-FIRMWARE §7 / V3-MOBILE-APP §7 "Local control fallback". When the cloud is
// unreachable the app talks DIRECTLY to the ESP32 over the LAN, so a device can
// actually be operated with the internet down — the one thing queueing cannot do.
//
// The board already advertises this (firmware/v3/main/local_ctrl.c):
//   mDNS : _she_ctrl._tcp on port 443 (per-device self-signed cert)
//   GET  /she/info  -> {node_id, sku, devices:[{name,type,channel,params:[…]}]}
//   POST /she/ctrl  -> {"device_name":"Socket 5","params":{"Power":true}}
//                      -> {"accepted":true,"device":"Socket 5","applied":1}
//   Auth : header X-SHE-PoP = the 9-digit factory PoP (constant-time on-device)
//
// NOTE the board addresses a device by its FIRMWARE NAME ("Socket 5"), NOT by the
// cloud device id — callers must pass `deviceName` (the server's `device_name`,
// i.e. the stable role name, never the user's rename).
// =============================================================================

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../storage/settings_store.dart';

final localControlServiceProvider =
    Provider<LocalControlService>((ref) => LocalControlService(ref));

class LocalControlService {
  final Ref ref;
  LocalControlService(this.ref);

  static const String _serviceType = '_she_ctrl._tcp.local';
  static const int _defaultPort = 443;
  static const Duration _discoveryTimeout = Duration(seconds: 4);
  static const Duration _hostTtl = Duration(seconds: 45);

  String? _host;
  int _port = _defaultPort;

  /// When the expensive discovery path (mDNS + LAN sweep) last ran.
  ///
  /// The Devices tab polls every 20 s, and each poll calls [discoverHost]. When
  /// the board is simply off, running a 4 s mDNS lookup plus a 5 s subnet sweep
  /// on EVERY poll would thrash the network and stall the UI. One attempt a
  /// minute is plenty — a board that comes back is picked up within that window.
  DateTime? _lastDeepDiscoverAt;
  static const Duration _deepDiscoverCooldown = Duration(seconds: 60);
  DateTime? _hostAt;

  /// Local control can only be attempted once a PoP has been entered.
  bool get isConfigured => SettingsStore.localPop.isNotEmpty;

  /// When the board last answered. Lets a caller decide whether to try local
  /// FIRST: on a phone that is NOT on the board's Wi-Fi, attempting local before
  /// the cloud would burn the full connect timeout on every single toggle. With
  /// this flag the app only goes local when the board has just proved it is
  /// there — which is what makes the switch feel instant and invisible.
  DateTime? _lastOkAt;

  static const Duration _reachableTtl = Duration(seconds: 45);

  bool get reachableRecently =>
      _lastOkAt != null &&
      DateTime.now().difference(_lastOkAt!) < _reachableTtl;

  void _markOk() => _lastOkAt = DateTime.now();

  void _markDown() {
    _lastOkAt = null;
    // Also drop the cached address so the NEXT discoverHost re-probes instead of
    // handing back a host we already know is dead for another 45 s.
    _hostAt = null;
  }

  // ---- Request serialisation ------------------------------------------------
  // The R24 has a tiny socket pool and performs a full TLS handshake per
  // connection. Two overlapping requests — a 20 s poll landing on a command, or
  // two quick taps — make it answer `Connection reset by peer` (errno 104), which
  // is exactly what the user saw on the Devices page: every toggle queued with
  // "local control failed".
  //
  // Everything now goes through ONE queue, so the board only ever sees a single
  // request at a time. The cost is that a burst of taps is applied serially; the
  // benefit is that they are applied at all.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() op) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    // A short gap before the next request. The board closes each connection and
    // needs a moment to free the socket; firing the next handshake immediately
    // is what produces errno 104 under a burst (e.g. a multi-device voice scene).
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      return await op();
    } finally {
      done.complete();
    }
  }

  /// Discover the board's LAN address, cached briefly. Returns null when no board
  /// answers — not on the same Wi-Fi, or mDNS disabled in the firmware build.
  Future<String?> discoverHost({bool force = false}) async {
    if (!isConfigured) return null;

    final manual = SettingsStore.localHost.trim();
    final cacheFresh = !force &&
        _host != null &&
        _hostAt != null &&
        DateTime.now().difference(_hostAt!) < _hostTtl;

    // 1. The saved address, but VERIFIED. The board takes a new DHCP lease on
    //    every reboot — it has been .20, .22 and .24 within a single day — and
    //    the old code returned the saved value unconditionally, so one reboot
    //    stranded local control until somebody re-typed the IP by hand.
    if (manual.isNotEmpty) {
      if (cacheFresh && _host == manual) return manual;
      if (await _tcpProbe(manual, port: _defaultPort)) {
        _host = manual;
        _hostAt = DateTime.now();
        return manual;
      }
      // Saved address is dead — fall through and go looking for the board.
    } else if (cacheFresh) {
      return _host;
    }

    // Rate-limit the expensive path so a powered-off board cannot make every
    // poll pay for an mDNS lookup plus a subnet sweep.
    if (_lastDeepDiscoverAt != null &&
        DateTime.now().difference(_lastDeepDiscoverAt!) < _deepDiscoverCooldown) {
      return null;
    }
    _lastDeepDiscoverAt = DateTime.now();

    // 2. mDNS, when the firmware advertises `_she_ctrl._tcp`.
    final mdns = await _discoverMdns();
    if (mdns != null) {
      await _remember(mdns.host, mdns.port);
      return mdns.host;
    }

    // 3. Last resort: sweep this /24 for the board. Reached only when the saved
    //    address is dead AND mDNS found nothing — i.e. exactly after a DHCP move.
    //
    // Drop our own pooled socket first: the board serves ONE client at a time, so
    // a connection we are still holding would make the sweep's verification
    // request to the board time out and the board would never be found.
    _resetClient();
    final scanned = await _scanLan();
    if (scanned != null) {
      await _remember(scanned, _defaultPort);
      // The caller fires its real request immediately, and the board serves one
      // client at a time — let it drop the verification socket first.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return scanned;
    }

    _host = null;
    _hostAt = null;
    return null;
  }

  /// Cheap liveness check: can we open a TCP connection to [host]?
  ///
  /// Deliberately NOT a full `/she/info` — this runs before discovery and a TLS
  /// handshake on this board costs ~1 s. The request that follows validates.
  Future<bool> _tcpProbe(String host, {int? port}) async {
    try {
      final socket = await Socket.connect(
        host,
        port ?? _port,
        timeout: const Duration(milliseconds: 800),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Remember a discovered address AND persist it, so the next launch is instant
  /// and the Board settings card shows the address that actually works.
  Future<void> _remember(String host, int port) async {
    _host = host;
    _port = port;
    _hostAt = DateTime.now();
    if (SettingsStore.localHost.trim() != host) {
      await SettingsStore.setLocalHost(host);
    }
  }

  /// mDNS lookup for `_she_ctrl._tcp`.
  Future<({String host, int port})?> _discoverMdns() async {
    MDnsClient? client;
    try {
      client = MDnsClient();
      await client.start();

      String? ip;
      var port = _defaultPort;

      await for (final ptr in client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(_serviceType))
          .timeout(_discoveryTimeout)) {
        await for (final srv in client
            .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
            .timeout(_discoveryTimeout)) {
          port = srv.port == 0 ? _defaultPort : srv.port;
          await for (final addr in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target)).timeout(_discoveryTimeout)) {
            ip = addr.address.address;
            break;
          }
          if (ip != null) break;
        }
        if (ip != null) break;
      }

      return ip == null ? null : (host: ip, port: port);
    } catch (_) {
      return null;
    } finally {
      client?.stop();
    }
  }

  /// Sweep the phone's own /24 for a host that answers `/she/info` as a SHE node.
  ///
  /// A home LAN is small, so a 254-host sweep with a 48-way parallel batch and an
  /// 800 ms connect timeout finishes in a few seconds. Only hosts with 443 open
  /// get the real (PoP-authenticated) check, so at most a handful of TLS
  /// handshakes are ever made.
  Future<String?> _scanLan() async {
    final subnets = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
          }
        }
      }
    } catch (_) {
      return null;
    }

    for (final net in subnets) {
      const batch = 48;
      for (var start = 1; start <= 254; start += batch) {
        final open = <String>[];
        final probes = <Future<void>>[];
        for (var i = start; i < start + batch && i <= 254; i++) {
          final host = '$net.$i';
          probes.add(
            _tcpProbe(host, port: _defaultPort)
                .then((ok) { if (ok) open.add(host); }),
          );
        }
        await Future.wait(probes);
        for (final host in open) {
          if (await _isOurBoard(host)) return host;
        }
      }
    }
    return null;
  }

  /// Is [host] a SHE board that accepts our PoP?
  Future<bool> _isOurBoard(String host) async {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://$host:$_defaultPort',
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 3),
      headers: {'X-SHE-PoP': SettingsStore.localPop},
      validateStatus: (_) => true,
    ));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..badCertificateCallback = (_, __, ___) => true,
    );
    try {
      final res = await dio.get<dynamic>('/she/info');
      final data = res.data;
      return data is Map && data['node_id'] != null;
    } catch (_) {
      return false;
    } finally {
      // MUST close: the board serves ONE client at a time, so leaving this
      // keep-alive socket open makes the request that follows the sweep fail
      // with "answered but did not return its device list".
      dio.close(force: true);
    }
  }

  /// One pooled client per board.
  ///
  /// The board's httpd has a very small socket pool and performs a full TLS
  /// handshake per connection, so opening a NEW client for every command (which
  /// this used to do) churns connections until the device starts answering with
  /// `Connection reset by peer` (errno 104). Reusing a single client keeps one
  /// warm session and lets idle sockets lapse on their own.
  Dio? _dio;

  Dio _client(String host) {
    final baseUrl = 'https://$host:$_port';
    final existing = _dio;
    if (existing != null && existing.options.baseUrl == baseUrl) return existing;

    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 6),
      sendTimeout: const Duration(seconds: 6),
      headers: {'X-SHE-PoP': SettingsStore.localPop},
    ));
    // The board serves a per-device SELF-SIGNED cert, so validation is disabled
    // for this LAN-only client. The real gate is the PoP header, which the device
    // verifies constant-time — a wrong PoP still gets a 401.
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final c = HttpClient();
        c.badCertificateCallback = (cert, host, port) => true;
        // Never hold more than one socket to the board, and let it lapse quickly
        // so a connection the board has already dropped is never reused.
        c.maxConnectionsPerHost = 1;
        c.idleTimeout = const Duration(seconds: 5);
        c.connectionTimeout = const Duration(seconds: 4);
        return c;
      },
    );
    _dio = dio;
    return dio;
  }

  /// Drop the pooled client (and with it the warm socket) so the next attempt
  /// starts from a clean TLS handshake.
  void _resetClient() {
    final old = _dio;
    _dio = null;
    old?.close(force: true);
  }

  /// Why the last [sendCommand] failed, for surfacing to the user. Local control
  /// fails SILENTLY by design (it must never break a toggle), which made "the
  /// command queued instead of switching" impossible to diagnose from outside.
  String? lastError;

  /// Ask the board to apply [params] to the device whose firmware name is
  /// [deviceName]. Returns true ONLY when the board confirms it drove the
  /// hardware — anything else (no board, timeout, 401 wrong PoP, unknown device)
  /// returns false so the caller can fall back to the queue.
  Future<bool> sendCommand({
    required String deviceName,
    required Map<String, dynamic> params,
  }) =>
      _serial(() => _sendCommand(deviceName: deviceName, params: params));

  Future<bool> _sendCommand({
    required String deviceName,
    required Map<String, dynamic> params,
  }) async {
    lastError = null;
    if (!isConfigured) {
      lastError = 'no PoP set';
      return false;
    }
    if (deviceName.isEmpty) {
      lastError = 'no firmware name for this device';
      return false;
    }
    final host = await discoverHost();
    if (host == null) {
      lastError = 'board not found';
      return false;
    }

    // The board intermittently answers with `Connection reset by peer` — its
    // httpd has a tiny socket pool and mbedTLS heap is tight — so one retry on a
    // FRESH connection turns an intermittent failure into a reliable one.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _client(host).post<dynamic>('/she/ctrl', data: {
          'device_name': deviceName,
          'params': params,
        });
        final data = res.data;
        if (data is Map && data['accepted'] == true) {
          _markOk();
          return true;
        }
        // A real answer from the board (401 wrong PoP / 404 unknown device) will
        // not change on a retry, so surface it and stop.
        lastError = 'board rejected it (${res.statusCode})';
        return false;
      } catch (e) {
        lastError = '$host: $e';
        _resetClient();
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    // Both attempts failed on the transport. Forget the host so the next command
    // re-discovers rather than hammering a stale address.
    _host = null;
    _hostAt = null;
    _markDown();
    return false;
  }

  /// The board-reported Power from the most recent [readReportedPower] — i.e. the
  /// FEEDBACK value, which can legitimately differ from what was commanded.
  bool? lastReportedPower;

  /// Read a device's board-REPORTED Power — the FEEDBACK value, not the command.
  ///
  /// `/she/info` returns the firmware's `last_value`, which the input monitor
  /// updates from the LAMP-SIDE AC SENSE. Online, the switch only ever moves on
  /// that value, so local control must read it back too: driving the switch from
  /// the command would claim a state the feedback circuit never confirmed — a
  /// lamp with a dead bulb (or no load on a bench board) closes the relay but
  /// still reports OFF.
  Future<bool?> readReportedPower(String deviceName) async {
    lastReportedPower = null;
    final d = await _deviceEntry(deviceName);
    if (d == null) return null;
    final params = d['params'];
    if (params is! List) return null;
    for (final p in params) {
      if (p is! Map || p['name']?.toString() != 'Power') continue;
      final v = p['value'];
      if (v is bool) {
        lastReportedPower = v;
        return v;
      }
    }
    return null;
  }

  /// Every device's board-REPORTED Power from ONE `/she/info` call, keyed by
  /// firmware name.
  ///
  /// Used by the offline Devices tab to reflect a PHYSICAL wall-switch flip:
  /// offline there is no push channel, so without polling the app would only ever
  /// learn state from its own command feedback.
  Future<Map<String, bool>?> readAllPower() => _serial(_readAllPower);

  Future<Map<String, bool>?> _readAllPower() async {
    if (!isConfigured) return null;
    final host = await discoverHost();
    if (host == null) return null;
    try {
      final res = await _client(host).get<dynamic>('/she/info');
      final data = res.data;
      if (data is! Map) return null;
      final devices = data['devices'];
      if (devices is! List) return null;
      final out = <String, bool>{};
      for (final d in devices) {
        if (d is! Map) continue;
        final name = d['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final params = d['params'];
        if (params is! List) continue;
        for (final p in params) {
          if (p is Map &&
              p['name']?.toString() == 'Power' &&
              p['value'] is bool) {
            out[name] = p['value'] as bool;
            break;
          }
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// The board's full `/she/info` payload, or null when it cannot be reached.
  ///
  /// Local-first mode needs the WHOLE device list (names, types, channels and
  /// every param), not just Power. While the backend is down `/she/info` is the
  /// only source for that, so it is exposed here rather than re-implemented in
  /// the screen.
  Future<Map<String, dynamic>?> readInfo() => _serial(_readInfo);

  Future<Map<String, dynamic>?> _readInfo() async {
    if (!isConfigured) return null;
    final host = await discoverHost();
    if (host == null) return null;
    try {
      final res = await _client(host).get<dynamic>('/she/info');
      final data = res.data;
      if (data is! Map) return null;
      _markOk();
      return data.cast<String, dynamic>();
    } catch (_) {
      _markDown();
      return null;
    }
  }

  /// Every device the board knows about, in firmware order.
  ///
  /// This is the offline equivalent of the backend's device list: same device
  /// NAMES the board addresses, but no cloud ids, rooms or renames.
  Future<List<Map<String, dynamic>>?> listDevices() async {
    final info = await readInfo();
    if (info == null) return null;
    final devices = info['devices'];
    if (devices is! List) return null;
    return [
      for (final d in devices)
        if (d is Map) d.cast<String, dynamic>(),
    ];
  }

  /// One device's entry from `/she/info`, or null when it is not on this board.
  Future<Map<String, dynamic>?> _deviceEntry(String deviceName) =>
      _serial(() => _deviceEntryUnlocked(deviceName));

  Future<Map<String, dynamic>?> _deviceEntryUnlocked(String deviceName) async {
    if (!isConfigured || deviceName.isEmpty) return null;
    final host = await discoverHost();
    if (host == null) return null;
    try {
      final res = await _client(host).get<dynamic>('/she/info');
      final data = res.data;
      if (data is! Map) return null;
      final devices = data['devices'];
      if (devices is! List) return null;
      for (final d in devices) {
        if (d is Map && d['name']?.toString() == deviceName) {
          return d.cast<String, dynamic>();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The board's RELAY CHANNEL for a device, which is what a local schedule
  /// addresses. Null when the board is unreachable or does not know the device.
  Future<int?> deviceChannel(String deviceName) async {
    final d = await _deviceEntry(deviceName);
    final ch = d?['channel'];
    return ch is num ? ch.toInt() : null;
  }

  // ---- Device-local schedules (offline automations) -------------------------
  //
  // The board runs time-based schedules with no cloud at all (firmware
  // schedule_store.c). These expose that store so the app can create one while
  // offline; the automation is then synced to the cloud when the link returns.
  // The firmware dedups on content, so a later cloud push converges on one slot.

  /// GET /she/schedule → the board's schedules (each with its slot `index`).
  Future<List<Map<String, dynamic>>?> listSchedules() async {
    if (!isConfigured) return null;
    final host = await discoverHost();
    if (host == null) return null;
    try {
      final res = await _client(host).get<dynamic>('/she/schedule');
      final data = res.data;
      if (data is! Map) return null;
      final list = data['schedules'];
      if (list is! List) return null;
      return [
        for (final s in list)
          if (s is Map) s.cast<String, dynamic>(),
      ];
    } catch (_) {
      return null;
    }
  }

  /// POST /she/schedule. Returns the slot index, or null on failure (board
  /// unreachable, list full, or rejected).
  ///
  /// [daysMask] bit0 = Sunday … bit6 = Saturday; 0x7F = daily; 0 = one-shot.
  /// [relay] is the CHANNEL index from [deviceChannel].
  Future<int?> addSchedule({
    required int hour,
    required int minute,
    required int daysMask,
    required int relay,
    required bool on,
  }) async {
    lastError = null;
    if (!isConfigured) {
      lastError = 'no PoP set';
      return null;
    }
    final host = await discoverHost();
    if (host == null) {
      lastError = 'board not found';
      return null;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _client(host).post<dynamic>('/she/schedule', data: {
          'hour': hour,
          'minute': minute,
          'days_mask': daysMask,
          'relay': relay,
          'action': on ? 1 : 0,
        });
        final data = res.data;
        if (data is Map && data['accepted'] == true) {
          final idx = data['index'];
          return idx is num ? idx.toInt() : -1;
        }
        lastError = 'board rejected the schedule (${res.statusCode})';
        return null;
      } catch (e) {
        lastError = '$host: $e';
        _resetClient();
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    return null;
  }

  /// POST /she/schedule/remove — frees the slot at [index].
  Future<bool> removeSchedule(int index) async {
    if (!isConfigured) return false;
    final host = await discoverHost();
    if (host == null) return false;
    try {
      final res = await _client(host)
          .post<dynamic>('/she/schedule/remove', data: {'index': index});
      final data = res.data;
      return data is Map && data['removed'] == true;
    } catch (_) {
      return false;
    }
  }
}
