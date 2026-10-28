// =============================================================================
// SHE V3 — shared device-kind resolver
// =============================================================================
// The firmware registers EVERY relay channel as `esp.device.switch`, so the
// physical role (light vs socket) lives in the device NAME ("Light 1",
// "Socket 1"…). This single implementation is reused by the Devices tab
// (devices_screen.dart) AND the board-detail page (device_detail_screen.dart)
// so the icon/tint mapping never diverges. Do NOT duplicate this logic
// elsewhere — keep the ONE source here.
String kindFromDeviceType(String type, {String name = ''}) {
  // ---- Specific firmware types: unambiguous, trust them first ----
  if (type.contains('lightbulb')) return 'light';
  if (type.contains('fan')) return 'appliance';
  if (type.contains('temp_sensor')) return 'climate';
  if (type.contains('energy_meter')) return 'meter';

  // ---- Relay channels: type is generic, so read the name ----
  // Word-boundary-ish matching on a lowercased name so "Socket 1" and
  // "Power Socket" both resolve to an outlet.
  final n = name.toLowerCase();
  if (n.contains('socket') || n.contains('outlet') || n.contains('plug')) {
    return 'outlet';
  }
  if (n.contains('light') || n.contains('lamp')) return 'light';
  if (n.contains('fan')) return 'appliance';
  if (n.contains('gate') || n.contains('door')) return 'gate';
  if (n.contains('pump') || n.contains('irrigation') || n.contains('water')) {
    return 'irrigation';
  }
  if (n.contains('camera')) return 'camera';
  if (n.contains('tv')) return 'tv';
  if (n.contains('meter')) return 'meter';

  // ---- Generic switch / relay / unknown ----
  if (type.contains('switch') || type.contains('relay')) return 'outlet';
  if (type.contains('sensor')) return 'sensor';
  return 'generic';
}
