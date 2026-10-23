// =============================================================================
// SHE V3 — Add Device (BLE provisioning) — ESP RainMaker "classic" flow
// =============================================================================
// V3-MOBILE-APP §6. V3-FIRMWARE §5.
//
// Modelled on the ESP RainMaker classic Android app, which drives provisioning
// as a linear sequence of activities:
//
//   BLEProvisionLanding      → scan, list devices, tap one, "Connecting…"
//   ProofOfPossessionActivity→ PoP PIN entry, "Incorrect PoP" on rejection
//   ClaimingActivity         → "Claiming in progress…", red error icon on failure
//   ProvisionActivity        → five-step indicator + "Device Added Successfully!!"
//
// This screen keeps that shape as a five-phase wizard:
//
//   1. Select device   — editable name prefix + Scan + device list
//   2. Proof of Possession — verified immediately by opening the secure session
//   3. Device details  — MAC / model / home (SHE-specific: the app-claims flow
//                        needs the MAC, which RainMaker gets from the device)
//   4. Wi-Fi network   — network list, hidden-SSID entry, password
//   5. Adding device   — the RainMaker five-step indicator, then success
//
// The five indicator steps are RainMaker's, mapped onto this backend:
//   1 Sending Wi-Fi credentials   → provisionWifi()
//   2 Confirming Wi-Fi connection → the board reboots on GOT_IP (see below)
//   3 Configuring Node association→ POST /auth/claim-token + POST /nodes/claim
//   4 Confirming Node association → the node actually reports in to the backend
//   5 Setting up the Node         → finalise + open the dashboard
//
// Two firmware behaviours this screen has to work around:
//  * The board reboots the instant it gets an IP (ble_provisioning.c sets the
//    provisioned flag then esp_restart()s), which drops the BLE link before the
//    plugin can read the final status — so a false/throw from provisionWifi()
//    is usually a SUCCESS, not a rejected password. Step 4 is the real proof.
//  * The device publishes to she/{tenant}/{fctry_home}/… — the home baked into
//    its fctry NVS at the factory. If the node is claimed into a different home
//    the backend publishes to a topic the device never subscribes to, so the
//    app cannot read fctry_home and step 4 is the only honest check it has.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_esp_ble_prov/flutter_esp_ble_prov.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ble/bluetooth_preflight.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/she_theme.dart';
// The dashboard caches the home's node list in a FutureProvider, and device
// detail caches per node. Adding a device has to invalidate those or the front
// page keeps rendering the list it fetched before provisioning.
import '../device_detail/node_service.dart';
import 'qr_scan_screen.dart';

/// Which wizard screen is showing.
enum _Phase { scan, pop, details, wifi, progress }

/// The RainMaker five-step indicator (ProvisionActivity).
enum _ProvStep { sendCreds, confirmWifi, configureNode, confirmNode, setupNode }

enum _StepState { pending, active, done, failed }

/// What the board answered to the BLE "send credentials" call.
///
/// [noAnswer] is the *expected* outcome on this firmware, not an error: the board
/// reboots ~2 s after it gets an IP, which drops the BLE link before the
/// Espressif library can read the final status — and when that happens it
/// frequently invokes no callback at all. Treating that silence as "still
/// working" is what made a successful provision look like a frozen screen.
enum _SendOutcome { confirmed, noAnswer, rejected }

const Map<_ProvStep, String> _stepLabels = <_ProvStep, String>{
  _ProvStep.sendCreds: 'Sending Wi-Fi credentials',
  _ProvStep.confirmWifi: 'Confirming Wi-Fi connection',
  _ProvStep.configureNode: 'Configuring node association',
  _ProvStep.confirmNode: 'Confirming node association',
  _ProvStep.setupNode: 'Setting up the node',
};

class ProvisioningScreen extends ConsumerStatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  ConsumerState<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends ConsumerState<ProvisioningScreen> {
  /// Every SKU the backend's ClaimRequest accepts. SHE-R24 is the 24-relay
  /// board (lights 0-7 + 16-23, sockets in between).
  static const List<String> _skus = <String>[
    'SHE-R4',
    'SHE-R8',
    'SHE-R16',
    'SHE-R24',
  ];

  final _prov = FlutterEspBleProv();

  final _prefixCtrl = TextEditingController(text: 'SHE-');
  final _popCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  final _macCtrl = TextEditingController();
  // Hidden networks are invisible to the ESP32's scan (a hidden AP omits its
  // SSID from the beacon), so the name has to be typed by hand.
  final _manualSsidCtrl = TextEditingController();

  _Phase _phase = _Phase.scan;
  String _selectedSku = 'SHE-R8';

  bool _isLoading = false;
  bool _isScanning = false;
  String? _error;
  String? _warning;
  String? _status;

  List<String> _devices = [];
  List<String> _networks = [];
  String? _selectedDevice;
  String? _selectedSsid;

  /// The device's Wi-Fi scan result stays visible only until the user answers
  /// the question it exists to answer — pick a network, or type a hidden name —
  /// and then collapses out of the way. Clearing the name box, tapping refresh,
  /// or arriving on the screen afresh brings it back.
  bool _showNetworkList = true;

  /// True while a refresh of that list is in flight.
  bool _refreshingNetworks = false;

  /// Last 6 hex of the advertised BLE name ("SHE-AE5300" → "AE5300").
  /// The full MAC cannot be derived from it — the OUI is not advertised — so
  /// this is only a hint plus a cross-check on what the user types.
  String? _macSuffix;

  /// True when the MAC in [_macCtrl] came from the scanned QR payload rather
  /// than from the keyboard. The wizard then shows it as already answered
  /// instead of asking again: the sticker carries the full MAC, so re-typing it
  /// is busywork that only invites a typo. The manual (no-QR) path leaves this
  /// false — that is what makes the MAC step a real question there.
  bool _macFromQr = false;

  /// The SSID actually sent (either the picked one or the typed hidden one).
  String _ssid = '';

  final Map<_ProvStep, _StepState> _steps = <_ProvStep, _StepState>{
    for (final s in _ProvStep.values) s: _StepState.pending,
  };
  bool _added = false;

  /// The node was claimed but never reported in — show a "continue anyway"
  /// escape hatch rather than trapping the user on the progress screen.
  bool _partial = false;

