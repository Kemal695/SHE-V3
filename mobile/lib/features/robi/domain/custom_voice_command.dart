// =============================================================================
// SHE V3 — User-defined voice command
// =============================================================================
// A phrase mapped to an action. Two uses:
//   * alias  — "socket one"            -> turn on Socket 1
//   * macro  — "goodnight"             -> turn off all lights
//
// `hidden` keeps it out of the list unless the page is unlocked, so someone
// browsing the app cannot read the phrase. `locked` forces a confirmation before
// it runs, so even someone who knows the phrase cannot fire it silently.
//
// The payload stores NAMES/IDS, not live objects, so it survives a rename of the
// home's devices: it is resolved against the current device/group/scene/
// automation list at parse time, and simply does not match if the target is gone.
// =============================================================================

class CustomVoiceCommand {
  final String id;

  /// What the user says, e.g. "goodnight" or "turn on socket one".
  final String phrase;

  /// `VoiceAction.name`: turnOn, turnOff, turnAllOn, turnAllOff, turnOnGroup,
  /// turnOffGroup, activateScene, runAutomation, enableAutomation,
  /// disableAutomation.
  final String action;

  /// Device actions: the firmware name or display label to resolve.
  final String? deviceName;

  /// Group actions: the group id (preferred) and/or name.
  final String? groupId;
  final String? groupName;

  /// Scene action.
  final String? sceneId;

  /// Automation actions.
  final String? automationId;

  /// Class actions: 'lights' | 'sockets' | 'all'.
  final String? group;

  final bool enabled;
  final bool hidden;
  final bool locked;

  const CustomVoiceCommand({
    required this.id,
    required this.phrase,
    required this.action,
    this.deviceName,
    this.groupId,
    this.groupName,
    this.sceneId,
    this.automationId,
    this.group,
    this.enabled = true,
    this.hidden = false,
    this.locked = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'phrase': phrase,
        'action': action,
        if (deviceName != null) 'deviceName': deviceName,
        if (groupId != null) 'groupId': groupId,
        if (groupName != null) 'groupName': groupName,
        if (sceneId != null) 'sceneId': sceneId,
        if (automationId != null) 'automationId': automationId,
        if (group != null) 'group': group,
        'enabled': enabled,
        'hidden': hidden,
        'locked': locked,
      };

  factory CustomVoiceCommand.fromJson(Map<String, dynamic> j) =>
      CustomVoiceCommand(
        id: j['id']?.toString() ?? '',
        phrase: j['phrase']?.toString() ?? '',
        action: j['action']?.toString() ?? '',
        deviceName: j['deviceName']?.toString(),
        groupId: j['groupId']?.toString(),
        groupName: j['groupName']?.toString(),
        sceneId: j['sceneId']?.toString(),
        automationId: j['automationId']?.toString(),
        group: j['group']?.toString(),
        enabled: j['enabled'] != false,
        hidden: j['hidden'] == true,
        locked: j['locked'] == true,
      );

  CustomVoiceCommand copyWith({
    String? phrase,
    String? action,
    String? deviceName,
    String? groupId,
    String? groupName,
    String? sceneId,
    String? automationId,
    String? group,
    bool? enabled,
    bool? hidden,
    bool? locked,
  }) =>
      CustomVoiceCommand(
        id: id,
        phrase: phrase ?? this.phrase,
        action: action ?? this.action,
        deviceName: deviceName ?? this.deviceName,
        groupId: groupId ?? this.groupId,
        groupName: groupName ?? this.groupName,
        sceneId: sceneId ?? this.sceneId,
        automationId: automationId ?? this.automationId,
        group: group ?? this.group,
        enabled: enabled ?? this.enabled,
        hidden: hidden ?? this.hidden,
        locked: locked ?? this.locked,
      );
}
