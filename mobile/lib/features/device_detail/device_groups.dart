// =============================================================================
// SHE V3 — shared device-group utilities
// =============================================================================
// Custom device groups (backend: node_groups + node_group_members). These are
// used by the dashboard and the group-detail screen. They live in their own
// file so the board-detail page (device_detail_screen.dart) can stay a clean,
// group-free "device page" for a single board while the dashboard keeps its
// group feature.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/media_service.dart';
import '../../core/widgets/she_icon_or_image.dart';
import '../../core/theme/v3_design_tokens.dart';
import 'node_service.dart';

/// Custom device groups for a home (backend: node_groups + node_group_members).
final nodeDeviceGroupsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, homeId) => ref.read(nodeServiceProvider).listDeviceGroups(homeId),
);

class GroupEditResult {
  final String name;
  final List<String> deviceIds;

  /// Bundled icon key for the card. Null → the card derives an icon from the
  /// members' role names, as it always has.
  final String? icon;

  /// Bundled photo key for the detail hero. Null → the hero shows the icon only.
  final String? image;

  const GroupEditResult(this.name, this.deviceIds, {this.icon, this.image});
}

/// Icon keys the group editor offers, mapped to Material glyphs.
///
/// Keys are what get stored (migration V37 stores a short string, not a code
/// point), so they must stay stable — a glyph can change freely, a key cannot.
const Map<String, IconData> kGroupIconChoices = {
  'auto': Icons.auto_awesome_outlined,
  'lights': Icons.lightbulb_outline,
  'sockets': Icons.power_outlined,
  'folder': Icons.folder_special_outlined,
  'bed': Icons.bed_outlined,
  'sofa': Icons.weekend_outlined,
  'kitchen': Icons.kitchen_outlined,
  'garage': Icons.garage_outlined,
  'tv': Icons.tv_outlined,
  'security': Icons.shield_outlined,
  'water': Icons.water_drop_outlined,
  'fan': Icons.mode_fan_off_outlined,
};

/// Bundled photos the group editor offers for the detail hero.
const Map<String, String> kGroupImageChoices = {
  'none': '',
  'home-dusk': 'assets/img/home-dusk.png',
  'living-room': 'assets/img/living-room.png',
  'skyline': 'assets/img/skyline.png',
};

class GroupEditorDialog extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> devices;
  final Map<String, dynamic>? existing;

  const GroupEditorDialog({required this.devices, this.existing});

  @override
  ConsumerState<GroupEditorDialog> createState() => GroupEditorDialogState();
}

class GroupEditorDialogState extends ConsumerState<GroupEditorDialog> {
  late final TextEditingController _name;
  late final Set<String> _selected;

  /// Chosen icon key ('auto' = derive from members) and hero image key
  /// ('none' = no photo). Both default to the existing group's values, or the
  /// permissive defaults for a new group.
  late String _icon;
  late String _image;

