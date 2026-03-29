// Schedule Page – Program Sală
// Shows the managed space calendar with ownership coloring, requests, and events.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../data/repositories.dart';
import '../../application/space_ownership_service.dart';
import '../theme.dart';
import '../helpers/calendar_helpers.dart';
import '../helpers/status_dialog_helper.dart';
import '../widgets/appointment_card.dart';
import '../widgets/legend_widget.dart';
import '../dialogs/add_event_dialog.dart';
import '../dialogs/request_dialog.dart';
import 'space_allocation_page.dart';

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  // ── Repositories & Services ──
  final _eventRepo = EventRepository();
  final _requestRepo = RequestRepository();
  final _scheduleRepo = ScheduleRepository();
  final _orgRepo = OrganizationRepository();
  final _profileRepo = ProfileRepository();

  // ── State ──
  final CalendarController _calendarController = CalendarController();
  List<Organization> _organizations = [];
  List<ScheduleAnchor> _anchors = [];
  List<ScheduleOverride> _overrides = [];
  List<CalendarEvent> _events = [];
  List<EventRequest> _requests = [];
  UserProfile? _profile;
  SpaceOwnershipService? _ownership;

  List<Appointment> _appointments = [];
  List<TimeRegion> _backgroundRegions = [];

  bool _isLoading = true;
  String _currentView = 'Săptămână';
  DateTime? _selectedMonthDay;
  List<DateTime> _visibleDates = [];
  double _viewHeaderHeight = -1;

  StreamSubscription? _realtimeSub;

  String? get _magicId => _ownership?.magicId;
  String? get _maidanId => _ownership?.maidanId;
  String? get _userOrgId => _profile?.organizationId;
  UserRole get _userRole => _profile?.role ?? UserRole.utilizator;
  bool get _isPhone => MediaQuery.of(context).size.width < 600;

  @override
  void initState() {
    super.initState();
    _calendarController.view = CalendarView.week;
    _fetchData();
    _setupRealtime();
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    _calendarController.dispose();
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
      final results = await Future.wait([
        _orgRepo.fetchAll(),
        _scheduleRepo.fetchAnchors(),
        _scheduleRepo.fetchOverrides(),
        _eventRepo.fetchForSchedule(),
        _requestRepo.fetchAll(),
        _profileRepo.fetchById(userId),
      ]);

      _organizations = results[0] as List<Organization>;
      _anchors = results[1] as List<ScheduleAnchor>;
      _overrides = results[2] as List<ScheduleOverride>;
      _events = results[3] as List<CalendarEvent>;
      _requests = (results[4] as List<EventRequest>)
          .where((r) => r.status == RequestStatus.open)
          .toList();
      _profile = results[5] as UserProfile;

      _ownership = SpaceOwnershipService(
        organizations: _organizations,
        anchors: _anchors,
        overrides: _overrides,
        events: _events,
      );

      _buildAppointments();
      _buildBackgroundRegions();

      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('SchedulePage._fetchData error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ──────────────────────────────────────────
  // Appointment conversion
  // ──────────────────────────────────────────

  void _buildAppointments() {
    final all = <Appointment>[];

    // Events
    for (final event in _events) {
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

  // ──────────────────────────────────────────
  // Background ownership regions
  // ──────────────────────────────────────────

  void _buildBackgroundRegions() {
    if (_ownership == null) {
      _backgroundRegions = [];
      return;
    }
    final regions = <TimeRegion>[];
    for (final date in _visibleDates) {
      for (int hour = 9; hour < 23; hour++) {
        final slotStart = DateTime(date.year, date.month, date.day, hour);
        final slotEnd = slotStart.add(const Duration(hours: 1));
        final owner = _ownership!.getOwnerAt(slotStart);
        regions.add(TimeRegion(
          startTime: slotStart,
          endTime: slotEnd,
          color: AppTheme.backgroundForOrg(owner, _magicId, _maidanId),
        ));
      }
    }
    _backgroundRegions = regions;
  }

  // ──────────────────────────────────────────
  // Tap handling
  // ──────────────────────────────────────────

  void _onCalendarTapped(CalendarTapDetails details) {
    if (details.targetElement == CalendarElement.appointment) {
      final app = details.appointments!.first as Appointment;
      _handleAppointmentTap(app);
    } else if (details.targetElement == CalendarElement.calendarCell) {
      if (_calendarController.view == CalendarView.month) {
        setState(() => _selectedMonthDay = details.date);
      } else if (_userRole.canCreateOrgEvents) {
        _openAddEventDialog(details.date ?? DateTime.now());
      }
    }
  }

  void _handleAppointmentTap(Appointment app) async {
    final id = app.id?.toString() ?? '';

    if (id.startsWith('req_')) {
      final reqId = id.replaceFirst('req_', '');
      _showRequestDialog(reqId);
    } else if (id.startsWith('event_')) {
      final eventId = id.replaceFirst('event_', '');
      if (_userRole.canCreateOrgEvents) {
        _openEditEventDialog(eventId);
      }
    }
  }

  void _showRequestDialog(String requestId) async {
    final req = _requests.firstWhere(
      (r) => r.id == requestId,
      orElse: () => _requests.first,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (_) => RequestDialog(
        request: req,
        ownership: _ownership!,
        userOrgId: _userOrgId ?? '',
        userRole: _userRole,
        orgNameById: (id) => _ownership?.orgNameById(id) ?? '',
      ),
    );

    if (result == 'accepted' || result == 'rejected' || result == 'deleted') {
      _fetchData();
    }
  }

  void _openAddEventDialog(DateTime selectedDate) async {
    if (_ownership == null || _profile == null) return;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddEventDialog(
        selectedDate: selectedDate,
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
        await StatusDialogHelper.show(
          context,
          title: 'Eroare la încărcare',
          message: 'Eroare la încărcarea evenimentului: $e',
          isError: true,
        );
      }
    }
  }

  // ──────────────────────────────────────────
  // View header height calculation
  // ──────────────────────────────────────────

  double _computeViewHeaderHeight() {
    if (_calendarController.view == CalendarView.month) return -1;
    final isPhone = _isPhone;
    final cell = isPhone ? 44.0 : 56.0;
    final headerBand = isPhone ? 34.0 : 38.0;

    int allDayCount = 0;
    for (final app in _appointments) {
      if (app.isAllDay || shouldDisplayInAllDayPanel(app.startTime, app.endTime)) {
        for (final d in _visibleDates) {
          final dayStart = DateTime(d.year, d.month, d.day);
          final dayEnd = dayStart.add(const Duration(days: 1));
          if (app.startTime.isBefore(dayEnd) && app.endTime.isAfter(dayStart)) {
            allDayCount++;
            break;
          }
        }
      }
    }

    final effectiveCount = allDayCount.clamp(0, 6);
    if (effectiveCount == 0) return headerBand;
    return headerBand + cell * (0.5 + 0.5 * effectiveCount).clamp(1.0, 4.0);
  }

  // ──────────────────────────────────────────
  // View switching
  // ──────────────────────────────────────────

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
      _calendarController.view = view;
      _selectedMonthDay = null;
    });
  }

  // ──────────────────────────────────────────
  // Build methods
  // ──────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: AppTheme.appBg,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        title: const Text('Program Sală', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          // Space allocation button (admin only)
          if (_userRole.canModifySchedule)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Împărțire spațiu',
              onPressed: _openSpaceAllocation,
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
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                  children: [
                    const CalendarLegend(),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
            SliverFillRemaining(
              child: _currentView == 'Zi' ? _buildDayViewLayout() : _buildCalendarOnly(),
            ),
          ],
        ),
      ),
      floatingActionButton: _userRole.canCreateOrgEvents
          ? FloatingActionButton(
              onPressed: () => _openAddEventDialog(DateTime.now()),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildCalendarOnly() {
    return Column(
      children: [
        Expanded(child: _buildCalendarWidget()),
        if (_currentView == 'Lună' && _selectedMonthDay != null) _buildMonthDayPanel(),
      ],
    );
  }

  Widget _buildDayViewLayout() {
    final isPhone = _isPhone;

    final miniCalendar = _buildMiniCalendar();
    final calendar = Expanded(child: _buildCalendarWidget());

    if (isPhone) {
      return Column(
        children: [
          SizedBox(height: 140, child: miniCalendar),
          calendar,
        ],
      );
    }

    return Row(
      children: [
        SizedBox(width: 120, child: miniCalendar),
        calendar,
      ],
    );
  }

  Widget _buildMiniCalendar() {
    final now = DateTime.now();
    final displayDate = _calendarController.displayDate ?? now;
    final firstOfMonth = DateTime(displayDate.year, displayDate.month, 1);
    final daysInMonth = DateTime(displayDate.year, displayDate.month + 1, 0).day;
    final startWeekday = firstOfMonth.weekday; // 1=Mon

    return Container(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          Text(
            '${roMonthNames[displayDate.month - 1]} ${displayDate.year}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          // Day name headers
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: roDayNamesShort.map((d) => SizedBox(
              width: 14,
              child: Text(d, textAlign: TextAlign.center, style: const TextStyle(fontSize: 8, color: AppTheme.textMuted)),
            )).toList(),
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
                final selected = _calendarController.selectedDate;
                final isSelected = selected != null &&
                    selected.year == date.year &&
                    selected.month == date.month &&
                    selected.day == date.day;
                final isToday = date.year == now.year && date.month == now.month && date.day == now.day;

                return GestureDetector(
                  onTap: () {
                    _calendarController.selectedDate = date;
                    _calendarController.displayDate = date;
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
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.metaLeft ||
                event.logicalKey == LogicalKeyboardKey.metaRight)) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SfCalendar(
        controller: _calendarController,
        dataSource: _AppointmentDataSource(_appointments),
        firstDayOfWeek: 1,
        showNavigationArrow: true,
        showDatePickerButton: true,
        viewHeaderHeight: _viewHeaderHeight,
        timeSlotViewSettings: TimeSlotViewSettings(
          startHour: 9,
          endHour: 23,
          timeIntervalHeight: isPhone ? 52 : 58,
          timeFormat: 'HH:mm',
        ),
        monthViewSettings: const MonthViewSettings(
          appointmentDisplayMode: MonthAppointmentDisplayMode.appointment,
          appointmentDisplayCount: 4,
          showAgenda: false,
        ),
        specialRegions: _backgroundRegions,
        appointmentBuilder: (context, details) {
          return AppointmentCard(
            details: details,
            isMonthView: _calendarController.view == CalendarView.month,
            isPhone: isPhone,
          );
        },
        onTap: _onCalendarTapped,
        onViewChanged: (details) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _visibleDates = details.visibleDates;
              _buildBackgroundRegions();
              _viewHeaderHeight = _computeViewHeaderHeight();
            });
          });
        },
      ),
    );
  }

  Widget _buildMonthDayPanel() {
    final day = _selectedMonthDay!;
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final dayApps = _appointments.where((a) {
      return a.startTime.isBefore(dayEnd) && a.endTime.isAfter(dayStart);
    }).toList()
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
                Text(
                  formatDateRo(day),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_userRole.canCreateOrgEvents)
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
                        leading: CircleAvatar(
                          backgroundColor: app.color,
                          radius: 6,
                        ),
                        title: Text(
                          '${meta.headerLabel} • ${meta.title}',
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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

  void _openSpaceAllocation() async {
    if (_ownership == null) return;
    // Use the currently visible week, not today
    final visibleWeekStart = _visibleDates.isNotEmpty
        ? _getMonday(_visibleDates.first)
        : _getMonday(DateTime.now());
    final result = await Navigator.of(context).push<SpaceAllocResult>(
      MaterialPageRoute(
        builder: (_) => SpaceAllocationPage(
          initialWeekStart: visibleWeekStart,
          ownership: _ownership!,
          organizations: _organizations,
          weekEvents: _events,
        ),
      ),
    );
    if (result != null) {
      await _applySpaceAllocResult(result);
      _fetchData();
    }
  }

  Future<void> _applySpaceAllocResult(SpaceAllocResult result) async {
    final userId = Supabase.instance.client.auth.currentUser!.id;
    for (final block in result.blocks) {
      for (final entry in block.entries) {
        final weekday = entry.key;
        final draft = entry.value;
        final dayDate = result.weekStart.add(Duration(days: weekday - 1));

        // Delete existing overrides for this day
        final dayStart = DateTime(dayDate.year, dayDate.month, dayDate.day, 0);
        final dayEnd = DateTime(dayDate.year, dayDate.month, dayDate.day, 23, 59);
        await _scheduleRepo.deleteOverridesInRange(dayStart, dayEnd);

        // Insert new segments
        for (final seg in draft.segments) {
          if (seg.orgId == null) continue;
          await _scheduleRepo.insertOverride(
            start: DateTime(dayDate.year, dayDate.month, dayDate.day, seg.startHour),
            end: DateTime(dayDate.year, dayDate.month, dayDate.day, seg.endHour),
            organizationId: seg.orgId,
            createdBy: userId,
          );
        }
      }
    }
  }

  DateTime _getMonday(DateTime date) => date.subtract(Duration(days: date.weekday - 1));
}

// ──────────────────────────────────────────────
// Calendar data source
// ──────────────────────────────────────────────

class _AppointmentDataSource extends CalendarDataSource {
  _AppointmentDataSource(List<Appointment> source) {
    appointments = source;
  }
}
