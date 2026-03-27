// Space Ownership Service – THE core business logic engine.
// Determines who owns each time slot and computes ownership segments.
import '../domain/enums.dart';
import '../domain/models.dart';

class SpaceOwnershipService {
  final List<Organization> organizations;
  final List<ScheduleAnchor> anchors;
  final List<ScheduleOverride> overrides;
  final List<CalendarEvent> events;

  String? _magicId;
  String? _maidanId;

  SpaceOwnershipService({
    required this.organizations,
    required this.anchors,
    required this.overrides,
    required this.events,
  }) {
    _magicId = _findOrgIdByName('magic');
    _maidanId = _findOrgIdByName('maidan');
  }

  String? get magicId => _magicId;
  String? get maidanId => _maidanId;

  String? _findOrgIdByName(String keyword) {
    for (final org in organizations) {
      if (org.name.toLowerCase().contains(keyword)) return org.id;
    }
    return null;
  }

  String orgNameById(String? orgId) {
    if (orgId == null || orgId.isEmpty) return '-';
    for (final org in organizations) {
      if (org.id == orgId) return org.name;
    }
    return orgId;
  }

  /// Returns the organization ID that owns the given time slot,
  /// or null if free/unassigned.
  String? getOwnerAt(DateTime date, {ManagedLocation location = ManagedLocation.sala}) {
    if (location == ManagedLocation.foaier) {
      final blocked = _isFoaierBlockedAt(date);
      if (!blocked) return null; // free
      // When foaier is blocked, follow Sala ownership
      return getOwnerAt(date, location: ManagedLocation.sala);
    }

    // Check overrides first (newest wins)
    for (final ov in overrides) {
      if ((date.isAtSameMomentAs(ov.startTime) || date.isAfter(ov.startTime)) &&
          date.isBefore(ov.endTime)) {
        return ov.organizationId;
      }
    }

    // Fall back to weekly anchor pattern
    if (anchors.isEmpty) return null;
    final anchor = anchors.first;

    final ref = anchor.anchorDate;
    final refMonday = ref.subtract(Duration(days: ref.weekday - 1));
    final dateMonday = date.subtract(Duration(days: date.weekday - 1));
    final weekDiff = dateMonday.difference(refMonday).inDays ~/ 7;
    final isEven = weekDiff % 2 == 0;
    final isMagicWeek = isEven
        ? anchor.isMagicMondayMorning
        : !anchor.isMagicMondayMorning;

    // Friday–Sunday: weekend schedule
    if (date.weekday >= 5) {
      final isMagicW = isEven ? anchor.isMagicWeekend : !anchor.isMagicWeekend;
      return isMagicW ? _magicId : _maidanId;
    }

    // Mon–Thu: morning (9–14) = week owner, afternoon (14–23) = other
    if (date.hour >= 9 && date.hour < 14) {
      return isMagicWeek ? _magicId : _maidanId;
    }
    return isMagicWeek ? _maidanId : _magicId;
  }

  /// Whether the foaier is blocked at this specific moment
  /// (blocked by a hall-blocking event type in Sala).
  bool _isFoaierBlockedAt(DateTime moment) {
    for (final event in events) {
      if (ManagedLocation.fromString(event.location) != ManagedLocation.sala) continue;
      final explicitFoaierBlock = ManagedLocation.isSalaWithBlockedFoaier(event.location);
      final implicitFoaierBlock = EventTypes.isHallBlocking(event.eventType);
      if (!explicitFoaierBlock && !implicitFoaierBlock) continue;
      final blockedUntil = implicitFoaierBlock
          ? event.endTime.add(const Duration(hours: 1))
          : event.endTime;
      if ((moment.isAtSameMomentAs(event.startTime) || moment.isAfter(event.startTime)) &&
          moment.isBefore(blockedUntil)) {
        return true;
      }
    }
    return false;
  }

  /// Check if foaier has overlap with existing events at given time range.
  bool hasFoaierOverlap(DateTime start, DateTime end, {String? ignoreEventId}) {
    for (final event in events) {
      if (event.id == ignoreEventId) continue;
      if (ManagedLocation.fromString(event.location) != ManagedLocation.foaier) continue;
      if (start.isBefore(event.endTime) && event.startTime.isBefore(end)) {
        return true;
      }
    }
    return false;
  }

