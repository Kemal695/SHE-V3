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
  DateTime? _hostAt;

  /// Local control can only be attempted once a PoP has been entered.
  bool get isConfigured => SettingsStore.localPop.isNotEmpty;

  /// Discover the board's LAN address, cached briefly. Returns null when no board
  /// answers — not on the same Wi-Fi, or mDNS disabled in the firmware build.
  Future<String?> discoverHost({bool force = false}) async {
    if (!isConfigured) return null;

    // A manually-entered board address wins outright: it is the ONLY path when
    // the firmware's mDNS advertisement is unavailable (the shipped firmware has
    // the mDNS component disabled, so `_she_ctrl._tcp` is never published — the
    // HTTPS server still runs, the board just does not announce itself).
    final manual = SettingsStore.localHost.trim();
    if (manual.isNotEmpty) {
      _host = manual;
      _hostAt = DateTime.now();
      return manual;
    }

    if (!force &&
        _host != null &&
        _hostAt != null &&
        DateTime.now().difference(_hostAt!) < _hostTtl) {
      return _host;
    }

    MDnsClient? client;
    try {
      client = MDnsClient();
      await client.start();

      String? ip;
      int port = _defaultPort;

      await for (final ptr in client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(_serviceType))
          .timeout(_discoveryTimeout)) {
        await for (final srv in client
            .lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(ptr.domainName))
            .timeout(_discoveryTimeout)) {
          port = srv.port == 0 ? _defaultPort : srv.port;
          await for (final addr in client
              .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(_discoveryTimeout)) {
            ip = addr.address.address;
            break;
          }
          if (ip != null) break;
        }
        if (ip != null) break;
      }

      _host = ip;
      _port = port;
      _hostAt = ip == null ? null : DateTime.now();
      return ip;
    } catch (_) {
      return null;
    } finally {
      client?.stop();
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
        if (data is Map && data['accepted'] == true) return true;
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
  Future<Map<String, bool>?> readAllPower() async {
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

  /// One device's entry from `/she/info`, or null when it is not on this board.
  Future<Map<String, dynamic>?> _deviceEntry(String deviceName) async {
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
