// =============================================================================
// SHE V3 — Provisioning QR scanner (ESP RainMaker "classic" flow)
// =============================================================================
// V3-FACTORY-OPS §4. The factory sticker carries a JSON payload with the BLE
// advertisement name, the 9-digit PoP, the MAC and the SKU — everything the
// first three wizard screens ask for — so one scan replaces typing:
//
//   {"ver":1,"name":"SHE-R8-AABBCC","pop":"482917305","transport":"ble",
//    "mac":"24:6F:28:AA:BB:CC","sku":"SHE-R8","url":"https://she.et/setup/…"}
//
// The screen returns a [ProvisionQrPayload]; the caller opens the secure BLE
// session with it, exactly like RainMaker's ProofOfPossessionActivity.
//
// ── Why there is deliberately NO `scanWindow` on the MobileScanner widget ────
// Passing `scanWindow` looks like a nice UX touch, but on Android it is enforced
// in `MobileScanner.isBarcodeInScanWindow()` as
//
//     cornerPoints.all { scaledScanWindow.contains(it.x, it.y) }
//
// i.e. *every* corner of the code must fall inside a rectangle that Dart computes
// from the texture size, the reported device orientation and the BoxFit, and that
// the native side then rescales by the analysis-frame resolution. Any disagreement
// between those coordinate spaces (cover-crop, a mis-reported orientation, a
// resolution change) silently moves the checked region away from the frame the
// user is aiming at. The symptom is exactly "the camera is live, the code is
// centred in the frame, and nothing ever happens". Detection therefore runs over
// the whole preview; the on-screen frame is a visual guide only.
// =============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_esp_ble_prov/flutter_esp_ble_prov.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/she_theme.dart';

/// Parsed contents of a device provisioning QR code (V3-FACTORY-OPS §4).
class ProvisionQrPayload {
  const ProvisionQrPayload({
    this.version,
    this.name,
    this.pop,
    this.mac,
    this.sku,
    this.url,
  });

  final int? version;

  /// BLE advertisement name ("SHE-R8-AABBCC") — also the node id.
  final String? name;

  /// 9-digit numeric proof of possession.
  final String? pop;

  final String? mac;
  final String? sku;
  final String? url;

  static final RegExp _popOnly = RegExp(r'^\d{9}$');

  bool get hasName => name != null && name!.trim().isNotEmpty;
  bool get hasPop => pop != null && _popOnly.hasMatch(pop!.trim());

  /// Everything phase 1-3 needs to run without the user typing anything.
  bool get isComplete => hasName && hasPop;

  /// Returns null when [raw] is not a provisioning payload.
  ///
  /// Accepts, in order of likelihood:
  ///  1. the JSON payload itself;
  ///  2. a URL whose `data` query parameter holds that JSON — this is what the
  ///     firmware prints as its console fallback link, so a user who scans the
  ///     *screen* instead of the sticker still gets a usable payload;
  ///  3. a URL carrying the fields as plain query parameters
  ///     (`?name=…&pop=…&mac=…`);
  ///  4. a bare 9-digit PoP sticker.
  static ProvisionQrPayload? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final decoded = _tryDecodeJson(text);
    if (decoded is Map) return _fromMap(decoded);

    final fromUrl = _fromUrl(text);
    if (fromUrl != null) return fromUrl;

