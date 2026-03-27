// Add / Edit Event Dialog – shown as a modal bottom sheet.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../data/repositories.dart';
import '../../application/event_service.dart';
import '../../application/space_ownership_service.dart';
import '../../application/user_availability_service.dart';
import '../theme.dart';
import '../helpers/calendar_helpers.dart';

class AddEventDialog extends StatefulWidget {
  final DateTime selectedDate;
  final SpaceOwnershipService ownership;
  final String userOrgId;
  final List<Organization> organizations;
  final UserProfile profile;
  final CalendarEvent? existingEvent;

  const AddEventDialog({
    super.key,
    required this.selectedDate,
    required this.ownership,
    required this.userOrgId,
    required this.organizations,
    required this.profile,
    this.existingEvent,
  });

  @override
  State<AddEventDialog> createState() => _AddEventDialogState();
}

class _AddEventDialogState extends State<AddEventDialog> {
  final _eventService = EventService();
  final _profileRepo = ProfileRepository();
  final _eventRepo = EventRepository();
  final _availabilityService = UserAvailabilityService();

  // Form state
  String _selectedType = EventTypes.all.first;
  String _projectName = '';
  final _titleController = TextEditingController();
  String? _managedLocation;
  bool _blockFoaierWithSala = false;
  final _freeLocationController = TextEditingController();
  bool _isAllDay = false;
  late DateTime _startDate;
  late TimeOfDay _startTime;
  late DateTime _endDate;
  late TimeOfDay _endTime;
  final _detailsController = TextEditingController();
  final _requestMsgController = TextEditingController();
  final List<String> _participants = [];

  // Supplementary state
  List<UserProfile> _orgMembers = [];
  Map<String, BusyInfo> _busyInfo = {};
  Set<String> _titleHistory = {};
  Map<String, Set<String>> _participantHistory = {};
  bool _isSaving = false;
  bool _membersLoaded = false;

  bool get _isEdit => widget.existingEvent != null;

  @override
  void initState() {
    super.initState();
    final ev = widget.existingEvent;
    if (ev != null) {
      _selectedType = EventTypes.isProjectCultural(ev.eventType)
          ? 'Proiect cultural'
          : ev.eventType;
      _projectName = EventTypes.isProjectCultural(ev.eventType)
          ? EventTypes.projectName(ev.eventType)
          : '';
      _titleController.text = ev.title;
      _managedLocation = ManagedLocation.fromString(ev.location)?.displayName;
        _blockFoaierWithSala = ManagedLocation.isSalaWithBlockedFoaier(ev.location);
      _freeLocationController.text = _managedLocation == null ? ev.location : '';
      _isAllDay = ev.isAllDay;
      _startDate = ev.startTime;
      _startTime = TimeOfDay(hour: ev.startTime.hour, minute: ev.startTime.minute);
      _endDate = ev.endTime;
      _endTime = TimeOfDay(hour: ev.endTime.hour, minute: ev.endTime.minute);
      _participants.addAll(ev.participants);
    } else {
      _managedLocation = null;
      _startDate = widget.selectedDate;
      _endDate = widget.selectedDate;
      final hour = widget.selectedDate.hour.clamp(9, 22);
      _startTime = TimeOfDay(hour: hour, minute: 0);
      _endTime = TimeOfDay(hour: (hour + 1).clamp(10, 23), minute: 0);
    }
    _loadMembers();
    _loadHistory();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _freeLocationController.dispose();
    _detailsController.dispose();
    _requestMsgController.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      _orgMembers = await _profileRepo.fetchByOrg(widget.userOrgId);
      _membersLoaded = true;
      _computeBusy();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    try {
      final rows = await _eventRepo.fetchHistory(widget.userOrgId);
      final titles = <String>{};
      final partMap = <String, Set<String>>{};
      for (final r in rows) {
        final t = (r['title'] ?? '').toString().trim();
        if (t.isNotEmpty) titles.add(t);
        final parts = (r['participants'] as List<dynamic>? ?? []);
        if (t.isNotEmpty && parts.isNotEmpty) {
          partMap.putIfAbsent(t, () => {}).addAll(parts.map((p) => p.toString().trim()).where((p) => p.isNotEmpty));
        }
      }
      if (mounted) {
        setState(() {
          _titleHistory = titles;
          _participantHistory = partMap;
        });
      }
    } catch (_) {}
  }

