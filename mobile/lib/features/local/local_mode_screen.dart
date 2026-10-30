// =============================================================================
// SHE V3 — Local mode (local-first control, RainMaker-style)
// =============================================================================
// WHY THIS EXISTS
// --------------
// The app used to be unusable without the backend: the router guard sends every
// route except /login to /login when there is no access token, and logging in
// needs the server. So if the backend was down (or the phone was on a LAN with
// no internet), the user could not even reach the local-control client that
// already existed in `LocalControlService` — the one thing that DOES work with
// no cloud at all.
//
// This screen is the local-first path, modelled on ESP RainMaker: the phone
// talks straight to the node on the LAN, discovers it over mDNS (or a manually
// entered IP), lists its devices and drives them. No account, no token, no
// backend.
//
// WHAT IT CAN DO WITHOUT A CLOUD
//   GET  /she/info   -> device names, types, channels and live params
//   POST /she/ctrl   -> {"device_name":"Light 3","params":{"Power":true}}
//   Auth             -> X-SHE-PoP, the 9-digit PoP from the device label
//
// DELIBERATE LIMITS (v1)
//   * State is TWO-STAGE, mirroring the firmware: the command is shown first
//     (the board writes `last_value = command`), then the switch settles onto
//     the AC-sense FEEDBACK ~1.6 s later. A relay that closed with no load
//     therefore falls back to OFF, and the screen says so instead of claiming
//     the circuit is live.
//   * No rooms/renames/history: those live in the backend. Devices are shown by
//     their FIRMWARE names, which is exactly how the board addresses them.
//   * Board-side schedules exist in the service but are not surfaced here yet.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/local/local_control_service.dart';
import '../../core/network/device_kind.dart' show kindFromDeviceType;
import '../../core/storage/settings_store.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart' show SHEFilterChip;
// The Devices tab's own card + row, so local mode renders the SAME card instead
// of a parallel design. See the typedef comment in devices_screen.dart.
import '../devices/devices_screen.dart' show DeviceRow, DeviceTile;

/// Unit + label for the read-only sensor params the firmware publishes.
const Map<String, String> _sensorUnits = {
  'Temperature': '°C',
  'Humidity': '%',
  'Soil_Moisture': '%',
  'CO': 'ppm',
  'Alcohol': 'ppm',
  'CO2': 'ppm',
};

class LocalModeScreen extends ConsumerStatefulWidget {
  const LocalModeScreen({super.key});

  @override
  ConsumerState<LocalModeScreen> createState() => _LocalModeScreenState();
}

class _LocalModeScreenState extends ConsumerState<LocalModeScreen> {
  final _popCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();

  bool _loading = true;
  bool _showSetup = false;
  String? _error;
  String? _host;
  String? _sku;

  /// The board's node id from `/she/info` — carried into each [DeviceRow] so the
  /// shared card has a non-empty node like its cloud counterpart.
  String _nodeId = '';
  List<Map<String, dynamic>> _devices = const [];

  /// Board-REPORTED Power, keyed by firmware device name.
  final Map<String, bool> _power = {};

  /// Devices with a command in flight — their toggle is disabled so a second
  /// tap cannot race the first one.
  final Set<String> _busy = {};

  /// A background poll is in flight; used to stop ticks stacking up on a board
  /// that is answering slowly.
  bool _polling = false;

  /// Which device category is showing — same chip set as the Devices tab so the
  /// two pages read identically.
  String _filter = 'all';

  Timer? _poll;

  LocalControlService get _svc => ref.read(localControlServiceProvider);

