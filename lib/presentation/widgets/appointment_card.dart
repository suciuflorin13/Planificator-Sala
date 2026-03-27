// Appointment card widget – renders a single calendar cell.
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/enums.dart';
import '../helpers/calendar_helpers.dart';

class AppointmentCard extends StatelessWidget {
  final CalendarAppointmentDetails details;
  final bool isMonthView;
  final bool isPhone;

  const AppointmentCard({
    super.key,
    required this.details,
    this.isMonthView = false,
    this.isPhone = false,
  });

  @override
  Widget build(BuildContext context) {
    final app = details.appointments.first as Appointment;
    final cardHeight = details.bounds.height;
    final meta = parseCalendarSubject(app.subject);
    final phoneFactor = isPhone ? 0.78 : 1.0;

    double rs(double base, {double min = 5}) {
      final v = base * phoneFactor;
      return v < min ? min : v;
    }

    // Tiny – just a colored bar
    if (cardHeight <= 8) {
      return Container(
        decoration: BoxDecoration(
          color: app.color,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }

    // All-day row (non-month) or tiny month cell
    final isAllDayLike = !isMonthView &&
        shouldDisplayInAllDayPanel(app.startTime, app.endTime, explicitAllDay: app.isAllDay);

    if (isAllDayLike || (isMonthView && cardHeight <= 12)) {
      return _allDayBar(app, meta, rs);
    }

    // Month view – single line
    if (isMonthView) {
      return _monthCell(app, meta, rs);
    }

    // Normal timed card
    if (cardHeight < 34) {
      return _compactCard(app, meta, cardHeight, rs);
    }

    return _fullCard(app, meta, cardHeight, rs);
  }

  Widget _allDayBar(
    Appointment app,
    CalendarSubjectData meta,
    double Function(double, {double min}) rs,
  ) {
    final label = meta.isRequest ? '[CERERE] ${meta.type} ${meta.title}' : '${meta.type} ${meta.title}';
    return Container(
      decoration: BoxDecoration(
        color: app.color,
        borderRadius: BorderRadius.circular(3),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.white, fontSize: rs(7, min: 5), fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _monthCell(
    Appointment app,
    CalendarSubjectData meta,
    double Function(double, {double min}) rs,
  ) {
    final label = meta.isRequest ? '[CERERE] ${meta.type} ${meta.title}' : '${meta.type} ${meta.title}';
    return Container(
      decoration: BoxDecoration(
        color: app.color,
        borderRadius: BorderRadius.circular(3),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.white, fontSize: rs(8, min: 5)),
      ),
    );
  }

  Widget _compactCard(
    Appointment app,
    CalendarSubjectData meta,
    double cardHeight,
    double Function(double, {double min}) rs,
  ) {
    final prefix = meta.isRequest ? '[CERERE] ' : '';
    final startLabel = formatCalendarTime(app.startTime);
    final endLabel = formatCalendarTime(app.endTime);
    final showTime = cardHeight >= 24;
    final label = '$prefix${meta.type} ${meta.title}${showTime ? ' $startLabel-$endLabel' : ''}';

    return Container(
      decoration: BoxDecoration(
        color: app.color,
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.white, fontSize: rs(10, min: 7)),
      ),
    );
  }

  Widget _fullCard(
    Appointment app,
    CalendarSubjectData meta,
    double cardHeight,
    double Function(double, {double min}) rs,
  ) {
    final startLabel = formatCalendarTime(app.startTime);
    final endLabel = formatCalendarTime(app.endTime);
    final canOpenMap = !meta.isRequest &&
        meta.location.trim().isNotEmpty &&
        ManagedLocation.fromString(meta.location) == null;
    final isMultiDay = !_isSameDay(app.startTime, app.endTime);
    final compactHeaderOnly = app.isAllDay || isMultiDay;
    final headerText = '${meta.isRequest ? 'CERERE' : meta.type} • ${meta.title}';

    return Container(
      decoration: BoxDecoration(
        color: app.color,
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (compactHeaderOnly)
            Text(
              headerText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: calendarCardTextStyle(size: rs(11, min: 8), weight: FontWeight.w700, color: Colors.white),
            ),
          if (!compactHeaderOnly) ...[
            if (meta.isRequest) ...[
              Text(
                'CERERE',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(size: rs(10, min: 7), weight: FontWeight.w600, color: Colors.white),
              ),
              Text(
                meta.type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(size: rs(10, min: 7), weight: FontWeight.w600, color: Colors.white),
              ),
              Text(
                meta.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(
                  size: rs(14, min: 9),
                  weight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ] else ...[
              Text(
                meta.type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(size: rs(10, min: 7), weight: FontWeight.w600, color: Colors.white),
              ),
              Text(
                meta.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(
                  size: rs(14, min: 9),
                  weight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
            if (cardHeight >= 56)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      meta.displayLocation.isNotEmpty ? meta.displayLocation : '-',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: calendarCardTextStyle(size: rs(10, min: 7), color: Colors.white70),
                    ),
                  ),
                  if (canOpenMap)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _openMaps(meta.location),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.map_outlined, size: rs(12, min: 9), color: Colors.white70),
                      ),
                    ),
                ],
              ),
            if (cardHeight >= 68)
              Text(
                '$startLabel-$endLabel',
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(size: rs(10, min: 7), color: Colors.white70),
              ),
            if (cardHeight >= 80)
              Text(
                meta.organization,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: calendarCardTextStyle(
                  size: rs(10, min: 7),
                  style: FontStyle.italic,
                  color: Colors.white70,
                ),
              ),
          ],
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<void> _openMaps(String location) async {
    final q = location.trim();
    if (q.isEmpty) return;
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(q)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
