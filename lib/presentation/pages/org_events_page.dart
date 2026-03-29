// Organization Events Page – Calendarul organizației sau personal.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../data/repositories.dart';
import '../../application/space_ownership_service.dart';
import '../../application/google_calendar_service.dart';
import '../helpers/calendar_helpers.dart';
import '../theme.dart';
import '../widgets/appointment_card.dart';
import '../dialogs/add_event_dialog.dart';

class OrgEventsPage extends StatefulWidget {
  final bool personalMode;
  const OrgEventsPage({super.key, this.personalMode = false});

  @override
  State<OrgEventsPage> createState() => _OrgEventsPageState();
}

class _OrgEventsPageState extends State<OrgEventsPage> {
  // ── Repos & Services ──
  final _eventRepo = EventRepository();
  final _requestRepo = RequestRepository();
  final _scheduleRepo = ScheduleRepository();
  final _orgRepo = OrganizationRepository();
  final _profileRepo = ProfileRepository();
  final _googleSync = const GoogleCalendarService();

  // ── State ──
  final CalendarController _calendarCtrl = CalendarController();
  List<Organization> _organizations = [];
  List<CalendarEvent> _events = [];
  List<EventRequest> _requests = [];
  UserProfile? _profile;
  SpaceOwnershipService? _ownership;

  List<Appointment> _appointments = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _syncProgressDialogOpen = false;
  String? _filterType;
  String _currentView = 'Săptămână';
  DateTime? _selectedMonthDay;
  List<DateTime> _visibleDates = [];
  double _viewHeaderHeight = -1;

  StreamSubscription? _realtimeSub;

  String? get _magicId => _ownership?.magicId;
  String? get _userOrgId => _profile?.organizationId;
  UserRole get _userRole => _profile?.role ?? UserRole.utilizator;
  bool get _isPhone => MediaQuery.of(context).size.width < 600;

  @override
  void initState() {
    super.initState();
    _calendarCtrl.view = CalendarView.week;
    _fetchData();
    _setupRealtime();
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    _calendarCtrl.dispose();
    super.dispose();
  }

  void _setupRealtime() {
    _realtimeSub = Supabase.instance.client
        .from('events')
        .stream(primaryKey: ['id'])
        .listen((_) {
          if (mounted) _fetchData();
        });
  }

  Future<void> _fetchData() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser!.id;
      final orgs = await _orgRepo.fetchAll();
      final anchors = await _scheduleRepo.fetchAnchors();
      final overrides = await _scheduleRepo.fetchOverrides();
      final profile = await _profileRepo.fetchById(userId);
      final orgId = profile.organizationId ?? '';

      List<CalendarEvent> events;
      List<EventRequest> requests;

      if (widget.personalMode) {
        // Personal mode: show events where user is a participant or owner
        final allEvents = await _eventRepo.fetchAll();
        final userName = profile.displayName;
        final aliases = {userName, profile.fullName, '${profile.firstName} ${profile.lastName}'.trim()}
          ..removeWhere((s) => s.isEmpty);

        events = allEvents.where((e) {
          if (e.scope == EventScope.personal && e.ownerUserId == userId) return true;
          if (e.scope == EventScope.personal && e.createdBy == userId) return true;
          for (final alias in aliases) {
            if (e.participants.any((p) => p.toLowerCase() == alias.toLowerCase())) return true;
          }
          return false;
        }).toList();
        requests = [];
      } else {
        // Org mode
        events = await _eventRepo.fetchByOrg(orgId);
        final allReqs = await _requestRepo.fetchForOrg(orgId);
        requests = allReqs.where((r) => r.status == RequestStatus.open).toList();
      }

      _organizations = orgs;
      _events = events;
      _requests = requests;
      _profile = profile;

      _ownership = SpaceOwnershipService(
        organizations: orgs,
        anchors: anchors,
        overrides: overrides,
        events: events,
      );

