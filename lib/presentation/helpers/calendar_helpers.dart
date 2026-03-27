// Calendar helpers – subject encoding, time formatting, display utilities.
import 'package:flutter/material.dart';
import '../../domain/enums.dart';

// ──────────────────────────────────────────────
// Subject encoding / decoding
// ──────────────────────────────────────────────

class CalendarSubjectData {
  final bool isRequest;
  final String type;
  final String title;
  final String organization;
  final String location;

  const CalendarSubjectData({
    required this.isRequest,
    required this.type,
    required this.title,
    required this.organization,
    this.location = '',
  });

  String get headerLabel => isRequest ? 'Cerere' : type;

  /// Display name for location, transforming "Sala (foaier ocupat)" to "Sală și Foaier"
  String get displayLocation {
    if (location.isEmpty) return '';
    if (location.toLowerCase().contains('foaier') && location.toLowerCase().contains('ocupat')) {
      return 'Sală și Foaier';
    }
    return location;
  }
}

String buildCalendarSubject({
  required bool isRequest,
  required String type,
  required String title,
  required String organization,
  String location = '',
}) {
  return <String>[
    isRequest ? 'REQUEST' : 'EVENT',
    _escapePart(type),
    _escapePart(title),
    _escapePart(organization),
    _escapePart(location),
  ].join('|');
}

CalendarSubjectData parseCalendarSubject(String subject) {
  final parts = subject.split('|').map((e) => e.trim()).toList();
  if (parts.length >= 4 && (parts.first == 'EVENT' || parts.first == 'REQUEST')) {
    return CalendarSubjectData(
      isRequest: parts.first == 'REQUEST',
      type: parts[1].isEmpty ? 'Eveniment' : parts[1],
      title: parts[2].toUpperCase(),
      organization: parts[3],
      location: parts.length > 4 ? parts[4] : '',
    );
  }
  if (parts.isNotEmpty && EventTypes.normalize(parts.first) == 'cerere') {
    return CalendarSubjectData(
      isRequest: true,
      type: parts.length > 1 ? parts[1] : 'Cerere',
      title: (parts.length > 2 ? parts[2] : '').toUpperCase(),
      organization: parts.length > 3 ? parts[3] : '',
    );
  }
  return CalendarSubjectData(
    isRequest: false,
    type: parts.isNotEmpty ? parts[0] : 'Eveniment',
    title: (parts.length > 1 ? parts[1] : subject).toUpperCase(),
    organization: parts.length > 3 ? parts[3] : '',
    location: parts.length > 4 ? parts[4] : '',
  );
}

String _escapePart(String value) => value.replaceAll('|', '/').trim();

// ──────────────────────────────────────────────
// Time formatting
// ──────────────────────────────────────────────

String formatCalendarTime(DateTime value) {
  return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

String formatDateRo(DateTime d) {
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

// ──────────────────────────────────────────────
// All-day helpers
// ──────────────────────────────────────────────

bool isVisibleScheduleAllDayRange(DateTime start, DateTime end) {
  if (start.hour == 9 && start.minute == 0 && end.hour == 23 && end.minute == 0 && end.isAfter(start)) {
    return true;
  }
  return start.hour == 0 && start.minute == 0 && end.hour == 23 && end.minute == 59 && end.isAfter(start);
}

bool shouldDisplayInAllDayPanel(DateTime start, DateTime end, {bool explicitAllDay = false}) {
  if (explicitAllDay) return true;
  return isVisibleScheduleAllDayRange(start, end);
}

DateTime normalizeAllDayStart(DateTime date) => DateTime(date.year, date.month, date.day, 0, 0, 0);
DateTime normalizeAllDayEnd(DateTime date) => DateTime(date.year, date.month, date.day, 23, 59, 0);

// ──────────────────────────────────────────────
// Filter matching
// ──────────────────────────────────────────────

bool matchesEventFilter(String rawType, String? filterType) {
  if (filterType == null || filterType.isEmpty) return true;
  if (EventTypes.normalize(filterType) == 'proiect cultural') {
    return EventTypes.isProjectCultural(rawType);
  }
  return EventTypes.normalize(EventTypes.baseLabel(rawType)) == EventTypes.normalize(filterType);
}

// ──────────────────────────────────────────────
// Text style helper
// ──────────────────────────────────────────────

TextStyle calendarCardTextStyle({
  required double size,
  FontWeight weight = FontWeight.w400,
  FontStyle style = FontStyle.normal,
  required Color color,
  double height = 1,
}) {
  return TextStyle(
    fontSize: size,
    fontWeight: weight,
    fontStyle: style,
    color: color,
    height: height,
  );
}

// ──────────────────────────────────────────────
// Romanian month/day names
// ──────────────────────────────────────────────

const List<String> roMonthNames = [
  'Ianuarie', 'Februarie', 'Martie', 'Aprilie', 'Mai', 'Iunie',
  'Iulie', 'August', 'Septembrie', 'Octombrie', 'Noiembrie', 'Decembrie',
];

const List<String> roDayNamesShort = ['Lu', 'Ma', 'Mi', 'Jo', 'Vi', 'Sâ', 'Du'];
