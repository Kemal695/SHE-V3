// =============================================================================
// SHE V3 — Offline command queue (design sheet screen 23)
// =============================================================================
// V3-MOBILE-APP §7: "Commands queued: in `pending_commands` Hive box; sent when
// reconnect. UI shows 'Queued' badge on the command."
//
// A device command issued while the app cannot reach SHE is persisted here and
// replayed the moment the live link returns, so a tap made in a dead spot is not
// silently lost. The `pending_commands` box is already opened in main(); this is
// its only user.
// =============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../features/device_detail/node_service.dart';
import '../local/local_control_service.dart';
import '../network/connectivity_provider.dart';
import '../network/ws_client.dart';

class PendingCommand {
  final String id;
  final String nodeId;
  final String deviceId;
  final Map<String, dynamic> params;

  /// Human label for the queue screen, e.g. "Kitchen light · On".
  final String label;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;

  /// The firmware's own name for the device ("Socket 5").
  ///
  /// Stored so a queued command can be replayed over LOCAL CONTROL — the board
  /// has no notion of the cloud device id. Without it, a command queued while
  /// the internet was down had to wait for the cloud even when the board was
  /// right there on the same Wi-Fi.
  final String? deviceName;

  const PendingCommand({
    required this.id,
    required this.nodeId,
    required this.deviceId,
    required this.params,
    required this.label,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
    this.deviceName,
  });

  PendingCommand copyWith({int? attempts, String? lastError}) => PendingCommand(
        id: id,
        nodeId: nodeId,
        deviceId: deviceId,
        params: params,
        label: label,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
        deviceName: deviceName,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'nodeId': nodeId,
        'deviceId': deviceId,
        'params': params,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        if (lastError != null) 'lastError': lastError,
        if (deviceName != null) 'deviceName': deviceName,
      };

  factory PendingCommand.fromJson(Map<String, dynamic> j) => PendingCommand(
        id: j['id']?.toString() ?? '',
        nodeId: j['nodeId']?.toString() ?? '',
        deviceId: j['deviceId']?.toString() ?? '',
        params: (j['params'] as Map?)?.cast<String, dynamic>() ?? const {},
        label: j['label']?.toString() ?? 'Command',
        createdAt:
            DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        lastError: j['lastError']?.toString(),
        deviceName: j['deviceName']?.toString(),
      );
}

/// Result of an attempted send.
enum SendOutcome {
  /// The server accepted it now.
  sent,

  /// The app could not reach SHE, so it was persisted for replay.
  queued,
}

final commandQueueProvider =
    NotifierProvider<CommandQueue, List<PendingCommand>>(CommandQueue.new);

class CommandQueue extends Notifier<List<PendingCommand>> {
  static const _boxName = 'pending_commands';
  static const _key = 'queue';
  bool _flushing = false;

  @override
  List<PendingCommand> build() {
    // Replay the moment the live link returns. `wsConnectedProvider` starts
    // false and flips true on the first successful handshake, so this also
    // covers a cold start while already online.
    ref.listen<bool>(wsConnectedProvider, (_, up) {
      if (up) flush();
    });
    ref.listen<ConnectivityStatus>(connectivityStatusProvider, (_, next) {
      if (next == ConnectivityStatus.online) flush();
    });
    return _read();
  }