  Future<void> _computeBusy() async {
    if (_orgMembers.isEmpty) return;
    final start = _buildStartDateTime();
    final end = _buildEndDateTime();
    if (!end.isAfter(start)) return;

    final nameToId = <String, String>{};
    for (final m in _orgMembers) {
      nameToId[m.displayName] = m.id;
    }

    try {
      final info = await _availabilityService.computeBusy(
        orgId: widget.userOrgId,
        nameToUserId: nameToId,
        start: start,
        end: end,
        excludeEventId: widget.existingEvent?.id,
      );
      if (mounted) setState(() => _busyInfo = info);
    } catch (_) {}
  }

  DateTime _buildStartDateTime() {
    if (_isAllDay) return DateTime(_startDate.year, _startDate.month, _startDate.day, 0, 0);
    return DateTime(_startDate.year, _startDate.month, _startDate.day, _startTime.hour, _startTime.minute);
  }

  DateTime _buildEndDateTime() {
    if (_isAllDay) return DateTime(_endDate.year, _endDate.month, _endDate.day, 23, 59);
    return DateTime(_endDate.year, _endDate.month, _endDate.day, _endTime.hour, _endTime.minute);
  }

  String get _effectiveEventType {
    if (_selectedType == 'Proiect cultural' && _projectName.trim().isNotEmpty) {
      return 'Proiect cultural/${_projectName.trim()}';
    }
    return _selectedType;
  }

  String get _titleHint {
    final normalizedOrg = _normalizeText(widget.profile.organizationName ?? '');
    if (normalizedOrg.contains('teatrul magic puppet')) return 'Ex: Canon';
    if (normalizedOrg.contains('centrul de creatie maidan')) return 'Ex: Fata din cloud';
    return 'Ex: Eveniment organizație';
  }

  String _normalizeText(String value) {
    return value
        .toLowerCase()
        .replaceAll('ă', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ș', 's')
        .replaceAll('ş', 's')
        .replaceAll('ț', 't')
        .replaceAll('ţ', 't')
        .trim();
  }

  String get _effectiveLocation {
    if (_managedLocation == 'Sala' && _blockFoaierWithSala) {
      return ManagedLocation.salaWithBlockedFoaierLabel;
    }
    if (_managedLocation != null) return _managedLocation!;
    return _freeLocationController.text.trim();
  }

  bool get _hasFreeLocationText => _freeLocationController.text.trim().isNotEmpty;

  // Ownership check for conflict warning
  bool get _hasForeignSegments {
    final loc = ManagedLocation.fromString(_effectiveLocation);
    if (loc == null) return false;
    final segs = widget.ownership.computeSegments(
      start: _buildStartDateTime(),
      end: _buildEndDateTime(),
      location: loc,
      userOrgId: widget.userOrgId,
    );
    return segs.any((s) => !s.isOwn);
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showErrorDialog('Titlul este obligatoriu.');
      return;
    }

    final start = _buildStartDateTime();
    final end = _buildEndDateTime();
    final location = _effectiveLocation;
    if (location.isEmpty) {
      _showErrorDialog('Locația este obligatorie.');
      return;
    }
    if (!end.isAfter(start)) {
      _showErrorDialog('Ora de sfârșit trebuie să fie după ora de început.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      await _eventService.saveEvent(
        existingEventId: widget.existingEvent?.id,
        title: title,
        eventType: _effectiveEventType,
        location: location,
        start: start,
        end: end,
        userOrgId: widget.userOrgId,
        participants: _participants,
        ownership: widget.ownership,
        organizations: widget.organizations,
        requestMessage: _requestMsgController.text.trim(),
        isAllDay: _isAllDay,
      );

      // Send details message if provided
      if (_detailsController.text.trim().isNotEmpty && _participants.isNotEmpty) {
        _sendDetailsToParticipants(title, start, end);
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showErrorDialog('Eroare: $e');
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Atenție'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendDetailsToParticipants(String title, DateTime start, DateTime end) async {
    try {
      final nameToId = <String, String>{};
      for (final m in _orgMembers) {
        nameToId[m.displayName] = m.id;
      }
      final userId = widget.profile.id;
      final date = formatDateRo(start);
      final interval = '${formatCalendarTime(start)}-${formatCalendarTime(end)}';
      final body = 'Detalii pentru "$title" ($date, $interval):\n${_detailsController.text.trim()}';

      final msgRepo = MessageRepository();
      for (final name in _participants) {
        final uid = nameToId[name];
        if (uid == null || uid == userId) continue;
        await msgRepo.send(
          senderId: userId,
          receiverId: uid,
          content: body,
          title: 'Detalii eveniment: $title',
          recipientScope: 'user',
        );
      }
    } catch (_) {}
  }

  Future<void> _deleteEvent() async {
    if (widget.existingEvent == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ștergere eveniment'),
        content: const Text('Sigur dorești să ștergi acest eveniment?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Anulează')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.notification),
            child: const Text('Șterge'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isSaving = true);
    try {
      await _eventService.deleteEvent(widget.existingEvent!.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showErrorDialog('Eroare: $e');
      }
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.88,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) {
          return SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 12),
                // Title bar
                Row(
                  children: [
                    Text(
                      _isEdit ? 'Editare Eveniment' : 'Eveniment Nou',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    if (_isEdit)
                      IconButton(
                        icon: const Icon(Icons.delete, color: AppTheme.notification),
                        onPressed: _isSaving ? null : _deleteEvent,
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                // Event type
                _buildLabel('Tip eveniment'),
                DropdownButtonFormField<String>(
                  initialValue: EventTypes.all.contains(_selectedType) ? _selectedType : EventTypes.all.first,
                  isExpanded: true,
                  decoration: _inputDecoration(),
                  items: EventTypes.all
                      .map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 14))))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedType = v);
                  },
                ),
                // Project name (conditional)
                if (_selectedType == 'Proiect cultural') ...[
                  const SizedBox(height: 8),
                  _buildLabel('Denumire proiect'),
                  TextFormField(
                    initialValue: _projectName,
                    decoration: _inputDecoration(hint: 'Numele proiectului'),
                    onChanged: (v) => _projectName = v,
                  ),
                ],
                const SizedBox(height: 12),

                // Title with autocomplete
                _buildLabel('Titlu'),
                Autocomplete<String>(
                  initialValue: TextEditingValue(text: _titleController.text),
                  optionsBuilder: (value) {
                    if (value.text.isEmpty) return const Iterable.empty();
                    final query = value.text.toLowerCase();
                    return _titleHistory.where((t) => t.toLowerCase().contains(query));
                  },
                  onSelected: (value) {
                    _titleController.text = value;
                    // Auto-add participants from history
                    final histPart = _participantHistory[value];
                    if (histPart != null && histPart.isNotEmpty) {
                      setState(() {
                        for (final p in histPart) {
                          if (!_participants.contains(p)) _participants.add(p);
                        }
                      });
                    }
                    _computeBusy();
                  },
                  fieldViewBuilder: (_, controller, focusNode, onFieldSubmitted) {
                    // Keep controllers in sync
                    if (controller.text != _titleController.text && _titleController.text.isNotEmpty) {
                      controller.text = _titleController.text;
                    }
                    _titleController.addListener(() {
                      if (controller.text != _titleController.text) {
                        controller.text = _titleController.text;
                      }
                    });
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: _inputDecoration(hint: _titleHint),
                      onChanged: (v) => _titleController.text = v,
                    );
                  },
                ),
                const SizedBox(height: 12),