    if (_popOnly.hasMatch(text)) return ProvisionQrPayload(pop: text);
    return null;
  }

  static ProvisionQrPayload? _fromMap(Map<dynamic, dynamic> map) {
    String field(String key) => '${map[key] ?? ''}'.trim();

    final pop = field('pop');
    final name = field('name');
    final mac = field('mac');
    final sku = field('sku');
    final url = field('url');

    // Require at least one identifying field, or this is just some JSON blob.
    if (pop.isEmpty && name.isEmpty && mac.isEmpty) return null;

    return ProvisionQrPayload(
      version: int.tryParse(field('ver')),
      name: name.isEmpty ? null : name,
      pop: pop.isEmpty ? null : pop,
      mac: mac.isEmpty ? null : mac,
      sku: sku.isEmpty ? null : sku,
      url: url.isEmpty ? null : url,
    );
  }

  static ProvisionQrPayload? _fromUrl(String text) {
    // A JSON blob is not a URL, and `Uri.tryParse` is lenient enough to accept
    // almost anything as a relative reference, so only bother when it looks
    // like one.
    if (!text.contains('://') && !text.contains('?')) return null;

    final Uri? uri = Uri.tryParse(text);
    if (uri == null || uri.query.isEmpty) return null;

    // Decoding the query string can throw on malformed percent-encoding, so it
    // goes through a helper rather than a `try`/`catch` around an assignment
    // (which keeps the variable's definite-assignment analysis unambiguous).
    final params = _tryQueryParameters(uri);
    if (params == null) return null;

    // (2) The `data` parameter carries the JSON payload.
    final data = params['data']?.trim();
    if (data != null && data.isNotEmpty) {
      final decoded = _tryDecodeJson(data);
      if (decoded is Map) return _fromMap(decoded);
      if (_popOnly.hasMatch(data)) return ProvisionQrPayload(pop: data);
    }

    // (3) The fields are the query parameters themselves.
    if (params.containsKey('pop') || params.containsKey('mac')) {
      return _fromMap(params);
    }
    return null;
  }

  static Object? _tryDecodeJson(String text) {
    try {
      return jsonDecode(text);
    } on Object {
      // FormatException, and anything else the parser may surface.
      return null;
    }
  }

  static Map<String, String>? _tryQueryParameters(Uri uri) {
    try {
      return uri.queryParameters;
    } on Object {
      // Malformed percent-encoding in the query string.
      return null;
    }
  }
}

/// Full-screen camera view framed on the label QR.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  /// Pushes the scanner and returns the payload, or null if the user backed
  /// out or the code could not be used.
  static Future<ProvisionQrPayload?> push(BuildContext context) {
    return Navigator.of(context).push<ProvisionQrPayload>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
  }

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

/// What the bottom panel is telling the user right now.
enum _ScanStatus {
  /// `start()` is in flight (camera warming up, or permission dialog open).
  starting,

  /// Camera is live and we are looking for a code.
  scanning,

  /// Nothing decoded within [_scanTimeout] — advisory, we keep scanning.
  notFound,

  /// A code was decoded but it is not a provisioning payload.
  wrongCode,

  /// The user (or the OS) refused the camera.
  permissionDenied,

  /// The camera could not be started for any other reason.
  cameraError,
}