  /// Inline validation. The previous build returned silently on an empty name,
  /// which reads exactly like "the Create button does nothing".
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
        text: widget.existing?['name']?.toString() ?? '');
    final raw = (widget.existing?['device_ids'] ??
        widget.existing?['deviceIds']) as List<dynamic>? ?? const <dynamic>[];
    _selected = {...raw.map((e) => e.toString())};
    _icon = widget.existing?['icon']?.toString() ?? 'auto';
    _image = widget.existing?['image']?.toString() ?? 'none';
    // An unknown key (say a future upload URL) must not crash the picker —
    // fall back to the permissive default instead of an unselected state.
    // An UPLOADED value (V41) is a valid choice and must survive the reset.
    if (!kGroupIconChoices.containsKey(_icon) && !MediaUrls.isUploaded(_icon)) {
      _icon = 'auto';
    }
    if (!kGroupImageChoices.containsKey(_image) &&
        !MediaUrls.isUploaded(_image)) {
      _image = 'none';
    }
  }

  /// True while a picker/upload is running.
  bool _uploading = false;

  /// Pick a photo from the gallery and upload it — either as the group's icon
  /// (a 44 px picture instead of a glyph) or as its cover image.
  Future<void> _pickImage({bool asIcon = false}) async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final url = await ref.read(mediaServiceProvider).pickAndUpload(
            maxWidth: asIcon ? 512 : 1600,
          );
      if (!mounted || url == null) return;
      setState(() {
        if (asIcon) {
          _icon = url;
        } else {
          _image = url;
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not upload that image: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Validate, then pop with the result.
  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a group name');
      return;
    }
    // 'auto' / 'none' are UI sentinels meaning "no explicit choice" — send null
    // so the backend leaves the column NULL and the client keeps its fallback.
    Navigator.pop(
      context,
      GroupEditResult(
        name,
        _selected.toList(),
        icon: _icon == 'auto' ? null : _icon,
        // '' (not null) so choosing "None" actually CLEARS a saved image —
        // the API treats null as "leave unchanged".
        image: _image == 'none' ? '' : _image,
      ),
    );
  }

  /// Selectable chip used by the icon + cover-image pickers.
  ///
  /// [label] is optional: a null label renders just the [child] (used for the
  /// icon grid, where the glyph is self-explanatory), while a non-null label
  /// (e.g. "None" for the cover picker) shows a text beside it.
  Widget _Pill({
    required bool selected,
    required String? label,
    required Widget child,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(V3Radius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: V3Spacing.sm, vertical: V3Spacing.xs),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(V3Radius.md),
          color: selected
              ? V3Colors.primary.withValues(alpha: 0.15)
              : V3Colors.background,
          border: Border.all(
            color: selected
                ? V3Colors.primary
                : V3Colors.textSecondary.withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(label!,
                  style: TextStyle(
                    color: selected
                        ? V3Colors.primary
                        : V3Colors.textSecondary,
                    fontSize: 12,
                  )),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final selectable =
        widget.devices.where((d) => !(d['is_service'] ?? false)).toList();

    return Dialog(
      backgroundColor: V3Colors.surface,
      insetPadding: const EdgeInsets.all(V3Spacing.lg),
      child: ConstrainedBox(
        // A hard height cap makes the Flexible below safe: a flex child needs a
        // bounded height, and an AlertDialog does not always provide one — when
        // that failed the device list never laid out, nothing could be ticked,
        // and the group was created with zero members.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          maxWidth: 380,
        ),
        child: Padding(
          padding: const EdgeInsets.all(V3Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isEdit ? 'Edit group' : 'New group',
                  style: TextStyle(
                      color: V3Colors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: V3Spacing.md),
              TextField(
                controller: _name,
                style: TextStyle(color: V3Colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Group name',
                  labelStyle: TextStyle(color: V3Colors.textSecondary),
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: V3Spacing.md),

              // ---- Icon ----
              // Choosing an icon overrides the card's auto-derived glyph; 'auto'
              // keeps the existing behaviour of reading role names off the
              // members. Stored as a key, never a code point (migration V37).
              Text('Icon',
                  style: TextStyle(
                      color: V3Colors.textSecondary,
                      fontSize: V3Typography.captionSize)),
              const SizedBox(height: V3Spacing.xs),
              Wrap(
                spacing: V3Spacing.xs,
                runSpacing: V3Spacing.xs,
                children: [
                  for (final e in kGroupIconChoices.entries)
                    _Pill(
                      selected: _icon == e.key,
                      label: e.key == 'auto' ? null : '',
                      child: Icon(e.value, size: 18),
                      onTap: () => setState(() => _icon = e.key),
                    ),
                  // The user's own picture, in place of a glyph (V41 upload).
                  _Pill(
                    selected: MediaUrls.isUploaded(_icon),
                    label: null,
                    child: MediaUrls.isUploaded(_icon)
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.network(
                              MediaUrls.resolve(_icon),
                              width: 22,
                              height: 22,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Icon(Icons.add_photo_alternate_outlined, size: 18),
                    onTap: () => _pickImage(asIcon: true),
                  ),
                ],
              ),

              const SizedBox(height: V3Spacing.md),

              // ---- Hero image ----
              // 'none' = the detail hero shows the icon only, no photo. The
              // thumbnails are the same bundled assets the Scene detail uses,
              // so a group and a scene of the same room look consistent.
              Text('Cover image',
                  style: TextStyle(
                      color: V3Colors.textSecondary,
                      fontSize: V3Typography.captionSize)),
              const SizedBox(height: V3Spacing.xs),
              Wrap(
                spacing: V3Spacing.xs,
                runSpacing: V3Spacing.xs,
                children: [
                  for (final e in kGroupImageChoices.entries)
                    _Pill(
                      selected: _image == e.key,
                      label: e.key == 'none' ? 'None' : null,
                      child: e.key == 'none'
                          ? const Icon(Icons.block_outlined, size: 18)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.asset(
                                e.value,
                                width: 34,
                                height: 34,
                                fit: BoxFit.cover,
                                // A missing asset must not break the picker.
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.broken_image_outlined,
                                    size: 18),
                              ),
                            ),
                      onTap: () => setState(() => _image = e.key),
                    ),
                  // Upload your own cover (V41).
                  _Pill(
                    selected: MediaUrls.isUploaded(_image),
                    label: null,
                    child: MediaUrls.isUploaded(_image)
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              MediaUrls.resolve(_image),
                              width: 34,
                              height: 34,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.broken_image_outlined,
                                  size: 18),
                            ),
                          )
                        : Icon(Icons.add_photo_alternate_outlined, size: 18),
                    onTap: () => _pickImage(),
                  ),
                ],
              ),

              const SizedBox(height: V3Spacing.md),
              Row(
                children: [
                  Text('Devices (${_selected.length} selected)',
                      style: TextStyle(
                          color: V3Colors.textSecondary,
                          fontSize: V3Typography.captionSize)),
                  const Spacer(),
                  TextButton(
                    onPressed: selectable.isEmpty
                        ? null
                        : () => setState(() {
                              if (_selected.length == selectable.length) {
                                _selected.clear();
                              } else {
                                _selected
                                  ..clear()
                                  ..addAll(
                                      selectable.map((d) => d['id'].toString()));
                              }
                            }),
                    child: Text(
                        _selected.length == selectable.length
                            ? 'Clear all'
                            : 'Select all',
                        style: TextStyle(
                            color: V3Colors.primary, fontSize: 12)),
                  ),
                ],
              ),
              Flexible(
                child: selectable.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(V3Spacing.md),
                        child: Text('No devices found for this home.',
                            style: TextStyle(color: V3Colors.textSecondary)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: selectable.length,
                        itemBuilder: (_, i) {
                          final d = selectable[i];
                          final id = d['id'].toString();
                          final name = d['display_name'] ??
                              d['device_name'] ??
                              'Device';
                          return CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: _selected.contains(id),
                            activeColor: V3Colors.primary,
                            title: Text(name,
                                style: TextStyle(
                                    color: V3Colors.textPrimary,
                                    fontSize: 14)),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            }),
                          );
                        },
                      ),
              ),
              if (_selected.isEmpty)
                Padding(
                  padding: EdgeInsets.only(top: V3Spacing.sm),
                  child: Text('Tick the relays you want in this group.',
                      style: TextStyle(
                          color: V3Colors.warning,
                          fontSize: V3Typography.captionSize)),
                ),
              const SizedBox(height: V3Spacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  const SizedBox(width: V3Spacing.sm),
                  FilledButton(
                    onPressed: _submit,
                    child: Text(isEdit ? 'Save' : 'Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