  /// How long the wizard listens for the board's answer to the credentials.
  ///
  /// ⚠ Deliberately SHORT, and **not** a deadline for the whole operation — it is
  /// the window in which a *negative* answer can still arrive.
  ///
  /// The firmware sets its `provisioned` flag and reboots ~2 s after it gets an
  /// IP (`ble_provisioning.c` `prov_event_handler` → `esp_restart()`), which
  /// tears the BLE link down before the Espressif library can read the final
  /// status. When that happens the library frequently invokes **no callback at
  /// all** — neither success nor failure — so the platform-channel `Future` never
  /// completes. On a *successful* provision, silence is therefore the normal
  /// outcome, and waiting out a "safe" timeout is exactly what left the wizard
  /// parked on "Sending Wi-Fi credentials" while the board was already running.
  ///
  /// Every answer that exists does come back promptly: a rejected PoP, a refused
  /// handshake and the board's own `AUTH_FAILED` / `NETWORK_NOT_FOUND` are all
  /// reported within a few seconds of the config being written, and a successful
  /// provision reports at roughly 8-14 s (connect → session → config → DHCP →
  /// reboot). 20 s therefore covers every case that has anything to say. After
  /// it the wizard moves on and step 4 — the node reporting in over MQTT — is
  /// the verdict. A wrong password is still caught: the node never comes online
  /// and step 4 says so.
  static const Duration _provisionAnswerWindow = Duration(seconds: 20);

  /// Upper bound on the Wi-Fi scan, which is also the PoP check.
  ///
  /// Load-bearing, not cosmetic: the native side answers `scanWifiNetworks` by
  /// looking the device up **by name** in its own map of scanned BLE devices
  /// (`Boss.connector`) and then simply `return`s — completing no result at all —
  /// when the name is not in that map. A QR code whose device name the BLE scan
  /// never saw would otherwise wedge the PoP screen forever. The plugin's own
  /// connect path can take ~47 s (3 × 15 s attempts plus delays), so the bound
  /// sits above that.
  static const Duration _wifiScanTimeout = Duration(seconds: 50);

  /// Live "(12s)" counter for the BLE step, so a long wait does not look like a
  /// frozen screen.
  Timer? _elapsedTimer;
  int _elapsed = 0;

  /// The device's own rejection message, when there was one — surfaced in the
  /// "claimed but not online" warning instead of leaving the user guessing.
  String? _wifiError;

  /// True while step 4 is polling for the node. The progress screen shows a
  /// "stop waiting" button while it is, so a slow — or genuinely dead — device
  /// can never trap the user on a spinner.
  bool _waitingForNode = false;

  /// Set by that button; makes [_verifyOnline] give up on its next iteration.
  bool _skipWait = false;

  /// Set when the failure is one the user can only fix in Android Settings
  /// (a refused Bluetooth or camera permission), so the error block offers a
  /// shortcut there. Android stops showing the dialog after a "Don't allow",
  /// which otherwise leaves the flow as a dead end.
  bool _showSettingsAction = false;

  List<Map<String, dynamic>> _homes = [];
  String? _selectedHomeId;