  /// Check if sala has overlap with existing events at given time range.
  bool hasSalaOverlap(DateTime start, DateTime end, {String? ignoreEventId}) {
    for (final event in events) {
      if (event.id == ignoreEventId) continue;
      if (ManagedLocation.fromString(event.location) != ManagedLocation.sala) continue;
      if (start.isBefore(event.endTime) && event.startTime.isBefore(end)) {
        return true;
      }
    }
    return false;
  }

  /// Find conflicting event in sala or foaier, or check if sala blocks foaier.
  CalendarEvent? findConflictingEvent(
    DateTime start,
    DateTime end,
    ManagedLocation location, {
    String? ignoreEventId,
  }) {
    for (final event in events) {
      if (event.id == ignoreEventId) continue;
      if (!start.isBefore(event.endTime) || !event.startTime.isBefore(end)) continue;

      final eventLoc = ManagedLocation.fromString(event.location);
      if (eventLoc == location) return event;

      // If we're querying foaier and event is sala with blocked foaier
      if (location == ManagedLocation.foaier &&
          eventLoc == ManagedLocation.sala &&
          ManagedLocation.isSalaWithBlockedFoaier(event.location)) {
        return event;
      }
    }
    return null;
  }

  /// Compute ownership segments for a given time range and location.
  /// Segments are split on 15-minute boundaries.
  List<OwnershipSegment> computeSegments({
    required DateTime start,
    required DateTime end,
    required ManagedLocation location,
    required String userOrgId,
  }) {
    final segments = <OwnershipSegment>[];
    if (!end.isAfter(start)) return segments;

    DateTime dayCursor = DateTime(start.year, start.month, start.day);
    final lastDay = DateTime(end.year, end.month, end.day);

    while (!dayCursor.isAfter(lastDay)) {
      final managedDayStart = DateTime(dayCursor.year, dayCursor.month, dayCursor.day, 9);
      final managedDayEnd = DateTime(dayCursor.year, dayCursor.month, dayCursor.day, 23);

      final windowStart = start.isAfter(managedDayStart) ? start : managedDayStart;
      final windowEnd = end.isBefore(managedDayEnd) ? end : managedDayEnd;

      if (windowEnd.isAfter(windowStart)) {
        DateTime cursor = windowStart;
        while (cursor.isBefore(windowEnd)) {
          DateTime slotEnd = cursor.add(const Duration(minutes: 15));
          if (slotEnd.isAfter(windowEnd)) slotEnd = windowEnd;

          final owner = getOwnerAt(cursor, location: location);
          final isOwnOrFree = owner == userOrgId || owner == null;

          if (segments.isNotEmpty) {
            final last = segments.last;
            final isAdjacent = last.end.isAtSameMomentAs(cursor);
            final mergeOwn = isAdjacent && last.isOwn && isOwnOrFree;
            final mergeForeign = isAdjacent && !last.isOwn && !isOwnOrFree && last.orgId == owner;

            if (mergeOwn || mergeForeign) {
              segments[segments.length - 1] = OwnershipSegment(
                start: last.start,
                end: slotEnd,
                isOwn: last.isOwn,
                orgId: last.orgId,
              );
            } else {
              segments.add(OwnershipSegment(
                start: cursor,
                end: slotEnd,
                isOwn: isOwnOrFree,
                orgId: owner,
              ));
            }
          } else {
            segments.add(OwnershipSegment(
              start: cursor,
              end: slotEnd,
              isOwn: isOwnOrFree,
              orgId: owner,
            ));
          }
          cursor = slotEnd;
        }
      }
      dayCursor = dayCursor.add(const Duration(days: 1));
    }
    return segments;
  }

  /// Check if any part of a time range has a Sala all-day-blocking event.
  CalendarEvent? getSalaBlockingEvent(DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    for (final event in events) {
      if (ManagedLocation.fromString(event.location) != ManagedLocation.sala) continue;
      if (!event.startTime.isBefore(dayEnd) || !event.endTime.isAfter(dayStart)) continue;
      if (CalendarEvent.isAllDayRange(event.startTime, event.endTime)) return event;
    }
    return null;
  }
}