class _QrScanScreenState extends State<QrScanScreen>
    with WidgetsBindingObserver {
  /// Side of the aiming frame, in logical pixels.
  static const double _frame = 260;

  /// How long we keep looking before we say "nothing found". Most scanners
  /// give up at around this point; the camera keeps running so the message is
  /// advice, not a dead end.
  static const Duration _scanTimeout = Duration(seconds: 25);

  /// `autoStart: false` on purpose. With the default the widget calls `start()`
  /// itself from an `unawaited` future, so a refused camera permission throws an
  /// unhandled async error and the screen just stays black — `errorBuilder`
  /// never runs. Starting it here means the refusal is caught and turned into a
  /// message with a way out.
  ///
  /// `DetectionSpeed.normal` rather than `noDuplicates`: the native
  /// no-duplicates mode keeps its own "last value seen" state machine, and we
  /// already guarantee single-shot behaviour with [_handled]. `normal` is the
  /// plain, well-trodden path.
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  final _prov = FlutterEspBleProv();

  /// Set as soon as a payload is accepted OR the user leaves, so a late
  /// stream event can never pop the route a second time.
  bool _handled = false;

  bool _starting = false;

  /// How many times [_start] has retried a `controllerInitializing` throw.
  ///
  /// `MobileScannerController.start()` throws that code when another start is
  /// still in flight — which is exactly what happens when the screen is resumed
  /// while the camera is still coming up. It is transient, so it is retried
  /// rather than shown as a camera error the user cannot act on.
  int _startRetries = 0;

  _ScanStatus _status = _ScanStatus.starting;
  String? _message;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    // The camera has to be stopped when the app is backgrounded and restarted
    // on return — without this, coming back from "Open Android settings" (or
    // from the permission dialog on some OEM ROMs) leaves a frozen preview.
    WidgetsBinding.instance.addObserver(this);
    // After the first frame, so the MobileScanner widget has attached the
    // controller (`start()` waits for that attachment and gives up after
    // 500 ms).
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    // We own the controller: because it was created with `autoStart: false` and
    // passed in, `_MobileScannerState._disposeController()` deliberately does
    // NOT dispose it (`if (widget.controller == null)`). If we do not, the
    // camera session is never released. `dispose()` cannot be awaited from
    // `State.dispose()`, and a platform-channel failure there must not surface
    // as an unhandled async error, hence `.ignore()`.
    _controller.dispose().ignore();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_handled || !mounted) return;

    if (state == AppLifecycleState.resumed) {
      // Re-acquires the camera after a stop, and picks up a permission the user
      // just granted in Android settings.
      _start();
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _timeout?.cancel();
      // Never stop while `start()` is still in flight: the permission result is
      // delivered through that pending call, and stopping underneath it drops
      // the answer and wedges the screen on "starting".
      if (!_starting && _controller.value.isRunning) {
        unawaited(_controller.stop());
      }
    }
  }

  Future<void> _start() async {
    if (!mounted || _handled || _starting) return;

    // Already running (e.g. we were resumed but were never stopped): just make
    // sure the timeout is armed again.
    if (_controller.value.isRunning) {
      _armTimeout();
      return;
    }

    setState(() {
      _starting = true;
      _status = _ScanStatus.starting;
      _message = null;
    });

    try {
      await _controller.start();
      if (!mounted || _handled) return;
      _startRetries = 0;
      setState(() => _status = _ScanStatus.scanning);
      _armTimeout();
    } on MobileScannerException catch (e) {
      if (!mounted) return;
      // A start that raced an earlier one is transient, not a camera fault.
      // Retry a couple of times instead of surfacing an error the user can do
      // nothing about. `_starting` is released BEFORE the retry: the `finally`
      // below only runs when this method actually returns, which is after it.
      if (e.errorCode == MobileScannerErrorCode.controllerInitializing &&
          _startRetries < 2) {
        _startRetries++;
        setState(() => _starting = false);
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted && !_handled) await _start();
        return;
      }
      setState(() {
        _status = e.errorCode == MobileScannerErrorCode.permissionDenied
            ? _ScanStatus.permissionDenied
            : _ScanStatus.cameraError;
        _message = e.errorCode == MobileScannerErrorCode.permissionDenied
            ? null
            : 'Camera error: ${e.errorCode.message}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _ScanStatus.cameraError;
        _message = 'Camera error: $e';
      });
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(_scanTimeout, () {
      if (!mounted || _handled) return;
      // Only downgrade the message; the camera keeps running so the user can
      // simply keep aiming.
      if (_status != _ScanStatus.scanning) return;
      setState(() => _status = _ScanStatus.notFound);
    });
  }

  /// Opens this app's Android settings page — the only way back from a
  /// "Don't allow" on the camera.
  Future<void> _openSettings() async {
    try {
      await _prov.openAppSettings();
    } on Object {
      // The message already tells the user where to go.
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;

    var sawRejected = false;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;

      final payload = ProvisionQrPayload.tryParse(raw);
      if (payload == null) {
        sawRejected = true;
        continue;
      }

      // Accept: latch first so no further event can act, then leave.
      _handled = true;
      _timeout?.cancel();
      Navigator.of(context).pop(payload);
      return;
    }

    if (sawRejected && _status != _ScanStatus.wrongCode) {
      setState(() => _status = _ScanStatus.wrongCode);
    }
  }

  /// Cancel: same latch as an accepted scan, so a code detected in the same
  /// frame cannot pop a route that is already going away.
  void _close() {
    if (_handled) return;
    _handled = true;
    _timeout?.cancel();
    Navigator.of(context).pop();
  }

  void _retry() {
    if (_handled || _starting) return;
    // A manual retry gets a fresh set of attempts.
    _startRetries = 0;
    _start();
  }

  // ── Panel copy ────────────────────────────────────────────────────────────

  String get _headline => switch (_status) {
        _ScanStatus.starting => 'Starting the camera…',
        _ScanStatus.scanning =>
          'Point the camera at the QR code on the device label',
        _ScanStatus.notFound => 'No QR code found',
        _ScanStatus.wrongCode => 'That is not a device QR code',
        _ScanStatus.permissionDenied => 'Camera permission needed',
        _ScanStatus.cameraError => 'Camera unavailable',
      };

  Color get _headlineColor => switch (_status) {
        _ScanStatus.notFound => SheTheme.warning,
        _ScanStatus.wrongCode ||
        _ScanStatus.permissionDenied ||
        _ScanStatus.cameraError =>
          SheTheme.error,
        _ScanStatus.starting || _ScanStatus.scanning => SheTheme.textPrimary,
      };

  String get _detail => switch (_status) {
        _ScanStatus.starting =>
          'Allow the camera if Android asks for it.',
        _ScanStatus.scanning =>
          'The code carries the device name, the MAC address and the 9-digit '
              'proof of possession, so a single scan fills in the next three '
              'steps for you.',
        _ScanStatus.notFound =>
          'Move closer to the label, hold the phone steady and keep the whole '
              'code inside the frame. Brighten the label if it is in shadow, '
              'or type the details in instead.',
        _ScanStatus.wrongCode =>
          'Scan the label on the device enclosure. Its code is a short block '
              'of text that starts with {"ver" — this one was not.',
        _ScanStatus.permissionDenied =>
          'SHE cannot read the code without the camera. Open Android settings, '
              'allow the camera for SHE, then come back — scanning restarts by '
              'itself.',
        _ScanStatus.cameraError =>
          _message ?? 'The camera could not be started.',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: SheTheme.textPrimary,
        elevation: 0,
        title: const Text('Scan device QR'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final on = state.torchState == TorchState.on;
              final unavailable = state.torchState == TorchState.unavailable;
              return IconButton(
                tooltip: 'Torch',
                icon: Icon(
                  on ? Icons.flash_on : Icons.flash_off,
                  color: unavailable
                      ? SheTheme.textMuted
                      : SheTheme.brightSkyBlue,
                ),
                onPressed: unavailable ? null : _controller.toggleTorch,
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildPreview()),
          _buildPanel(context),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        // Only draw the aiming frame when there is actually a preview under it.
        final showFrame = state.isInitialized && state.error == null;

        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final left = (w - _frame) / 2;
            final top = ((h - _frame) / 2) - 24;
            final safeTop = top < 0 ? 0.0 : top;
            final right = w - left - _frame;
            final bottom = h - safeTop - _frame;
            const dim = _DecoratedDim();

            return Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  fit: BoxFit.cover,
                  // No `scanWindow` — see the file header. Detection covers the
                  // whole preview; the frame below is a guide for the user.
                  onDetect: _onDetect,
                  errorBuilder: _buildError,
                ),
                if (showFrame) ...[
                  Positioned(
                      left: 0, top: 0, width: w, height: safeTop, child: dim),
                  Positioned(
                      left: 0,
                      top: safeTop + _frame,
                      width: w,
                      height: bottom < 0 ? 0 : bottom,
                      child: dim),
                  Positioned(
                      left: 0,
                      top: safeTop,
                      width: left,
                      height: _frame,
                      child: dim),
                  Positioned(
                      left: left + _frame,
                      top: safeTop,
                      width: right < 0 ? 0 : right,
                      height: _frame,
                      child: dim),
                  Positioned(
                    left: left,
                    top: safeTop,
                    width: _frame,
                    height: _frame,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: SheTheme.brightSkyBlue, width: 2),
                          borderRadius:
                              BorderRadius.circular(SheTheme.radiusMd),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPanel(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        color: SheTheme.lighterNavy,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _headline,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _headlineColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            if (_starting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Text(
                _detail,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: SheTheme.textSecondary),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _starting ? null : _retry,
                    child: const Text('Try again'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: _close,
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
            // Android stops showing the permission dialog after a "Don't
            // allow", so without this the screen is a dead end.
            if (_status == _ScanStatus.permissionDenied) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open Android settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context, MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(denied ? Icons.no_photography : Icons.error_outline,
                  size: 48, color: SheTheme.warning),
              const SizedBox(height: 12),
              Text(
                denied
                    ? 'Camera permission is needed to scan the QR code.\n'
                        'Allow the camera for this app in Android Settings, '
                        'then tap Try again.'
                    : 'Camera error: ${error.errorCode.message}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: SheTheme.textPrimary),
              ),
              if (denied) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('Open Android settings'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DecoratedDim extends StatelessWidget {
  const _DecoratedDim();

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: ColoredBox(color: Colors.black.withValues(alpha: .55)));
}