  @override
  void initState() {
    super.initState();
    // The MAC field's check mark + error text derive from the controller text,
    // and the parent does not rebuild on typing — so listen explicitly.
    _macCtrl.addListener(_onMacChanged);
    _loadHomes();
    // The RainMaker classic app turns Bluetooth on, asks for the runtime
    // permissions and starts scanning as soon as its landing screen opens.
    // Deferred to after the first frame so the activity is fully attached
    // before we ask Android for anything.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scan(requestCamera: true);
    });
  }

  void _onMacChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHomes() async {
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (!mounted) return;
      setState(() {
        _homes = homes;
        if (_homes.isNotEmpty) {
          _selectedHomeId =
              (_homes.first['id'] ?? _homes.first['home_id'])?.toString();
        }
      });
    } catch (_) {
      // Homes load failure is non-fatal — backend falls back to the user's
      // most recent home when home_id is omitted (NodeServiceImpl.claim).
    }
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _macCtrl.removeListener(_onMacChanged);
    _prefixCtrl.dispose();
    _popCtrl.dispose();
    _passphraseCtrl.dispose();
    _macCtrl.dispose();
    _manualSsidCtrl.dispose();
    super.dispose();
  }

  // ─── small helpers ─────────────────────────────────────────────────────────
  void _setBusy(String status) {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _warning = null;
      _status = status;
      _showSettingsAction = false;
    });
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _error = e.toString();
      _warning = null;
      _status = null;
      _showSettingsAction = false;
    });
  }

  /// Opens this app's Android settings page — the only way back from a
  /// "Don't allow" on a runtime permission.
  Future<void> _openSettings() async {
    try {
      await _prov.openAppSettings();
    } catch (_) {
      // Nothing more we can do; the message already says where to go.
    }
  }

  void _setStep(_ProvStep step, _StepState state) {
    if (!mounted) return;
    setState(() => _steps[step] = state);
  }

  void _back() {
    if (_isLoading) return;
    setState(() {
      _error = null;
      _warning = null;
      _status = null;
      _partial = false;
      _showSettingsAction = false;
      _phase = switch (_phase) {
        _Phase.scan => _Phase.scan,
        _Phase.pop => _Phase.scan,
        _Phase.details => _Phase.pop,
        _Phase.wifi => _Phase.details,
        _Phase.progress => _Phase.wifi,
      };
    });
  }

  static String _stripMac(String s) => s.replaceAll(RegExp(r'[:\-]'), '');

  /// Accepts `AABBCCDDEEFF` or `AA:BB:CC:DD:EE:FF` (also dash-separated).
  /// The backend normalises the same way and then requires exactly 12 hex
  /// chars, so a 6-char suffix is NOT a valid MAC — validating the stripped
  /// form stops the old failure where a pre-filled "AE5300" could never pass.
  bool get _macValid =>
      RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(_stripMac(_macCtrl.text.trim()));

  static String? _suffixOf(String deviceName) {
    final m = RegExp(r'([0-9A-Fa-f]{6})$').firstMatch(deviceName.trim());
    return m?.group(1)?.toUpperCase();
  }

  /// "SHE-R24-AE5300" → "SHE-R24"; null when the name does not encode a model.
  static String? _skuFromName(String deviceName) {
    final m = RegExp(r'(SHE-R\d+)', caseSensitive: false)
        .firstMatch(deviceName.trim());
    if (m == null) return null;
    final candidate = m.group(1)!.toUpperCase();
    return _skus.contains(candidate) ? candidate : null;
  }

  String _homeLabel(String? id) {
    for (final h in _homes) {
      final hid = (h['id'] ?? h['home_id'])?.toString();
      if (hid == id) return (h['name'] ?? 'Home').toString();
    }
    return 'the selected home';
  }

  // ═══ Phase 1 — select device (RainMaker BLEProvisionLanding) ═══════════════
  /// True when the camera permission is granted. Never throws.
  ///
  /// The QR scanner asks for it too, so a plugin that cannot answer is not
  /// treated as a refusal here.
  Future<bool> _ensureCamera() async {
    try {
      return await _prov.requestPermissions(
        extra: const <String>[kAndroidCameraPermission],
      );
    } catch (_) {
      return true;
    }
  }

  /// What the RainMaker classic app does when its landing screen opens:
  /// switch Bluetooth on, take the runtime permissions, start scanning.
  ///
  /// [requestCamera] additionally asks for the camera, which the QR sticker
  /// needs. It is a *separate* request because the platform side only tracks
  /// one permission dialog at a time, and because a camera refusal must not
  /// block the Bluetooth flow — it is passed on the first (automatic) run only.
  Future<void> _scan({bool requestCamera = false}) async {
    if (_isLoading) return;
    setState(() {
      _isScanning = true;
      _isLoading = true;
      _error = null;
      _warning = null;
      _status = 'Preparing Bluetooth…';
      _devices = [];
      _selectedDevice = null;
      _macSuffix = null;
      _showSettingsAction = false;
    });

    // Permissions and the adapter state are checked HERE rather than left to
    // the plugin: a denied Bluetooth permission used to make the Espressif
    // library fail on a callback thread and take the whole process down.
    final pre = await ensureBluetoothReady(_prov);
    if (!mounted) return;
    if (!pre.ok) {
      setState(() {
        _isScanning = false;
        _isLoading = false;
        _status = null;
        _error = pre.message;
        _showSettingsAction = true;
      });
      return;
    }

    if (requestCamera) {
      if (mounted) setState(() => _status = 'Preparing the camera…');
      // The answer is deliberately ignored: _scanQr() re-checks it and shows
      // the message on the screen that actually needs the camera.
      await _ensureCamera();
      if (!mounted) return;
    }

    if (mounted) setState(() => _status = 'Scanning devices…');
    try {
      final devices = await _prov.scanBleDevices(_prefixCtrl.text.trim());
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _isScanning = false;
        _isLoading = false;
        _status = devices.isEmpty
            ? 'No devices found. Make sure the device is powered on and not '
                'already added to another phone, and — on Android 11 or older '
                '— that Location services are switched on (Android hides '
                'Bluetooth scan results without them).'
            : '${devices.length} device(s) found — tap one to continue';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isScanning = false);
      _fail('Scan failed. Check that Bluetooth is on and the Nearby devices '
          'permission is granted.\n\n$e');
    }
  }

  Future<void> _editPrefix() async {
    final ctrl = TextEditingController(text: _prefixCtrl.text);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name prefix'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'SHE-'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    if (v == null || v.isEmpty || !mounted) return;
    setState(() {
      _prefixCtrl.text = v;
      _devices = [];
      _status = null;
    });
    await _scan();
  }

  void _selectDevice(String name) {
    setState(() {
      _selectedDevice = name;
      _macSuffix = _suffixOf(name);
      final inferred = _skuFromName(name);
      if (inferred != null) _selectedSku = inferred;
      // A different device invalidates any MAC that came from a QR scan or from
      // an earlier selection — and this path is by definition "no QR", so the
      // MAC has to be asked for again.
      _macCtrl.clear();
      _macFromQr = false;
      _error = null;
      _warning = null;
      _status = null;
      _showNetworkList = true;
      _phase = _Phase.pop;
    });
  }

  // ═══ Phase 1 — QR (RainMaker classic: scan the label, skip the typing) ════
  /// One scan of the factory sticker (V3-FACTORY-OPS §4) supplies the BLE name,
  /// MAC, SKU and PoP — then the secure session is opened straight away, so
  /// the wizard lands on "Device Details" with everything filled in.
  Future<void> _scanQr() async {
    if (_isLoading) return;

    // The camera is a runtime permission of its own. Ask for it before opening
    // the scanner so a refusal produces a message instead of a black preview.
    _setBusy('Opening the camera…');
    final cameraOk = await _ensureCamera();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _status = null;
    });
    if (!cameraOk) {
      setState(() {
        _error =
            'SHE needs the camera permission to read the QR code on the device '
            'label. Allow the camera for this app in Android Settings, then try '
            'again.';
        _showSettingsAction = true;
      });
      return;
    }

    final payload = await QrScanScreen.push(context);
    if (payload == null || !mounted) return;

    setState(() {
      _error = null;
      _warning = null;
      _status = null;
      if (payload.hasName) {
        _selectedDevice = payload.name!.trim();
        _macSuffix = _suffixOf(_selectedDevice!);
        final inferred = _skuFromName(_selectedDevice!);
        if (inferred != null) _selectedSku = inferred;
      }
      if (payload.sku != null && _skus.contains(payload.sku!)) {
        _selectedSku = payload.sku!;
      }
      final mac = payload.mac?.trim();
      if (mac != null && mac.isNotEmpty) {
        _macCtrl.text = mac;
        // Only count as "answered" when it is a real 12-hex MAC. A malformed
        // sticker value stays in the field as a starting point but must remain
        // editable, so it does NOT satisfy the MAC step on its own.
        _macFromQr = RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(_stripMac(mac));
      } else {
        _macFromQr = false;
      }
      if (payload.hasPop) _popCtrl.text = payload.pop!.trim();
    });

    if (payload.isComplete) {
      // The sticker answered the MAC and the model, so Device Details has
      // nothing left to ask — go straight to Wi-Fi, the one thing a QR code
      // cannot know. `_macFromQr` is true only for a well-formed 12-hex MAC, so
      // this can never skip a MAC that still has to be typed.
      await _verifyPopAndScanWifi(skipDetails: _macFromQr);
      if (!mounted) return;
      // The scan failed before it could open the Wi-Fi screen (no answer over
      // Bluetooth). Land on the PoP step, which has the prefilled code and both
      // retry paths, rather than leaving the user on the landing screen with an
      // error and only a Bluetooth re-scan to press.
      if (_error != null && _phase != _Phase.wifi) {
        setState(() => _phase = _Phase.pop);
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      if (payload.hasName && !payload.hasPop) {
        _phase = _Phase.pop;
        _error = 'That QR code has no proof of possession — enter the '
            '9-digit code printed on the label.';
      } else if (payload.hasPop) {
        _error = 'That QR code has no device name. Scan for Bluetooth devices '
            'below and pick yours — the proof of possession you scanned has '
            'been filled in.';
      } else {
        _error = 'That QR code is not a device provisioning code. Scan the '
            'sticker on the device enclosure.';
      }
    });
  }

  // ═══ Phase 2 — PoP (RainMaker ProofOfPossessionActivity) ═══════════════════
  /// The PoP is verified here rather than on the Wi-Fi screen: opening the
  /// secure session is exactly what `scanWifiNetworks` does, so a wrong PoP
  /// surfaces on the screen that asked for it — like RainMaker's
  /// `error_pop_incorrect`.
  ///
  /// [skipDetails] lands on the Wi-Fi screen instead of Device Details. Set it
  /// when the QR sticker already supplied the MAC and the model, so Details
  /// would have nothing left to ask and is pure friction. The caller passes true
  /// only for a well-formed 12-hex QR MAC, so this can never skip a MAC that
  /// still has to be typed.
  Future<void> _verifyPopAndScanWifi({bool skipDetails = false}) async {
    final pop = _popCtrl.text.trim();
    if (pop.length != 9 || int.tryParse(pop) == null) {
      setState(() => _error =
          'PoP must be the 9-digit code printed on the device label or QR.');
      return;
    }
    _setBusy('Verifying proof of possession…');
    try {
      // ⚠ Bounded on purpose. The native handler answers this call by looking
      // the device up by name in its own map of scanned BLE devices and returns
      // without completing any result when the name is not there, so an
      // unbounded await can wedge this screen forever.
      final networks = await _prov
          .scanWifiNetworks(_selectedDevice!, pop)
          .timeout(_wifiScanTimeout);
      if (!mounted) return;
      setState(() {
        _networks = networks;
        _selectedSsid = null;
        _isLoading = false;
        _status = null;
        _phase = skipDetails ? _Phase.wifi : _Phase.details;
        // A fresh scan re-opens the list, even if an earlier pick collapsed it.
        _showNetworkList = true;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _status = null;
        _error = 'No answer from $_selectedDevice over Bluetooth '
            '(${_wifiScanTimeout.inSeconds}s). Check that the device is powered '
            'on and not still connected to another phone, then scan again.';
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('scanWifiNetworks failed: $e');
      final msg = e.toString().toLowerCase();
      // (e2,) is a GATT connect failure; a rejected session is the PoP.
      final connectFailure = msg.contains('(e2,');
      setState(() {
        _isLoading = false;
        _status = null;
        // No raw exception in the message: "(e2,)" and a PlatformException dump
        // tell the user nothing they can act on, and both cases already have a
        // plain-language fix.
        _error = connectFailure
            ? 'Could not connect to $_selectedDevice. Make sure it is powered '
                'on, nearby, and not already connected to another phone.'
            : 'Incorrect proof of possession. Check the 9-digit code on the '
                'device label and try again.';
      });
    }
  }

  // ═══ Phase 3 — device details ═════════════════════════════════════════════
  void _detailsNext() {
    final mac = _macCtrl.text.trim();
    if (!_macValid) {
      setState(() => _error =
          'Enter the full 12-digit MAC (AA:BB:CC:DD:EE:FF) from the device '
          'label. The last 3 bytes alone are not enough.');
      return;
    }
    final suffix = _stripMac(mac).substring(6).toUpperCase();
    if (_macSuffix != null && suffix != _macSuffix) {
      setState(() => _error =
          'This MAC ends in $suffix but $_selectedDevice advertises '
          '…$_macSuffix. Check the label — adding the wrong MAC binds a '
          'different device to your home.');
      return;
    }
    setState(() {
      _error = null;
      _showNetworkList = true;
      _phase = _Phase.wifi;
    });
  }

  // ═══ Phase 4 → 5 — provision, claim, verify ═══════════════════════════════

  /// Sends the credentials and listens for the board's answer — but only for
  /// [_provisionAnswerWindow], because on this firmware the answer may never
  /// come.
  ///
  /// Always returns. It can never leave the wizard waiting on a platform-channel
  /// `Future` that the native side has silently abandoned, which is the failure
  /// that produced the endless "Sending Wi-Fi credentials".
  ///
  /// [noAnswer] and [rejected] are **both survivable**: the board may have taken
  /// the credentials and rebooted before it could report anything, so step 4 is
  /// the only honest verdict.
  Future<_SendOutcome> _sendWifiCredentials(String ssid) async {
    final call = _prov.provisionWifi(
      _selectedDevice!,
      _popCtrl.text.trim(),
      ssid,
      _passphraseCtrl.text,
    );

    _startElapsedTicker();
    try {
      final ok = await call.timeout(_provisionAnswerWindow);
      return ok == true ? _SendOutcome.confirmed : _SendOutcome.noAnswer;
    } on TimeoutException {
      // No answer inside the window — which is what a *successful* provision
      // looks like here. Carry on immediately, but keep listening: a genuinely
      // late rejection is still worth quoting in step 4's warning.
      unawaited(call.then(
        (value) {
          if (value != true) {
            _recordLateFailure('the device answered without confirming');
          }
        },
        onError: (Object e) => _recordLateFailure(_describeError(e)),
      ));
      return _SendOutcome.noAnswer;
    } on Object catch (e) {
      // A wrong PoP, a rejected handshake, or a Wi-Fi join failure the board
      // *did* report. A real negative answer — but still not fatal, for the same
      // reason as above.
      _wifiError = _describeError(e);
      return _SendOutcome.rejected;
    } finally {
      _stopElapsedTicker();
    }
  }

  /// Stores a late answer from the abandoned BLE call, for step 4's warning.
  ///
  /// Guarded on purpose: by the time a late answer lands the wizard may already
  /// be past step 1 — or finished, or gone. Writing into `_wifiError` then would
  /// either be pointless or paint a failure over a result the user has already
  /// been shown.
  void _recordLateFailure(String message) {
    if (!mounted || _added || _partial || _error != null) return;
    if (_phase != _Phase.progress) return;
    if (_wifiError != null) return;
    setState(() => _wifiError = message);
  }

  /// One line of progress copy for the BLE step, with the elapsed seconds.
  ///
  /// The countdown is stated up front so a 20 s wait reads as "working", not as
  /// "frozen" — the screen never sits on an unqualified spinner.
  ///
  /// Deliberately free of firmware detail. The earlier copy explained that the
  /// board reboots and therefore "usually never answers", which reads as a
  /// defect to someone adding their first device. That behaviour is expected and
  /// the wizard already handles it, so it is not the user's problem to know.
  String _sendStatus() =>
      'Sending Wi-Fi details to "$_ssid"… ${_elapsed}s / '
      '${_provisionAnswerWindow.inSeconds}s';

  void _startElapsedTicker() {
    _elapsedTimer?.cancel();
    _elapsed = 0;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed++;
        _status = _sendStatus();
      });
    });
  }

  void _stopElapsedTicker() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  /// MethodChannel failures arrive as [PlatformException]; prefer its message,
  /// which is the one the plugin composed from the ESP library's reason.
  String _describeError(Object e) {
    if (e is PlatformException) {
      final message = e.message?.trim();
      if (message != null && message.isNotEmpty) return message;
      return 'Bluetooth error ${e.code}';
    }
    return e.toString();
  }

  /// Entry point for the Wi-Fi screen's button.
  ///
  /// A thin guard around [_runProvisioning]: nothing in this wizard is allowed to
  /// leave the user parked on a step that never finishes. Every *expected* exit
  /// is handled inside — this only catches the unexpected, and turns it into a
  /// visible error with a way back instead of an unhandled async error and a
  /// permanently "active" step.
  Future<void> _startProvisioning() async {
    try {
      await _runProvisioning();
    } on Object catch (e) {
      if (!mounted) return;
      // The raw exception stays out of the UI: it means nothing to the user, and
      // a stack-trace-shaped wall of text reads as a crash. Logged instead.
      debugPrint('provisioning threw: $e');
      setState(() {
        _isLoading = false;
        _status = null;
        _waitingForNode = false;
        _error =
            'Something went wrong while adding the device. Please try again.';
      });
    }
  }

  Future<void> _runProvisioning() async {
    final manual = _manualSsidCtrl.text.trim();
    final ssid = manual.isNotEmpty ? manual : _selectedSsid;
    if (ssid == null || ssid.isEmpty) {
      setState(() => _error =
          'Select a Wi-Fi network, or type the name of your hidden network.');
      return;
    }
    _ssid = ssid;

    setState(() {
      _phase = _Phase.progress;
      _error = null;
      _warning = null;
      _status = null;
      _isLoading = false;
      _added = false;
      _partial = false;
      for (final s in _ProvStep.values) {
        _steps[s] = _StepState.pending;
      }
    });

    // ---- Step 1: sending Wi-Fi credentials ----
    // ⚠ This is the step that used to hang the wizard. The board's answer is
    // usually silence (it reboots before it can report), so this waits only
    // [_provisionAnswerWindow] and then carries on — step 4 is the verdict.
    _setStep(_ProvStep.sendCreds, _StepState.active);
    _wifiError = null;
    setState(() => _status = _sendStatus());
    final outcome = await _sendWifiCredentials(ssid);
    if (!mounted) return;
    _setStep(_ProvStep.sendCreds, _StepState.done);
    // The outcome is recorded but NOT shown as a warning. On this firmware "no
    // answer" is the normal result of a *successful* provision — the board
    // reboots and drops the BLE link before it can reply — so surfacing it told
    // every user their device had failed when it had just worked. A genuine
    // rejection rides along in `_wifiError` and is only mentioned by step 4,
    // which is the real verdict.
    if (outcome == _SendOutcome.rejected) {
      debugPrint('provisionWifi rejected: $_wifiError');
    }

    // ---- Step 2: confirming Wi-Fi connection ----
    // The board restarts here, so this step is "give it a moment" rather than a
    // real confirmation; step 4 is where we learn the truth.
    _setStep(_ProvStep.confirmWifi, _StepState.active);
    // Drop the step-1 counter, or its stale "…12s" line stays on screen.
    setState(() => _status = null);
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    _setStep(_ProvStep.confirmWifi, _StepState.done);

    // ---- Step 3: configuring node association ----
    _setStep(_ProvStep.configureNode, _StepState.active);
    final mac = _macCtrl.text.trim();
    final nodeService = ref.read(nodeServiceProvider);
    var dbId = '';
    var nodeId = '';
    String? baselineSeen;
    try {
      // Baseline BEFORE claiming: a factory pre-registered node may already
      // have a last_seen_at, which must not be mistaken for "it just came
      // online" in step 4.
      final homeId = _selectedHomeId;
      if (homeId != null) {
        try {
          final want = _stripMac(mac).toLowerCase();
          for (final n in await nodeService.listNodesByHome(homeId)) {
            if ((n['normalized_mac'] ?? '').toString().toLowerCase() == want) {
              baselineSeen = n['last_seen_at']?.toString();
              break;
            }
          }
        } catch (_) {
          // Best-effort; without it step 4 is simply more lenient.
        }
      }

      final token = await nodeService.claimToken();
      final result = await nodeService.claim(
        mac: mac,
        claimToken: token,
        sku: _selectedSku,
        homeId: _selectedHomeId,
        config: const {},
      );
      // `node_db_id` is the documented key, but the response has shipped other
      // shapes. Accept them all: an empty id used to be read as "nothing to
      // verify" and the wizard declared success on a claim it never checked.
      dbId = (result['node_db_id'] ?? result['id'] ?? '').toString();
      nodeId = (result['node_id'] ?? dbId).toString();

      // Tell the dashboard which home this node went into. It resolves its own
      // home from `/homes` on first load and the user may have picked a
      // different one here, in which case the new device would never appear on
      // the front page even though the claim succeeded.
      if (_selectedHomeId != null && _selectedHomeId!.isNotEmpty) {
        ref.read(activeHomeIdProvider.notifier).state = _selectedHomeId;
      }

      // Keep the PoP for the LAN path. It is the ONLY credential local control
      // uses (X-SHE-PoP on /she/info and /she/ctrl), and provisioning is the one
      // moment the user has it in hand — asking for it again on every relay tap
      // would be absurd. Keyed by the backend node id, because that is the id
      // every other part of the app passes around. SecureStorage, never the
      // plain Hive settings box: it is a device credential.
      final pop = _popCtrl.text.trim();
      if (dbId.isNotEmpty && pop.isNotEmpty) {
        await SecureStorage.saveNodePop(dbId, pop);
      } else if (pop.isNotEmpty) {
        // The user typed a PoP but the claim response carried no node id, so
        // there is nothing to key it under and local control will stay off.
        // Rare (the DTO always returns node_db_id), but silent data loss is the
        // exact failure this feature exists to avoid — say so instead.
        debugPrint('claim: no node id in the response — PoP not stored, '
            'local control will need to be configured by hand');
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('claim failed: $e');
      _setStep(_ProvStep.configureNode, _StepState.failed);
      setState(() => _error =
          'Could not add the device to your account. Please try again.');
      return;
    }
    if (!mounted) return;
    _setStep(_ProvStep.configureNode, _StepState.done);

    // The node now exists server-side. Everything that renders it caches:
    //   * `homeNodesProvider` backs the dashboard grid. Invalidate the whole
    //     family rather than one key, so it refreshes whichever home the
    //     dashboard resolved to — the id this wizard used is now published
    //     through `activeHomeIdProvider`, so the two agree.
    //   * the per-node providers back device detail, so opening the new device
    //     does not show a stale/empty record.
    // Without this the front page keeps showing the list it fetched before
    // provisioning and the new device looks like it was never added.
    ref.invalidate(homeNodesProvider);
    if (dbId.isNotEmpty) {
      ref.invalidate(nodeDetailProvider(dbId));
      ref.invalidate(nodeDevicesProvider(dbId));
    }

    // ---- Step 4: confirming node association ----
    _setStep(_ProvStep.confirmNode, _StepState.active);
    _skipWait = false;
    setState(() => _waitingForNode = true);
    final online = await _verifyOnline(dbId, mac, _selectedHomeId, baselineSeen);
    if (!mounted) return;
    // Clear the polling line too, or its last "(12/12)" stays on screen under
    // the result.
    setState(() {
      _waitingForNode = false;
      _status = null;
    });
    _setStep(_ProvStep.confirmNode,
        online ? _StepState.done : _StepState.failed);

    // ---- Step 5: setting up the node ----
    if (!online) {
      setState(() {
        _steps[_ProvStep.setupNode] = _StepState.failed;
        _partial = true;
        // Kept short and free of MQTT/home-topic detail. This is the one case
        // where something genuinely did not finish, so it has to say so — but it
        // should read as "check the password", not as a diagnosis. The device's
        // own rejection text still goes to the log.
        _warning = '$nodeId was added to your account, but it has not checked '
            'in yet.\n\n'
            'Check the Wi-Fi password and try again. If it still does not '
            'appear, make sure the device belongs to '
            '"${_homeLabel(_selectedHomeId)}".';
      });
      return;
    }

    _setStep(_ProvStep.setupNode, _StepState.active);
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    _setStep(_ProvStep.setupNode, _StepState.done);
    setState(() => _added = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) context.go('/dashboard');
  }

  /// True while the wizard is mid-provision and nothing terminal has been
  /// decided yet.
  ///
  /// Derived rather than a flag on purpose: every exit path from
  /// [_startProvisioning] sets `_added`, `_partial` or `_error`, so this turns
  /// itself off without any reset that could be missed on an early `return`.
  /// It gates the AppBar back button — walking away mid-call would leave a
  /// board half-configured and a BLE session still open.
  bool get _running =>
      _phase == _Phase.progress && !_added && !_partial && _error == null;

  /// Poll GET /api/v3/nodes/{id} until the node reports in (≈120 s max).
  /// A freshly claimed node is only "online" once its next MQTT message lands,
  /// so this is the app's only honest way to tell a good claim from a bad one.
  ///
  /// The budget must comfortably exceed the device's `params/local` publish
  /// period, which is **60 s** (measured on the bench board: 18:56:32,
  /// 18:57:32, 18:58:32, 18:59:31, 19:00:31). At 12 attempts × 5 s the window
  /// was exactly one period, so a provision that started just after a publish
  /// timed out and reported a false "added but not reporting in" on a device
  /// that was in fact fine. 24 attempts spans two full periods.
  ///
  /// [nodeDbId] may be empty: the claim response's key has changed shape before,
  /// and reading "no id in the response" as success is what let a claim the app
  /// never actually verified pass for a finished one. When it is empty the node
  /// is looked up by its normalised MAC inside [homeId] instead.
  ///
  /// [baselineSeen] is the node's `last_seen_at` from before the claim — a
  /// report that differs from it (or is_online) proves the device is talking to
  /// the backend now, rather than having talked to it in some earlier session.
  ///
  /// Returns false early when the user presses "stop waiting" — the node stays
  /// claimed either way, and the progress screen then offers the dashboard.
  Future<bool> _verifyOnline(
    String nodeDbId,
    String mac,
    String? homeId,
    String? baselineSeen,
  ) async {
    const int attempts = 24;
    final svc = ref.read(nodeServiceProvider);
    final want = _stripMac(mac).toLowerCase();
    var id = nodeDbId;
    var attempt = 0;
    while (attempt < attempts) {
      // Check before sleeping, so a device that is already up resolves on the
      // first pass instead of after a pointless 5 s wait.
      if (attempt > 0) {
        await Future.delayed(const Duration(seconds: 5));
      }
      attempt++;
      if (!mounted || _skipWait) return false;
      try {
        if (id.isEmpty) {
          if (homeId == null || homeId.isEmpty) {
            // Nothing to check against — stay lenient rather than inventing a
            // failure the app cannot substantiate.
            return true;
          }
          for (final n in await svc.listNodesByHome(homeId)) {
            if ((n['normalized_mac'] ?? '').toString().toLowerCase() == want) {
              id = (n['id'] ?? n['node_id'] ?? '').toString();
              break;
            }
          }
          // The claim is not visible yet; keep looking.
          if (id.isEmpty) {
            if (mounted) {
              setState(() => _status = 'Looking for the node in your home… '
                  '($attempt/$attempts)');
            }
            continue;
          }
        }
        final node = await svc.getNode(id);
        if (node['is_online'] == true) return true;
        final seen = node['last_seen_at']?.toString();
        if (seen != null && seen.isNotEmpty && seen != baselineSeen) return true;
      } catch (_) {
        // Transient — keep polling.
      }
      if (mounted) {
        setState(() => _status = 'Waiting for the device to report in… '
            '($attempt/$attempts)');
      }
    }
    return false;
  }

  // ═══ UI ════════════════════════════════════════════════════════════════════
  String get _title => switch (_phase) {
        _Phase.scan => 'Add Device',
        _Phase.pop => 'Proof of Possession',
        _Phase.details => 'Device Details',
        _Phase.wifi => 'Wi-Fi Network',
        _Phase.progress => 'Adding Device',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        leading: _phase == _Phase.scan
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: (_isLoading || _running) ? null : _back,
              ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _phase == _Phase.progress ? _buildProgress() : _buildInputPhase(),
              if (_status != null && !_added) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (_isLoading) ...[
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: Text(_status!)),
                  ],
                ),
              ],
              if (_warning != null) ...[
                const SizedBox(height: 16),
                Text(_warning!,
                    style: TextStyle(color: Colors.orange.shade800)),
              ],
              // Escape hatch for step 4. The node is claimed either way, so a
              // device that is slow (or never comes back) must not hold the user
              // on a spinner for the full polling budget.
              if (_waitingForNode) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => setState(() => _skipWait = true),
                  child: const Text('Stop waiting and continue'),
                ),
              ],
              if (_partial) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => context.go('/dashboard'),
                  child: const Text('Continue to dashboard'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: SheTheme.error)),
                const SizedBox(height: 12),
                OutlinedButton(
                  // On the landing screen "try again" means re-scan; on the
                  // later steps it means stepping back to the screen that
                  // failed.
                  onPressed: _isLoading
                      ? null
                      : (_phase == _Phase.scan ? () => _scan() : _back),
                  child: Text(_phase == _Phase.scan ? 'Try again' : 'Back'),
                ),
                if (_showSettingsAction) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Open Android settings'),
                  ),
                ],
              ],
              if (_added) ...[
                const SizedBox(height: 20),
                Center(
                  child: Column(
                    children: [
                      const Icon(Icons.check_circle,
                          size: 72, color: Colors.green),
                      const SizedBox(height: 12),
                      Text('Device Added Successfully!!',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('Opening dashboard…',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputPhase() => switch (_phase) {
        _Phase.scan => _buildScan(),
        _Phase.pop => _buildPop(),
        _Phase.details => _buildDetails(),
        _Phase.wifi => _buildWifi(),
        _Phase.progress => const SizedBox.shrink(),
      };

  // ---- Phase 1 ----
  Widget _buildScan() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.bluetooth_searching,
              size: 56, color: SheTheme.brightSkyBlue),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isLoading ? null : _scanQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
          ),
          const SizedBox(height: 8),
          Text(
            'The QR on the device label adds it in one step. Otherwise pair '
            'over Bluetooth:',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          // RainMaker shows the name prefix with an edit button.
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'Device name prefix', isDense: true),
                  child: Text(_prefixCtrl.text),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Change prefix',
                icon: const Icon(Icons.edit),
                onPressed: _isLoading ? null : _editPrefix,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _isLoading ? null : _scan,
            icon: Icon(_isScanning ? Icons.hourglass_top : Icons.refresh),
            label: Text(_isScanning ? 'Scanning…' : 'Scan'),
          ),
          const SizedBox(height: 16),
          ..._devices.map((d) => Card(
                child: ListTile(
                  leading: const Icon(Icons.memory),
                  title: Text(d),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _isLoading ? null : () => _selectDevice(d),
                ),
              )),
        ],
      );

  // ---- Phase 2 ----
  Widget _buildPop() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Device: ${_selectedDevice ?? ''}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 16),
          const Text(
              'Enter the proof of possession (PoP) for this device. It is the '
              '9-digit code printed on the device label or QR code.'),
          const SizedBox(height: 16),
          TextField(
            controller: _popCtrl,
            keyboardType: TextInputType.number,
            maxLength: 9,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Proof of possession',
              hintText: '123456789',
            ),
          ),
          const SizedBox(height: 8),
          // Reaching the PoP screen without a QR means the MAC step is still
          // ahead — say so, so the label is at hand.
          if (!_macFromQr) ...[
            Text(
              'Next you will be asked for the device MAC address. Have the '
              'label handy, or scan the QR code instead.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
          ],
          ElevatedButton(
            onPressed: _isLoading ? null : _verifyPopAndScanWifi,
            child: const Text('Next'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _isLoading ? null : _scanQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code instead'),
          ),
        ],
      );

  // ---- Phase 3 ----
  /// The QR sticker carried the full MAC, so it is already answered: show it as
  /// a fact with a way to correct it, rather than asking for it again.
  Widget _buildMacFromQr() => InputDecorator(
        decoration: InputDecoration(
          labelText: 'MAC address',
          helperText: 'Read from the QR code on the device label.',
          suffixIcon: IconButton(
            tooltip: 'Enter a different MAC',
            icon: const Icon(Icons.edit,
                size: 18, color: SheTheme.textSecondary),
            onPressed: () => setState(() => _macFromQr = false),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle, size: 18, color: SheTheme.success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _macCtrl.text.trim(),
                style: const TextStyle(color: SheTheme.textPrimary),
              ),
            ),
          ],
        ),
      );

  /// No QR was used, so the MAC is a genuine question. The advertised BLE name
  /// only carries the last 3 bytes (the OUI is not broadcast) and the claim is
  /// keyed on all 6, so this cannot be inferred — it has to be typed.
  Widget _buildMacEntry() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _macCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'MAC address',
              hintText: 'AA:BB:CC:DD:EE:FF',
              helperText: _macSuffix == null
                  ? 'Type the full 12-digit MAC printed on the device label'
                  : 'This device advertises …$_macSuffix — type the full MAC '
                      'from the label (the first 3 bytes are the manufacturer '
                      'prefix and are not broadcast)',
              helperMaxLines: 3,
              errorText: _macCtrl.text.trim().isEmpty || _macValid
                  ? null
                  : 'Needs all 12 hex digits',
              suffixIcon: _macValid
                  ? const Icon(Icons.check, color: SheTheme.brightSkyBlue)
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No QR code was scanned, so SHE cannot read the address off the '
            'device — this is the only way to bind the right board to your home.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: SheTheme.textSecondary),
          ),
        ],
      );

  Widget _buildDetails() {
    final homeItems = <DropdownMenuItem<String>>[];
    for (final h in _homes) {
      final id = (h['id'] ?? h['home_id'])?.toString();
      if (id == null || id.isEmpty) continue;
      homeItems.add(DropdownMenuItem(
        value: id,
        child: Text((h['name'] ?? 'Home').toString()),
      ));
    }
    final homeValue =
        homeItems.any((i) => i.value == _selectedHomeId) ? _selectedHomeId : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Device: ${_selectedDevice ?? ''}',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 16),
        // QR path: the MAC is already known, so it is shown as answered.
        // Manual path: it is the one thing the app genuinely cannot know, so it
        // is asked for here.
        if (_macFromQr) _buildMacFromQr() else _buildMacEntry(),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('sku-$_selectedSku'),
          initialValue: _selectedSku,
          decoration: const InputDecoration(labelText: 'Model'),
          items: _skus
              .map((s) => DropdownMenuItem(value: s, child: Text(s)))
              .toList(),
          onChanged: (v) => setState(() => _selectedSku = v ?? _selectedSku),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('home-$homeValue'),
          initialValue: homeValue,
          decoration: const InputDecoration(labelText: 'Home'),
          items: homeItems,
          onChanged: (v) => setState(() => _selectedHomeId = v),
        ),
        const SizedBox(height: 8),
        Text(
          'Add the device to the home it was factory-registered to — the '
          'backend addresses it by home, so a mismatch means commands never '
          'reach it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _isLoading ? null : _detailsNext,
          child: const Text('Next'),
        ),
      ],
    );
  }

  // ═══ Phase 4 — Wi-Fi (the name box first, the scan result as an assist) ═══
  /// Re-runs the device's Wi-Fi scan, so a network that was out of range — or a
  /// router that has since come up — can be picked without redoing the QR and
  /// Bluetooth steps.
  ///
  /// Failure is deliberately quiet: the list stays as it was and one short line
  /// says so. A refresh is a convenience, and a red error block for it would read
  /// as though the whole setup had failed.
  Future<void> _refreshWifiNetworks() async {
    final device = _selectedDevice;
    if (device == null || device.isEmpty || _refreshingNetworks) return;
    setState(() {
      _refreshingNetworks = true;
      _showNetworkList = true;
      _status = null;
    });
    try {
      final networks = await _prov
          .scanWifiNetworks(device, _popCtrl.text.trim())
          .timeout(_wifiScanTimeout);
      if (!mounted) return;
      setState(() {
        _networks = networks;
        _refreshingNetworks = false;
        _status = networks.isEmpty
            ? 'No networks found yet — try again in a moment.'
            : null;
      });
    } catch (e) {
      debugPrint('Wi-Fi rescan failed: $e');
      if (!mounted) return;
      setState(() {
        _refreshingNetworks = false;
        _status = 'Could not refresh the list. Tap the button to try again.';
      });
    }
  }

  Widget _buildWifi() {
    // The box is the single source of truth for the SSID: picking from the list
    // writes into it, and typing overrides it. That is also why Provision is
    // gated on the box rather than on `_selectedSsid`.
    final typed = _manualSsidCtrl.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Device: ${_selectedDevice ?? ''}',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        // A hidden AP omits its SSID from the beacon, so the ESP32's scan cannot
        // see it at all — the name has to be typed. That is why the name box is
        // the primary control and the scan result sits underneath it.
        TextField(
          controller: _manualSsidCtrl,
          decoration: InputDecoration(
            labelText: 'Network name (SSID)',
            hintText: 'Tap a network below, or type a hidden one',
            suffixIcon: IconButton(
              tooltip: 'Refresh the network list',
              onPressed: (_isLoading || _refreshingNetworks)
                  ? null
                  : _refreshWifiNetworks,
              icon: _refreshingNetworks
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
          onChanged: (v) => setState(() {
            // Answering the question hides the list; clearing the box brings it
            // back, so another network can be picked without a re-scan.
            _showNetworkList = v.trim().isEmpty;
            _selectedSsid = _networks.contains(v) ? v : null;
          }),
        ),
        if (_showNetworkList) ...[
          const SizedBox(height: 8),
          if (_networks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No networks found. If yours is hidden, type its name above — '
                'otherwise tap refresh.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            ..._networks.map((n) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: _selectedSsid == n
                      ? SheTheme.brightSkyBlue.withValues(alpha: 0.2)
                      : null,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.wifi),
                    title: Text(n.isEmpty ? '(unnamed)' : n),
                    trailing: _selectedSsid == n
                        ? const Icon(Icons.check, color: SheTheme.brightSkyBlue)
                        : null,
                    onTap: _isLoading
                        ? null
                        : () => setState(() {
                              // Fill the box, then get out of the way — the
                              // selection has to be readable in the field, not
                              // only as a highlight in a list that is about to
                              // collapse.
                              _manualSsidCtrl.text = n;
                              _selectedSsid = n;
                              _showNetworkList = false;
                            }),
                  ),
                )),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _passphraseCtrl,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'Wi-Fi password', hintText: '••••••••'),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: (_isLoading || typed.isEmpty) ? null : _startProvisioning,
          child: const Text('Provision'),
        ),
      ],
    );
  }

  // ---- Phase 5: the RainMaker five-step indicator ----
  Widget _buildProgress() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Adding ${_selectedDevice ?? 'device'}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Network: $_ssid',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
          for (final step in _ProvStep.values)
            _StepRow(label: _stepLabels[step]!, state: _steps[step]!),
        ],
      );
}

/// One row of the five-step indicator: state icon + label.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final Widget leading = switch (state) {
      _StepState.pending => const Icon(Icons.radio_button_unchecked,
          size: 22, color: Colors.grey),
      _StepState.active => const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      _StepState.done =>
        const Icon(Icons.check_circle, size: 22, color: Colors.green),
      _StepState.failed =>
        const Icon(Icons.error, size: 22, color: SheTheme.error),
    };

    final Color color = switch (state) {
      _StepState.pending => Colors.grey,
      _StepState.active => SheTheme.brightSkyBlue,
      _StepState.done => Colors.green,
      _StepState.failed => SheTheme.error,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 26, child: Center(child: leading)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: state == _StepState.active
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