  List<PendingCommand> _read() {
    try {
      final raw = Hive.box(_boxName).get(_key);
      if (raw is String && raw.isNotEmpty) {
        return (jsonDecode(raw) as List<dynamic>)
            .map((e) => PendingCommand.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // Corrupt/absent queue is not fatal — start empty.
    }
    return const [];
  }

  void _persist() {
    try {
      Hive.box(_boxName)
          .put(_key, jsonEncode(state.map((c) => c.toJson()).toList()));
    } catch (_) {
      // Best-effort; the in-memory queue is still correct.
    }
  }

  /// True when [deviceId] has a command waiting — drives the "Queued" badge.
  bool hasPendingFor(String deviceId) =>
      state.any((c) => c.deviceId == deviceId);

  /// Try to send now; if the app cannot reach SHE, persist it for replay.
  ///
  /// A genuine server REJECTION (HTTP response, e.g. a validation 4xx) is NOT
  /// queued — replaying it would fail forever — so it is rethrown for the caller
  /// to surface. Only transport failures (no response) are queued.
  Future<SendOutcome> sendOrQueue({
    required String nodeId,
    required String deviceId,
    required Map<String, dynamic> params,
    required String label,
    String? deviceName,
  }) async {
    final svc = ref.read(localControlServiceProvider);
    final canTryLocal =
        deviceName != null && deviceName.isNotEmpty && svc.isConfigured;

    // Remembered so the offline branch below does NOT hit the board a second
    // time in the same call. Two back-to-back attempts (each with its own
    // internal retry) is exactly what makes the R24 answer "Connection reset by
    // peer": it has a tiny socket pool and does a full TLS handshake per
    // connection. One attempt per tap, then queue.
    var triedLocal = false;

    // ---- LOCAL FIRST (transparent) -------------------------------------------
    // When the board has JUST answered a request, drive it directly even though
    // the cloud is up. This is what makes local and cloud control feel like one
    // app: same page, same card, and the switch simply works — no mode, no
    // notice. `reachableRecently` is the guard that keeps this cheap: on a phone
    // that is not on the board's Wi-Fi we skip straight to the cloud instead of
    // burning a connect timeout on every tap.
    if (canTryLocal && svc.reachableRecently) {
      triedLocal = true;
      final ok = await svc.sendCommand(
        deviceName: deviceName,
        params: params,
      );
      if (ok) {
        _mirrorLocal(deviceId, params, deviceName);
        return SendOutcome.sent;
      }
      // The board dropped between polls — fall through to the cloud path below.
    }

    // Offline short-circuit: if the live link is down, queue IMMEDIATELY instead
    // of firing a request that can only time out. Against a dead host the TCP
    // connect takes ~30 s before it errors (the firewall drops the SYN rather
    // than refusing), so without this the user stares at a spinner and then gets
    // "The server took too long to respond." The queue replays on reconnect.
    if (!ref.read(wsConnectedProvider)) {
      // Before giving up, try LOCAL CONTROL: talking straight to the board over
      // Wi-Fi actually switches the device, which is the whole point of offline.
      // [deviceName] is the firmware's role name ("Socket 5") — the board has no
      // notion of the cloud device id. Skipped when the local-first branch above
      // already tried and failed.
      if (canTryLocal && !triedLocal) {
        final ok = await svc.sendCommand(
          deviceName: deviceName,
          params: params,
        );
        if (ok) {
          _mirrorLocal(deviceId, params, deviceName);
          return SendOutcome.sent;
        }
      }
      _enqueue(nodeId, deviceId, params, label, deviceName);
      return SendOutcome.queued;
    }

    try {
      await ref.read(nodeServiceProvider).writeParams(nodeId, deviceId, params);
      return SendOutcome.sent;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.badResponse) rethrow;
      _enqueue(nodeId, deviceId, params, label, deviceName);
      return SendOutcome.queued;
    } catch (_) {
      _enqueue(nodeId, deviceId, params, label, deviceName);
      return SendOutcome.queued;
    }
  }

  /// Show the command now, then settle onto the board's feedback.
  ///
  /// Mirror ONLINE exactly — there it is a TWO-STAGE sequence:
  ///
  ///   1. the board writes `last_value = <command>` and publishes it, so the
  ///      switch moves onto the command straight away;
  ///   2. the input monitor's 1 s poll then reads the LAMP-SIDE AC sense and
  ///      rewrites `last_value`, so the switch SETTLES onto what the lamp
  ///      actually did — a light that never lit falls back to OFF.
  ///
  /// ⚠️ Reading `/she/info` immediately returns stage 1 (the command), which is
  /// exactly why the offline switch looked like it ignored the feedback circuit.
  /// So: show the command now, then settle after a full feedback cycle. A SOCKET
  /// has no feedback circuit, so stage 2 returns the same value and nothing
  /// appears to change.
  void _mirrorLocal(
    String deviceId,
    Map<String, dynamic> params,
    String deviceName,
  ) {
    final power = params['Power'];
    if (power is bool) {
      ref.read(livePowerProvider.notifier).set(deviceId, power);
    }
    _settleOnFeedback(deviceName, deviceId);
  }

  /// Settle the switches onto the board's FEEDBACK values after local sends.
  ///
  /// Deliberately waits PAST one input-monitor cycle (1 s): the firmware writes
  /// the COMMANDED value into `last_value` first and only then does the AC-sense
  /// poll correct it, so an immediate read returns the command rather than what
  /// the lamp did.
  ///
  /// BATCHED on purpose. A voice scene ("good night") sends one command per
  /// device; doing one read-back each meant a 10-device scene made 20 board
  /// requests, and the R24 resets under that churn — which is what surfaced as
  /// "Queued — local control failed: Connection reset by peer". One `/she/info`
  /// now settles the whole batch, and the timer is debounced so it runs once
  /// after the scene has finished sending.
  final Map<String, String> _settlePending = {};
  Timer? _settleTimer;

  void _settleOnFeedback(String deviceName, String deviceId) {
    _settlePending[deviceId] = deviceName;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 1600), () {
      final batch = Map<String, String>.from(_settlePending);
      _settlePending.clear();
      unawaited(_settleBatch(batch));
    });
  }

  Future<void> _settleBatch(Map<String, String> batch) async {
    final byName = await ref.read(localControlServiceProvider).readAllPower();
    if (byName == null || byName.isEmpty) return;
    final notifier = ref.read(livePowerProvider.notifier);
    for (final entry in batch.entries) {
      final reported = byName[entry.value];
      if (reported != null) notifier.set(entry.key, reported);
    }
  }

  void _enqueue(String nodeId, String deviceId, Map<String, dynamic> params,
      String label, String? deviceName) {
    // Collapse repeats for the same device: the newest intent wins, so a user
    // toggling on/off/on while offline does not replay three commands.
    final rest = state.where((c) => c.deviceId != deviceId).toList();
    state = [
      ...rest,
      PendingCommand(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        nodeId: nodeId,
        deviceId: deviceId,
        params: params,
        label: label,
        createdAt: DateTime.now(),
        deviceName: deviceName,
      ),
    ];
    _persist();
  }

  void remove(String id) {
    state = state.where((c) => c.id != id).toList();
    _persist();
  }

  void clear() {
    state = const [];
    _persist();
  }

  /// Replay every queued command. Successes are dropped; failures stay (with an
  /// incremented attempt count) for the next reconnect. Re-entrancy guarded so
  /// the two connectivity listeners cannot double-send.
  Future<void> flush() async {
    if (_flushing || state.isEmpty) return;
    _flushing = true;
    try {
      final pending = [...state];
      final remaining = <PendingCommand>[];
      final service = ref.read(nodeServiceProvider);
      final svc = ref.read(localControlServiceProvider);
      for (final c in pending) {
        // LOCAL FIRST here too. A command queued because the internet was down
        // must NOT wait for the cloud when the board is reachable on the same
        // Wi-Fi — that is the whole point of the queue.
        final name = c.deviceName;
        if (name != null &&
            name.isNotEmpty &&
            svc.isConfigured &&
            svc.reachableRecently) {
          final ok = await svc.sendCommand(deviceName: name, params: c.params);
          if (ok) {
            _mirrorLocal(c.deviceId, c.params, name);
            continue; // applied — drop it from the queue
          }
        }
        try {
          await service.writeParams(c.nodeId, c.deviceId, c.params);
        } catch (e) {
          remaining.add(
              c.copyWith(attempts: c.attempts + 1, lastError: e.toString()));
        }
      }
      state = remaining;
      _persist();
    } finally {
      _flushing = false;
    }
  }
}