      _buildAppointments();
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('OrgEventsPage._fetchData error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _buildAppointments() {
    final all = <Appointment>[];

    for (final event in _events) {
      // Filter
      if (_filterType != null && !matchesEventFilter(event.eventType, _filterType)) continue;

      final orgName = _ownership?.orgNameById(event.organizationId) ?? '';

      final isAllDay = event.isAllDay;
      final isImportedGoogle = event.isImportedGoogle;
      all.add(Appointment(
        id: 'event_${event.id}',
        startTime: isAllDay ? event.calendarDisplayStart : event.startTime,
        endTime: isAllDay ? event.calendarDisplayEnd : event.endTime,
        isAllDay: isAllDay,
        subject: buildCalendarSubject(
          isRequest: false,
          type: isImportedGoogle ? '[G]' : EventTypes.displayLabel(event.eventType, fallback: event.title),
          title: event.title,
          organization: orgName,
          location: event.location,
        ),
        color: isImportedGoogle
            ? AppTheme.googleImportedEvent
            : AppTheme.eventColorForOrgAndType(
                orgId: event.organizationId,
                magicId: _magicId,
                eventType: event.eventType,
              ),
        notes: 'event',
      ));
    }

    // Requests
    for (final req in _requests) {
      if (_filterType != null && !matchesEventFilter(req.displayType, _filterType)) continue;

      final isCreatedByMe = req.requestedByOrgId == _userOrgId;
      final orgName = req.requestedByOrgId != null
          ? (_ownership?.orgNameById(req.requestedByOrgId!) ?? '')
          : '';

      all.add(Appointment(
        id: 'req_${req.id}',
        startTime: req.requestedStart,
        endTime: req.requestedEnd,
        isAllDay: CalendarEvent.isAllDayRange(req.requestedStart, req.requestedEnd),
        subject: buildCalendarSubject(
          isRequest: true,
          type: EventTypes.displayLabel(req.displayType, fallback: req.displayTitle),
          title: req.displayTitle,
          organization: orgName,
          location: req.eventLocation ?? '',
        ),
        color: AppTheme.requestColor(isCreatedByMe: isCreatedByMe),
        notes: 'request',
      ));
    }

    _appointments = _mergeConsecutiveFullDayAppointments(all);
  }

  List<Appointment> _mergeConsecutiveFullDayAppointments(List<Appointment> input) {
    final fullDay = <Appointment>[];
    final rest = <Appointment>[];
    for (final app in input) {
      if (app.isAllDay && shouldDisplayInAllDayPanel(app.startTime, app.endTime, explicitAllDay: true)) {
        fullDay.add(app);
      } else {
        rest.add(app);
      }
    }

    if (fullDay.length < 2) return input;

    fullDay.sort((a, b) => a.startTime.compareTo(b.startTime));
    final merged = <Appointment>[fullDay.first];
    for (int i = 1; i < fullDay.length; i++) {
      final last = merged.last;
      final cur = fullDay[i];
      final nextDay = DateTime(last.endTime.year, last.endTime.month, last.endTime.day)
          .add(const Duration(days: 1));
      final curDay = DateTime(cur.startTime.year, cur.startTime.month, cur.startTime.day);

      if (curDay.isAtSameMomentAs(nextDay) &&
          cur.subject == last.subject &&
          cur.color == last.color &&
          cur.notes == last.notes) {
        merged[merged.length - 1] = Appointment(
          id: last.id,
          startTime: last.startTime,
          endTime: cur.endTime,
          isAllDay: true,
          subject: last.subject,
          color: last.color,
          notes: last.notes,
        );
      } else {
        merged.add(cur);
      }
    }
    return [...rest, ...merged];
  }

  void _onCalendarTapped(CalendarTapDetails details) {
    if (details.targetElement == CalendarElement.appointment) {
      final app = details.appointments!.first as Appointment;
      _handleAppointmentTap(app);
    } else if (details.targetElement == CalendarElement.calendarCell) {
      if (_calendarCtrl.view == CalendarView.month) {
        setState(() => _selectedMonthDay = details.date);
      } else if (_userRole.canCreateOrgEvents && !widget.personalMode) {
        _openAddEventDialog(details.date ?? DateTime.now());
      }
    }
  }

  void _handleAppointmentTap(Appointment app) async {
    final id = app.id?.toString() ?? '';

    if (widget.personalMode) {
      _showReadOnlyDialog(app);
      return;
    }

    if (id.startsWith('event_')) {
      final eventId = id.replaceFirst('event_', '');
      if (_userRole.canCreateOrgEvents) {
        _openEditEventDialog(eventId);
      } else {
        _showReadOnlyDialog(app);
      }
    } else if (id.startsWith('req_')) {
      final reqId = id.replaceFirst('req_', '');
      _showSimpleRequestDialog(reqId);
    }
  }