  @override
  void initState() {
    super.initState();
    _popCtrl.text = SettingsStore.localPop;
    _hostCtrl.text = SettingsStore.localHost;
    // First run: no PoP means local control cannot authenticate at all, so open
    // the setup form instead of showing a board-not-found error the user cannot
    // act on.
    _showSetup = SettingsStore.localPop.isEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _popCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  /// Fetch the board's device list.
  ///
  /// [quiet] skips the spinner — used by the poll so the list does not flicker
  /// every few seconds. [discover] forces a fresh mDNS lookup (the cached host
  /// expires after 45 s, but a DHCP change needs an explicit retry).
  Future<void> _load({bool quiet = false, bool discover = false}) async {
    if (!mounted) return;
    if (SettingsStore.localPop.isEmpty) {
      setState(() {
        _loading = false;
        _showSetup = true;
      });
      return;
    }

    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final host = await _svc.discoverHost(force: discover);
    if (!mounted) return;
    if (host == null) {
      _poll?.cancel();
      _poll = null;
      setState(() {
        _loading = false;
        _host = null;
        _error = 'No board answered. Check that the phone is on the same Wi-Fi '
            'as the board, or enter the board IP.';
      });
      return;
    }

    final info = await _svc.readInfo();
    if (!mounted) return;
    if (info == null) {
      setState(() {
        _loading = false;
        _host = host;
        _error = 'The board answered at $host but did not return its device '
            'list.';
      });
      return;
    }

    final raw = info['devices'];
    final devices = <Map<String, dynamic>>[
      for (final d in (raw is List ? raw : const []))
        if (d is Map) d.cast<String, dynamic>(),
    ];

    final power = <String, bool>{};
    for (final d in devices) {
      final name = d['name']?.toString();
      final p = _powerOf(d);
      if (name != null && name.isNotEmpty && p != null) power[name] = p;
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = null;
      _host = host;
      _sku = info['sku']?.toString();
      _nodeId = info['node_id']?.toString() ?? '';
      _devices = devices;
      _power
        ..clear()
        ..addAll(power);
    });
    _startPoll();
  }

  /// Poll while this screen is visible so a PHYSICAL wall-switch flip shows up.
  /// Offline there is no push channel, so polling is the only way to see it.
  ///
  /// INTERVAL MATTERS — measured on the real R24 board (2026-10-28): at 5 s the
  /// board stops answering altogether. It performs a full TLS handshake per
  /// connection and has a tiny socket pool, so a poll every 5 s (each one a new
  /// handshake, because the pooled client's idle timeout is 5 s too) saturates
  /// it — `/she/info` then returns empty or times out, and every command fails
  /// with it. Toggling a light looked broken for exactly this reason.
  ///
  /// So: one shot at a time (never a periodic timer that can stack ticks), 20 s
  /// between successful reads, and a 60 s back-off after a failure — hammering a
  /// board that just timed out only keeps it down.
  void _startPoll() => _schedulePoll(const Duration(seconds: 20));

  void _schedulePoll(Duration delay) {
    _poll?.cancel();
    _poll = Timer(delay, () async {
      if (!mounted) return;
      if (_busy.isNotEmpty || _polling) {
        _schedulePoll(const Duration(seconds: 20));
        return;
      }
      _polling = true;
      await _load(quiet: true);
      _polling = false;
      if (!mounted) return;
      _schedulePoll(
        _error == null
            ? const Duration(seconds: 20)
            : const Duration(seconds: 60),
      );
    });
  }