                // Location
                _buildLabel('Locație'),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Sala', label: Text('Sala')),
                    ButtonSegment(value: 'Foaier', label: Text('Foaier')),
                  ],
                  selected: {...?(_managedLocation == null ? null : {_managedLocation!})},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (v) {
                    setState(() {
                      _managedLocation = v.isEmpty ? null : v.first;
                      if (_managedLocation != null) {
                        _freeLocationController.clear();
                      }
                      if (_managedLocation != 'Sala') {
                        _blockFoaierWithSala = false;
                      }
                    });
                  },
                ),
                if (_managedLocation == 'Sala')
                  CheckboxListTile(
                    value: _blockFoaierWithSala,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text(
                      'Marchează și Foaierul ocupat (fără eveniment separat)',
                      style: TextStyle(fontSize: 13),
                    ),
                    onChanged: (v) {
                      setState(() => _blockFoaierWithSala = v ?? false);
                    },
                  ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _freeLocationController,
                  enabled: _managedLocation == null,
                  decoration: _inputDecoration(hint: 'Locație liberă (opțional)').copyWith(
                    suffixIcon: IconButton(
                      tooltip: 'Deschide în Google Maps',
                      icon: const Icon(Icons.map_outlined),
                      onPressed: _managedLocation != null
                          ? null
                          : () async {
                        final query = _freeLocationController.text.trim();
                        if (query.isEmpty) return;
                        final uri = Uri.parse(
                          'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(query)}',
                        );
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      },
                    ),
                  ),
                  onChanged: (value) {
                    if (!mounted) return;
                    setState(() {});
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  _hasFreeLocationText
                      ? 'Cu locație liberă, opțiunea Sală/Foaier este inactivă și evenimentul apare doar în Evenimente organizație.'
                      : _managedLocation != null
                      ? 'Cu Sală/Foaier selectat, evenimentul respectă regulile de gestiune spațiu și apare și în Program Sală.'
                      : 'Fără Sală/Foaier, evenimentul este cu locație liberă și apare doar în Evenimente organizație.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 12),

                // All-day toggle
                SwitchListTile(
                  title: const Text('Toată ziua', style: TextStyle(fontSize: 14)),
                  value: _isAllDay,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    setState(() => _isAllDay = v);
                    _computeBusy();
                  },
                ),

                // Date/time pickers
                if (_isAllDay) _buildAllDayPickers() else _buildTimePickers(),
                const SizedBox(height: 12),

                // Conflict warning
                if (_hasForeignSegments) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceElevated,
                      border: Border.all(color: AppTheme.border),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber, color: AppTheme.notification, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Intervalul selectat acoperă timp gestionat de altă organizație. Va fi creată o cerere.',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildLabel('Mesaj cerere (opțional)'),
                  TextFormField(
                    controller: _requestMsgController,
                    decoration: _inputDecoration(hint: 'Motivul cererii...'),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                ],

                // Details
                _buildLabel('Detalii (trimise participanților)'),
                TextFormField(
                  controller: _detailsController,
                  decoration: _inputDecoration(hint: 'Informații suplimentare...'),
                  maxLines: 3,
                ),
                const SizedBox(height: 16),

                // Members section
                _buildMembersSection(),
                const SizedBox(height: 20),

                // Action buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Anulează'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _isSaving ? null : _save,
                      child: _isSaving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(_isEdit ? 'Actualizează' : 'Salvează'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Sub-builders ──

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
    );
  }

  InputDecoration _inputDecoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    );
  }

  Widget _buildAllDayPickers() {
    return Row(
      children: [
        Expanded(
          child: _DatePickerField(
            label: 'De la',
            value: _startDate,
            onChanged: (d) {
              setState(() {
                _startDate = d;
                if (_endDate.isBefore(_startDate)) _endDate = _startDate;
              });
              _computeBusy();
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _DatePickerField(
            label: 'Până la',
            value: _endDate,
            onChanged: (d) {
              setState(() => _endDate = d);
              _computeBusy();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTimePickers() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _DatePickerField(
                label: 'Data',
                value: _startDate,
                onChanged: (d) {
                  setState(() {
                    _startDate = d;
                    _endDate = d;
                  });
                  _computeBusy();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TimePickerField(
                label: 'Ora început',
                value: _startTime,
                onChanged: (t) {
                  setState(() => _startTime = t);
                  _computeBusy();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TimePickerField(
                label: 'Ora sfârșit',
                value: _endTime,
                onChanged: (t) {
                  setState(() => _endTime = t);
                  _computeBusy();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMembersSection() {
    if (!_membersLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    final available = _orgMembers.where((m) => !_participants.contains(m.displayName)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildLabel('Participanți'),
            const Spacer(),
            if (available.isNotEmpty)
              PopupMenuButton<String>(
                icon: const Icon(Icons.person_add, size: 20),
                tooltip: 'Adaugă participant',
                onSelected: (name) {
                  setState(() => _participants.add(name));
                  _computeBusy();
                },
                itemBuilder: (_) => available.map((m) {
                  final busy = _busyInfo[m.displayName];
                  return PopupMenuItem(
                    value: m.displayName,
                    child: Row(
                      children: [
                        if (busy != null)
                          Container(
                            width: 8, height: 8,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: AppTheme.memberColor(busy.ratio),
                              shape: BoxShape.circle,
                            ),
                          ),
                        Expanded(child: Text(m.displayName, style: const TextStyle(fontSize: 13))),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
        // Participant chips
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: _participants.map((name) {
            final busy = _busyInfo[name];
            return Chip(
              label: Text(name, style: const TextStyle(fontSize: 12)),
              avatar: busy != null
                  ? CircleAvatar(backgroundColor: AppTheme.memberColor(busy.ratio), radius: 8)
                  : null,
              deleteIcon: const Icon(Icons.close, size: 14),
              onDeleted: () {
                setState(() => _participants.remove(name));
                _computeBusy();
              },
              visualDensity: VisualDensity.compact,
            );
          }).toList(),
        ),
        if (_participants.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Niciun participant adăugat.', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ),
      ],
    );
  }
}

// ── Date picker field ──

class _DatePickerField extends StatelessWidget {
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  const _DatePickerField({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime(2030),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
        child: Text(formatDateRo(value), style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}

// ── Time picker field ──

class _TimePickerField extends StatelessWidget {
  final String label;
  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onChanged;

  const _TimePickerField({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: value);
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
        child: Text(
          '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }
}
