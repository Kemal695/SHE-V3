// =============================================================================
// SHE V3 — Server endpoints dialog (shared)
// =============================================================================
// Used from BOTH Settings and the Login screen.
//
// Why the login screen needs it: the router redirects unauthenticated users to
// /login, so a wrong server URL means you cannot sign in — and therefore cannot
// reach Settings to correct it. That is precisely the situation where you need
// this dialog, so it must be reachable without a session.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/base_url_provider.dart';
import '../../core/network/ws_client.dart';
import '../../core/storage/settings_store.dart';

/// Show the API / WebSocket endpoint editor.
Future<void> showServerSettingsDialog(BuildContext context, WidgetRef ref) {
  final apiController =
      TextEditingController(text: ref.read(apiBaseUrlProvider));
  final wsController =
      TextEditingController(text: ref.read(wsBaseUrlProvider));

  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      String? errorText;

      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Server endpoints'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Change these when the backend moves to a new address, '
                      'instead of rebuilding the app.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: apiController,
                    decoration: const InputDecoration(
                      labelText: 'API base URL',
                      hintText: 'http://192.168.1.7:8080',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: wsController,
                    decoration: const InputDecoration(
                      labelText: 'WebSocket base URL',
                      hintText: 'ws://192.168.1.7:8080',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await SettingsStore.resetToDefaults();
                  ref.read(apiBaseUrlProvider.notifier).state =
                      SettingsStore.apiBaseUrl;
                  ref.read(wsBaseUrlProvider.notifier).state =
                      SettingsStore.wsBaseUrl;
                  await reconnectWs(ref);
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Reset to build defaults')),
                    );
                  }
                },
                child: const Text('Reset'),
              ),
              FilledButton(
                onPressed: () async {
                  final api = apiController.text.trim();
                  final ws = wsController.text.trim();

                  final apiOk = Uri.tryParse(api)?.hasScheme == true;
                  final wsOk = Uri.tryParse(ws)?.hasScheme == true;
                  if (!apiOk || !wsOk) {
                    setState(() => errorText =
                        'Both URLs must include a scheme (http:// or ws://)');
                    return;
                  }

                  await SettingsStore.setApiBaseUrl(api);
                  await SettingsStore.setWsBaseUrl(ws);
                  ref.read(apiBaseUrlProvider.notifier).state = api;
                  ref.read(wsBaseUrlProvider.notifier).state = ws;
                  await reconnectWs(ref);

                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Server updated')),
                    );
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Drop the existing socket so the next connect uses the new WS URL.
///
/// Invalidating disposes the old client (closing its sink — see WsClient.dispose),
/// then we reconnect. Without this the app would keep talking to the old host
/// until restart. Safe to call when not logged in: connect() returns early if
/// there is no access token.
Future<void> reconnectWs(WidgetRef ref) async {
  ref.invalidate(wsClientProvider);
  await ref.read(wsClientProvider).connect();
}
