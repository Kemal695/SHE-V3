// =============================================================================
// SHE V3 — Network constants
// =============================================================================
// V3-API-SPECIFICATION §1.
// =============================================================================

class ApiConstants {
  // ---- Base URLs (overridable via --dart-define) ----
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',   // Proxied to PC via adb reverse
  );
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://10.0.2.2:8080',
  );

  // ---- API paths (V3-API-SPECIFICATION) ----
  static const String apiPrefix = '/api/v3';

  // Auth
  static const String authRegister = '$apiPrefix/auth/register';
  static const String authLogin = '$apiPrefix/auth/login';
  static const String authRefresh = '$apiPrefix/auth/refresh';
  static const String authLogout = '$apiPrefix/auth/logout';
  static const String authMe = '$apiPrefix/auth/me';

  // Homes + rooms + members
  static const String homes = '$apiPrefix/homes';
  static String homeRooms(String homeId) => '$apiPrefix/homes/$homeId/rooms';
  static String homeMembers(String homeId) => '$apiPrefix/homes/$homeId/members';
  static String homeNodes(String homeId) => '$apiPrefix/homes/$homeId/nodes';

  // Nodes (V3-API-SPECIFICATION §6)
  static const String nodes = '$apiPrefix/nodes';
  static String node(String id) => '$apiPrefix/nodes/$id';
  static String nodeDevices(String id) => '$apiPrefix/nodes/$id/devices';
  static String nodeParams(String nodeId, String deviceId) =>
      '$apiPrefix/nodes/$nodeId/devices/$deviceId/params';
  static String nodeTelemetry(String id) => '$apiPrefix/nodes/$id/telemetry';
  static String nodeEnergy(String id) => '$apiPrefix/nodes/$id/energy';
  static String nodeCommands(String id) => '$apiPrefix/nodes/$id/commands';
  static const String nodeClaim = '$apiPrefix/nodes/claim';

  // Device groups + device rename (custom device groups, migration V36)
  static String homeDeviceGroups(String homeId) =>
      '$apiPrefix/homes/$homeId/device-groups';
  static String deviceGroup(String id) => '$apiPrefix/device-groups/$id';
  static String deviceGroupSet(String id) => '$apiPrefix/device-groups/$id/set';
  static String nodeDevice(String nodeId, String deviceId) =>
      '$apiPrefix/nodes/$nodeId/devices/$deviceId';

  // Scenes (V3-API-SPECIFICATION §8.1)
  static String homeScenes(String homeId) => '$apiPrefix/homes/$homeId/scenes';
  static String scene(String id) => '$apiPrefix/scenes/$id';
  static String sceneActivate(String id) => '$apiPrefix/scenes/$id/activate';

  // Automations (V3-API-SPECIFICATION §7)
  static String homeAutomations(String homeId) => '$apiPrefix/homes/$homeId/automations';
  static String automation(String id) => '$apiPrefix/automations/$id';
  static String automationEnabled(String id) => '$apiPrefix/automations/$id/enabled';
  static String automationTrigger(String id) => '$apiPrefix/automations/$id/trigger';

  // OTA (V3-API-SPECIFICATION §9)
  static String otaBatches(String homeId) => '$apiPrefix/homes/$homeId/ota/batches';

  // Payments + subscriptions (V3-PAYMENTS §3, ADR-005)
  static const String paymentsInitiate = '$apiPrefix/payments/initiate';
  static const String paymentsVerify = '$apiPrefix/payments/verify';   // + /{txRef}
  static const String subscriptionsCurrent = '$apiPrefix/subscriptions/current';

  // WebSocket
  static const String wsPath = '/ws/v3';

  // ---- Headers ----
  static const String authorization = 'Authorization';
  static const String contentType = 'Content-Type';
  static const String applicationJson = 'application/json';
  static const String requestId = 'X-Request-Id';
  static const String idempotencyKey = 'Idempotency-Key';
}

class WsEventTypes {
  static const String nodeState = 'node.state';
  static const String nodeTelemetry = 'node.telemetry';
  static const String nodePresence = 'node.presence';
  static const String energyUpdate = 'energy.update';
  static const String otaProgress = 'ota.progress';
  static const String sceneActivated = 'scene.activated';
  static const String automationTriggered = 'automation.triggered';
  static const String notificationReceived = 'notification.received';
}