  Future<void> _saveSetup() async {
    final pop = _popCtrl.text.trim();
    if (pop.length != 9 || int.tryParse(pop) == null) {
      setState(() => _error =
          'The PoP is the 9-digit number printed on the device label.');
      return;
    }
    await SettingsStore.setLocalPop(pop);
    await SettingsStore.setLocalHost(_hostCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      _showSetup = false;
      _error = null;
      _loading = true;
    });
    await _load(discover: true);
  }

  Future<void> _toggle(String name, bool value) async {
    // One command per device at a time — a double tap would otherwise send two
    // opposing commands and the last one wins by luck.
    if (_busy.contains(name)) return;
    setState(() => _busy.add(name));
    final accepted = await _svc.sendCommand(
      deviceName: name,
      params: {'Power': value},
    );
    if (!mounted) return;

    if (!accepted) {
      setState(() => _busy.remove(name));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(_svc.lastError ?? 'The board did not accept that command'),
        ),
      );
      unawaited(_load(quiet: true));
      return;
    }

    // STAGE 1 — show the command now.
    //
    // This is not an optimistic guess. The firmware writes the COMMANDED value
    // into `last_value` and publishes it immediately, so `/she/info` genuinely
    // reports it at this instant. (Same two-stage sequence the Devices tab
    // documents in CommandQueue.sendOrQueue.)
    setState(() {
      _power[name] = value;
      _busy.remove(name);
    });

    // STAGE 2 — settle onto the AC sense. One input-monitor cycle later the
    // board rewrites `last_value` from the lamp-side feedback, so a circuit with
    // nothing attached falls back to OFF. Without this the switch would stay on
    // the command until the next 20 s poll and then jump.
    unawaited(_settleOnFeedback(name));
  }

  /// Correct the switch to the board's FEEDBACK value after a local command.
  ///
  /// Deliberately waits PAST one input-monitor cycle (1 s), exactly like
  /// `CommandQueue._settleOnFeedback`: reading sooner returns stage 1 (the
  /// command), not what the lamp actually did.
  Future<void> _settleOnFeedback(String name) async {
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (!mounted) return;
    final reported = await _svc.readReportedPower(name);
    if (!mounted || reported == null) return;

    final before = _power[name];
    if (before == reported) return;
    setState(() => _power[name] = reported);

    // Only explain the direction that surprises people: it was told ON and the
    // circuit still reads dead.
    if (reported == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('The board reports OFF — no load detected on this circuit.'),
        ),
      );
    }
  }

  // ---- helpers --------------------------------------------------------------

  bool? _powerOf(Map<String, dynamic> d) {
    final params = d['params'];
    if (params is! List) return null;
    for (final p in params) {
      if (p is Map && p['name']?.toString() == 'Power' && p['value'] is bool) {
        return p['value'] as bool;
      }
    }
    return null;
  }

  /// Read-only readings for a device (sensors have no Power param).
  List<MapEntry<String, String>> _readingsOf(Map<String, dynamic> d) {
    final out = <MapEntry<String, String>>[];
    final params = d['params'];
    if (params is! List) return out;
    for (final p in params) {
      if (p is! Map) continue;
      final n = p['name']?.toString();
      if (n == null || n == 'Power') continue;
      final unit = _sensorUnits[n];
      if (unit == null) continue;
      final v = p['value'];
      if (v is! num) continue;
      final text = v == v.roundToDouble()
          ? v.toStringAsFixed(0)
          : v.toStringAsFixed(1);
      out.add(MapEntry(
        n == 'Soil_Moisture' ? 'Soil' : n,
        '$text $unit',
      ));
    }
    return out;
  }

  String _groupOf(Map<String, dynamic> d) {
    final name = (d['name']?.toString() ?? '').toLowerCase();
    if (name.startsWith('light')) return 'Lights';
    if (name.startsWith('socket')) return 'Sockets';
    return 'Sensors & other';
  }

  IconData _iconFor(String group) => switch (group) {
        'Lights' => Icons.lightbulb_outline,
        'Sockets' => Icons.power_outlined,
        _ => Icons.sensors,
      };

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: V3Colors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: V3Colors.ink),
          // Entered from the splash there is nothing to pop; falling back to
          // /login keeps the button from doing nothing.
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/login'),
        ),
        title: const Text('Local control'),
        actions: [
          IconButton(
            tooltip: 'Board settings',
            icon: Icon(Icons.tune, color: V3Colors.ink),
            onPressed: () => setState(() => _showSetup = !_showSetup),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(discover: true),
        child: ListView(
          padding: const EdgeInsets.all(V3Spacing.md),
          children: [
            _statusCard(),
            const SizedBox(height: V3Spacing.md),
            if (_showSetup) ...[
              _setupCard(),
              const SizedBox(height: V3Spacing.md),
            ],
            if (_loading && _devices.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: V3Spacing.xxl),
                child: Center(
                  child: CircularProgressIndicator(color: V3Colors.primary),
                ),
              )
            else if (_error != null && _devices.isEmpty)
              _errorCard()
            else if (_devices.isEmpty)
              _emptyCard()
            else
              ..._deviceSections(),
            const SizedBox(height: V3Spacing.xl),
            _cloudLink(),
            const SizedBox(height: V3Spacing.lg),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final connected = _host != null && _error == null;
    // Three states, not two: a failed poll with a list already on screen means
    // "unreachable right now", NOT "never connected" — and it is not the same as
    // a fresh screen that has nothing yet.
    final stale = !connected && _devices.isNotEmpty;
    final color = connected
        ? V3Colors.success
        : (stale ? V3Colors.warningAlt : V3Colors.dim);
    final title = connected
        ? 'Board connected'
        : (stale ? 'Board unreachable — reconnecting' : 'Not connected');
    final subtitle = connected
        ? '${_host!}${_sku == null || _sku!.isEmpty ? '' : ' · $_sku'}'
        : (stale
            ? 'Showing the last known state'
            : 'Direct Wi-Fi control — no internet needed');
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: V3Colors.ink,
                    fontSize: V3Typography.labelSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: V3Colors.text2,
                    fontSize: V3Typography.captionSize,
                  ),
                ),
              ],
            ),
          ),
          if (connected)
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh, color: V3Colors.textSecondary),
              onPressed: () => _load(discover: true),
            ),
        ],
      ),
    );
  }

  Widget _setupCard() {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connect to your board',
            style: TextStyle(
              color: V3Colors.ink,
              fontSize: V3Typography.labelSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The PoP is the 9-digit number on the device label. It is stored on '
            'this phone only and sent to the board, never to a server.',
            style: TextStyle(
              color: V3Colors.text2,
              fontSize: V3Typography.captionSize,
              height: 1.4,
            ),
          ),
          const SizedBox(height: V3Spacing.md),
          _field(
            controller: _popCtrl,
            label: 'Local control PoP (9 digits)',
            hint: '123456789',
            numeric: true,
          ),
          const SizedBox(height: V3Spacing.sm),
          _field(
            controller: _hostCtrl,
            label: 'Board IP (optional)',
            hint: '192.168.1.50',
            helper: 'Only if the board is not discovered automatically.',
          ),
          const SizedBox(height: V3Spacing.md),
          FilledButton.icon(
            onPressed: _saveSetup,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('Connect'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              backgroundColor: V3Colors.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorCard() {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.errorAlt.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.errorAlt.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_off, color: V3Colors.errorAlt, size: 18),
              const SizedBox(width: 8),
              Text(
                'Board not reachable',
                style: TextStyle(
                  color: V3Colors.ink,
                  fontSize: V3Typography.labelSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _error!,
            style: TextStyle(
              color: V3Colors.text2,
              fontSize: V3Typography.captionSize,
              height: 1.4,
            ),
          ),
          const SizedBox(height: V3Spacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _load(discover: true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: V3Colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: V3Spacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => setState(() => _showSetup = true),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Board IP'),
                  style: FilledButton.styleFrom(
                    backgroundColor: V3Colors.primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyCard() {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.lg),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.border),
      ),
      child: Column(
        children: [
          Icon(Icons.devices_other, color: V3Colors.dim, size: 32),
          const SizedBox(height: V3Spacing.sm),
          Text(
            'The board reports no devices yet.',
            style: TextStyle(color: V3Colors.text2, fontSize: V3Typography.labelSize),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Same chip row + flat list as the Devices tab.
  ///
  /// The old version grouped by LIGHTS / SOCKETS / SENSORS, which made local mode
  /// look like a different page from the one the user actually uses. Local mode
  /// now presents the board's devices exactly the way the Devices tab does.
  List<Widget> _deviceSections() {
    final visible = [
      for (final d in _devices)
        if (_matchesFilter(d)) d,
    ];
    return [
      SizedBox(
        height: 32,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final f in const [
              ('all', 'All'),
              ('lights', 'Lights'),
              ('appliances', 'Appliances'),
              ('security', 'Security'),
              ('climate', 'Climate'),
              ('other', 'Other'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: V3Spacing.sm),
                child: SHEFilterChip(
                  label: f.$2,
                  active: _filter == f.$1,
                  onTap: () => setState(() => _filter = f.$1),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: V3Spacing.md),
      if (visible.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: V3Spacing.lg),
          child: Text(
            'No devices in this category.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: V3Colors.text2,
              fontSize: V3Typography.labelSize,
            ),
          ),
        )
      else
        for (final d in visible) ...[
          _deviceTile(_groupOf(d), d),
          const SizedBox(height: V3Spacing.sm),
        ],
    ];
  }

  /// Mirrors `_matchesFilter` in devices_screen.dart — same kinds, same buckets.
  bool _matchesFilter(Map<String, dynamic> d) {
    if (_filter == 'all') return true;
    final kind = kindFromDeviceType(
      d['type']?.toString() ?? '',
      name: d['name']?.toString() ?? '',
    );
    return switch (_filter) {
      'lights' => kind == 'light',
      'appliances' => kind == 'outlet' || kind == 'appliance',
      'security' => kind == 'camera' || kind == 'gate',
      'climate' => kind == 'climate' || kind == 'irrigation',
      'other' =>
        kind == 'sensor' || kind == 'meter' || kind == 'tv' || kind == 'generic',
      _ => true,
    };
  }

  Widget _deviceTile(String group, Map<String, dynamic> d) {
    final name = d['name']?.toString() ?? 'Device';
    final power = _powerOf(d);

    // Relays render the EXACT card the Devices tab uses (DeviceTile), so local
    // and cloud control look like one app rather than two designs. The row is
    // built straight from `/she/info` — no cloud ids involved, and `deviceId`
    // is the firmware name because that is the board's only identifier.
    if (power != null) {
      final isOn = _power[name] ?? power;
      return DeviceTile(
        device: DeviceRow(
          nodeId: _nodeId,
          deviceId: name,
          name: name,
          kind: d['type']?.toString() ?? '',
          isOnline: true,
          isOn: isOn,
          raw: {'device_name': name},
        ),
        isOn: isOn,
        onToggle: () => _toggle(name, !isOn),
      );
    }

    // No Power param (the sensor module): the Devices tab has no switch for
    // these either, so show the readings read-only instead of a dead toggle.
    final readings = _readingsOf(d);
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(group), size: 20, color: V3Colors.primary),
              const SizedBox(width: V3Spacing.sm),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: V3Colors.ink,
                    fontSize: V3Typography.labelSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (readings.isNotEmpty) ...[
            const SizedBox(height: V3Spacing.sm),
            Wrap(
              spacing: V3Spacing.sm,
              runSpacing: V3Spacing.xs,
              children: [
                for (final r in readings)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: V3Spacing.sm,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: V3Colors.surface2,
                      borderRadius: BorderRadius.circular(V3Radius.sm),
                    ),
                    child: Text(
                      '${r.key}  ${r.value}',
                      style: TextStyle(
                        color: V3Colors.text2,
                        fontSize: V3Typography.captionSize,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _cloudLink() {
    return Center(
      child: TextButton.icon(
        onPressed: () => context.go('/login'),
        icon: Icon(Icons.cloud_outlined, size: 18, color: V3Colors.text2),
        label: Text(
          'Sign in for cloud features',
          style: TextStyle(color: V3Colors.text2, fontSize: V3Typography.captionSize),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool numeric = false,
    String? helper,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: V3Colors.textPrimary,
            fontSize: V3Typography.captionSize,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: numeric ? TextInputType.number : TextInputType.url,
          autocorrect: false,
          style: TextStyle(color: V3Colors.ink, fontSize: V3Typography.labelSize),
          decoration: InputDecoration(
            hintText: hint,
            helperText: helper,
            helperMaxLines: 2,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(V3Radius.md),
            ),
          ),
        ),
      ],
    );
  }
}