  void _showReadOnlyDialog(Appointment app) {
    final meta = parseCalendarSubject(app.subject);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(meta.title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tip: ${meta.type}'),
            const SizedBox(height: 4),
            Text('Interval: ${formatCalendarTime(app.startTime)}-${formatCalendarTime(app.endTime)}'),
            if (meta.organization.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Organizație: ${meta.organization}'),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ÎNCHIDE'))],
      ),
    );
  }

  void _showSimpleRequestDialog(String reqId) {
    final req = _requests.firstWhere((r) => r.id == reqId, orElse: () => _requests.first);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(req.displayTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tip: ${req.displayType}'),
            Text('Interval: ${formatCalendarTime(req.requestedStart)}-${formatCalendarTime(req.requestedEnd)}'),
            if (req.message != null && req.message!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Mesaj: ${req.message}'),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ÎNCHIDE'))],
      ),
    );
  }

  void _openAddEventDialog(DateTime date) async {
    if (_ownership == null || _profile == null) return;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddEventDialog(
        selectedDate: date,
        ownership: _ownership!,
        userOrgId: _userOrgId!,
        organizations: _organizations,
        profile: _profile!,
      ),
    );
    if (result == true) _fetchData();
  }

  void _openEditEventDialog(String eventId) async {
    if (_ownership == null || _profile == null) return;
    try {
      final event = await _eventRepo.fetchById(eventId);
      if (!mounted) return;
      final result = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => AddEventDialog(
          selectedDate: event.startTime,
          ownership: _ownership!,
          userOrgId: _userOrgId!,
          organizations: _organizations,
          profile: _profile!,
          existingEvent: event,
        ),
      );
      if (result == true) _fetchData();
    } catch (e) {
      if (mounted) {
        await _showPersistentStatusDialog(
          title: 'Eroare',
          message: 'Eroare: $e',
          isError: true,
        );
      }
    }
  }

  Future<void> _showPersistentStatusDialog({
    required String title,
    required String message,
    bool isError = false,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: isError ? AppTheme.notification : AppTheme.magicPrimary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSyncProgressDialog() async {
    if (!mounted || _syncProgressDialogOpen) return;
    _syncProgressDialogOpen = true;
    unawaited(showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Sincronizare în curs'),
          content: const Row(
            children: [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Expanded(child: Text('Se procesează evenimentele Google Calendar...')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _syncProgressDialogOpen = false;
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: const Text('Închide'),
            ),
          ],
        ),
      ),
    ));
  }

  void _closeSyncProgressDialogIfOpen() {
    if (!mounted || !_syncProgressDialogOpen) return;
    _syncProgressDialogOpen = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _syncNow() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    await _showSyncProgressDialog();

    try {
      final Map<String, dynamic> result;
      if (widget.personalMode) {
        result = await _googleSync.syncPersonalEvents();
      } else {
        result = await _googleSync.syncOrganizationEvents(organizationId: _userOrgId ?? '');
      }

      final ok = result['ok'] == true;
      final msg = (result['message'] ?? (ok ? 'Sincronizare completă.' : 'Eroare necunoscută.')).toString();

      // Handle auth redirect
      final authUrl = result['auth_url']?.toString();
      if (authUrl != null && authUrl.isNotEmpty) {
        final uri = Uri.tryParse(authUrl);
        if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
      }

      if (mounted) {
        _closeSyncProgressDialogIfOpen();
        await _showPersistentStatusDialog(
          title: ok ? 'Sincronizare finalizată' : 'Sincronizare cu probleme',
          message: msg,
          isError: !ok,
        );
      }
      if (ok) _fetchData();
    } catch (e) {
      if (mounted) {
        _closeSyncProgressDialogIfOpen();
        await _showPersistentStatusDialog(
          title: 'Eroare sincronizare',
          message: '$e',
          isError: true,
        );
      }
    } finally {
      _closeSyncProgressDialogIfOpen();
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _cleanupTestWeek() async {
    if (_isSyncing || widget.personalMode || _userRole != UserRole.admin) return;
    setState(() => _isSyncing = true);
    await _showSyncProgressDialog();

    try {
      DateTime weekStart;
      DateTime weekEnd;

      if (_visibleDates.isNotEmpty) {
        final sorted = [..._visibleDates]..sort((a, b) => a.compareTo(b));
        weekStart = DateTime(sorted.first.year, sorted.first.month, sorted.first.day);
        weekEnd = DateTime(sorted.last.year, sorted.last.month, sorted.last.day, 23, 59, 59);
      } else {
        final now = DateTime.now();
        weekStart = DateTime(now.year, now.month, now.day);
        weekEnd = weekStart.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
      }

      final result = await _googleSync.cleanupTestWeek(
        scope: widget.personalMode ? GoogleSyncScope.personal : GoogleSyncScope.organization,
        organizationId: widget.personalMode ? null : (_userOrgId ?? ''),
        weekStart: weekStart,
        weekEnd: weekEnd,
        cleanupLocalOlderThanDays: 7,
      );

      final ok = result['ok'] == true;
      final msg = (result['message'] ?? (ok ? 'Curățare finalizată.' : 'Eroare necunoscută.')).toString();
      if (mounted) {
        _closeSyncProgressDialogIfOpen();
        await _showPersistentStatusDialog(
          title: ok ? 'Curățare test finalizată' : 'Curățare test cu probleme',
          message: msg,
          isError: !ok,
        );
      }
      if (ok) _fetchData();
    } catch (e) {
      if (mounted) {
        _closeSyncProgressDialogIfOpen();
        await _showPersistentStatusDialog(
          title: 'Eroare curățare test',
          message: '$e',
          isError: true,
        );
      }
    } finally {
      _closeSyncProgressDialogIfOpen();
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  void _switchView(String viewName) {
    CalendarView view;
    switch (viewName) {
      case 'Zi':
        view = CalendarView.day;
        break;
      case 'Lună':
        view = CalendarView.month;
        break;
      default:
        view = CalendarView.week;
    }
    setState(() {
      _currentView = viewName;
      _calendarCtrl.view = view;
      _selectedMonthDay = null;
    });
  }

  double _computeViewHeaderHeight() {
    if (_calendarCtrl.view == CalendarView.month) return -1;
    final cell = _isPhone ? 44.0 : 56.0;
    final header = _isPhone ? 34.0 : 38.0;

    int count = 0;
    for (final app in _appointments) {
      if (app.isAllDay || shouldDisplayInAllDayPanel(app.startTime, app.endTime)) {
        for (final d in _visibleDates) {
          final dayStart = DateTime(d.year, d.month, d.day);
          final dayEnd = dayStart.add(const Duration(days: 1));
          if (app.startTime.isBefore(dayEnd) && app.endTime.isAfter(dayStart)) {
            count++;
            break;
          }
        }
      }
    }

    final effective = count.clamp(0, 6);
    if (effective == 0) return header;
    return header + cell * (0.5 + 0.5 * effective).clamp(1.0, 4.0);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final title = widget.personalMode ? 'Evenimente Personale' : 'Evenimente Organizație';

    return Scaffold(
      backgroundColor: AppTheme.appBg,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (!widget.personalMode && _userRole == UserRole.admin)
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined),
              tooltip: 'Curățare test (săptămână + evenimente locale > 7 zile)',
              onPressed: _cleanupTestWeek,
            ),
          // Sync button
          _isSyncing
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: 'Sincronizare Google Calendar',
                  onPressed: _syncNow,
                ),
          // Filter
          PopupMenuButton<String?>(
            icon: Icon(
              Icons.filter_list,
              color: _filterType != null ? AppTheme.magicPrimary : null,
            ),
            onSelected: (v) {
              setState(() {
                _filterType = v;
                _buildAppointments();
              });
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('Toate tipurile')),
              ...EventTypes.all.map((t) => PopupMenuItem(value: t, child: Text(t))),
            ],
          ),
          // View switcher
          PopupMenuButton<String>(
            initialValue: _currentView,
            onSelected: _switchView,
            icon: const Icon(Icons.view_agenda),
            itemBuilder: (_) => ['Zi', 'Săptămână', 'Lună']
                .map((v) => PopupMenuItem(value: v, child: Text(v)))
                .toList(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchData,
        child: Column(
          children: [
            if (_filterType != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                color: AppTheme.surfaceElevated,
                child: Row(
                  children: [
                    Text('Filtru: $_filterType', style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() {
                        _filterType = null;
                        _buildAppointments();
                      }),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _currentView == 'Zi' ? _buildDayViewLayout() : _buildCalendarOnly(),
            ),
            if (_currentView == 'Lună' && _selectedMonthDay != null) _buildMonthDayPanel(),
          ],
        ),
      ),
      floatingActionButton: _userRole.canCreateOrgEvents && !widget.personalMode
          ? FloatingActionButton(
              onPressed: () => _openAddEventDialog(DateTime.now()),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildCalendarOnly() {
    return _buildCalendarWidget();
  }

  Widget _buildDayViewLayout() {
    final miniCalendar = _buildMiniCalendar();
    final calendar = Expanded(child: _buildCalendarWidget());

    if (_isPhone) {
      return Column(children: [SizedBox(height: 140, child: miniCalendar), calendar]);
    }
    return Row(children: [SizedBox(width: 120, child: miniCalendar), calendar]);
  }

  Widget _buildMiniCalendar() {
    final now = DateTime.now();
    final displayDate = _calendarCtrl.displayDate ?? now;
    final firstOfMonth = DateTime(displayDate.year, displayDate.month, 1);
    final daysInMonth = DateTime(displayDate.year, displayDate.month + 1, 0).day;
    final startWeekday = firstOfMonth.weekday;

    return Container(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          Text(
            '${roMonthNames[displayDate.month - 1]} ${displayDate.year}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: roDayNamesShort
                .map((d) => SizedBox(
                      width: 14,
                      child: Text(d, textAlign: TextAlign.center, style: const TextStyle(fontSize: 8, color: AppTheme.textMuted)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7),
              itemCount: daysInMonth + startWeekday - 1,
              physics: const NeverScrollableScrollPhysics(),
              itemBuilder: (_, index) {
                if (index < startWeekday - 1) return const SizedBox.shrink();
                final day = index - startWeekday + 2;
                final date = DateTime(displayDate.year, displayDate.month, day);
                final selected = _calendarCtrl.selectedDate;
                final isSelected = selected != null &&
                    selected.year == date.year && selected.month == date.month && selected.day == date.day;
                final isToday = date.year == now.year && date.month == now.month && date.day == now.day;

                return GestureDetector(
                  onTap: () {
                    _calendarCtrl.selectedDate = date;
                    _calendarCtrl.displayDate = date;
                    setState(() {});
                  },
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.surfaceElevated
                          : (isToday ? Colors.white.withAlpha(18) : Colors.transparent),
                      border: Border.all(
                        color: isSelected ? AppTheme.textPrimary.withAlpha(120) : AppTheme.border,
                        width: 0.7,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$day',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isSelected || isToday ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? AppTheme.textPrimary : AppTheme.textMuted,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarWidget() {
    final isPhone = _isPhone;
    return SfCalendar(
      controller: _calendarCtrl,
      dataSource: _OrgAppointmentSource(_appointments),
      firstDayOfWeek: 1,
      showNavigationArrow: true,
      showDatePickerButton: true,
      viewHeaderHeight: _viewHeaderHeight,
      timeSlotViewSettings: TimeSlotViewSettings(
        startHour: 0,
        endHour: 24,
        timeIntervalHeight: isPhone ? 52 : 58,
        timeFormat: 'HH:mm',
      ),
      monthViewSettings: const MonthViewSettings(
        appointmentDisplayMode: MonthAppointmentDisplayMode.appointment,
        appointmentDisplayCount: 4,
        showAgenda: false,
      ),
      appointmentBuilder: (context, details) => AppointmentCard(
        details: details,
        isMonthView: _calendarCtrl.view == CalendarView.month,
        isPhone: isPhone,
      ),
      onTap: _onCalendarTapped,
      onViewChanged: (details) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _visibleDates = details.visibleDates;
            _viewHeaderHeight = _computeViewHeaderHeight();
          });
        });
      },
    );
  }

  Widget _buildMonthDayPanel() {
    final day = _selectedMonthDay!;
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final dayApps = _appointments
        .where((a) => a.startTime.isBefore(dayEnd) && a.endTime.isAfter(dayStart))
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return Container(
      constraints: BoxConstraints(maxHeight: _isPhone ? 320 : 260),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: const Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text(formatDateRo(day), style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_userRole.canCreateOrgEvents && !widget.personalMode)
                  TextButton.icon(
                    onPressed: () => _openAddEventDialog(day),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Eveniment nou', style: TextStyle(fontSize: 12)),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _selectedMonthDay = null),
                ),
              ],
            ),
          ),
          Expanded(
            child: dayApps.isEmpty
              ? const Center(child: Text('Niciun eveniment', style: TextStyle(color: AppTheme.textMuted)))
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: dayApps.length,
                    itemBuilder: (_, i) {
                      final app = dayApps[i];
                      final meta = parseCalendarSubject(app.subject);
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(backgroundColor: app.color, radius: 6),
                        title: Text('${meta.headerLabel} • ${meta.title}',
                            style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${formatCalendarTime(app.startTime)}-${formatCalendarTime(app.endTime)} • ${meta.organization}',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                        onTap: () => _handleAppointmentTap(app),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _OrgAppointmentSource extends CalendarDataSource {
  _OrgAppointmentSource(List<Appointment> source) { appointments = source; }
}
