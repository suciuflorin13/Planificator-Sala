// Event Service – handles creating, editing, deleting events
// and generating overflow requests when foreign management is involved.
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/enums.dart';
import '../domain/models.dart';
import '../data/repositories.dart';
import 'space_ownership_service.dart';

class EventService {
  final EventRepository _events;
  final RequestRepository _requests;
  final MessageRepository _messages;
  final ProfileRepository _profiles;

  EventService({
    EventRepository? events,
    RequestRepository? requests,
    MessageRepository? messages,
    ProfileRepository? profiles,
  })  : _events = events ?? EventRepository(),
        _requests = requests ?? RequestRepository(),
        _messages = messages ?? MessageRepository(),
        _profiles = profiles ?? ProfileRepository();

  String get _currentUserId => Supabase.instance.client.auth.currentUser!.id;

  /// Create or update an event with proper ownership segmentation.
  Future<void> saveEvent({
    required String? existingEventId,
    required String title,
    required String eventType,
    required String location,
    required DateTime start,
    required DateTime end,
    required String userOrgId,
    required List<String> participants,
    required SpaceOwnershipService ownership,
    required List<Organization> organizations,
    String? requestMessage,
    bool isAllDay = false,
  }) async {
    final managedLocation = ManagedLocation.fromString(location);
    final fullDayRange = CalendarEvent.isAllDayRange(start, end);
    final allDayIntent = isAllDay || fullDayRange;

    if (allDayIntent) {
      start = _normalizeAllDayStart(start);
      end = _normalizeAllDayEnd(end);
    }

    // Validate no conflicts with existing events
    if (managedLocation != null) {
      final conflict = ownership.findConflictingEvent(
        start,
        end,
        managedLocation,
        ignoreEventId: existingEventId,
      );
      if (conflict != null) {
        final dateLabel = _formatDateForError(conflict.startTime);
        final timeRange = '${_formatTimeForError(conflict.startTime)}-${_formatTimeForError(conflict.endTime)}';
        throw Exception(
          'Spațiul este folosit deja în intervalul "$dateLabel $timeRange" și evenimentul nu poate fi creat.',
        );
      }
    }

    final segments = managedLocation != null
        ? ownership.computeSegments(
            start: start,
            end: end,
            location: managedLocation,
            userOrgId: userOrgId,
          )
        : <OwnershipSegment>[];

    final ownSegments = managedLocation != null
        ? segments.where((s) => s.isOwn).toList()
        : [OwnershipSegment(start: start, end: end, isOwn: true, orgId: userOrgId)];
    final foreignSegments = managedLocation != null
        ? segments.where((s) => !s.isOwn).toList()
        : <OwnershipSegment>[];

    final primaryOwn = ownSegments.isNotEmpty ? ownSegments.first : null;
    final hasOwnPortion = primaryOwn != null && primaryOwn.end.isAfter(primaryOwn.start);
    final hasForeign = foreignSegments.isNotEmpty;

    if (!hasOwnPortion && !hasForeign) {
      throw Exception('Nu există porțiune disponibilă pentru organizația ta.');
    }

    final overflowGroupId = hasForeign
        ? '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(1 << 20)}'
        : '';

    // For all-day events, group own segments per calendar day and expand to full day (0:00-23:59).
    // For timed events, keep raw segments.
    final List<OwnershipSegment> effectiveOwnSegments;
    if (allDayIntent && ownSegments.isNotEmpty) {
      // Collect all unique days covered by own segments
      final ownDays = <DateTime>{};
      for (final seg in ownSegments.where((s) => s.end.isAfter(s.start))) {
        var d = DateTime(seg.start.year, seg.start.month, seg.start.day);
        final last = DateTime(seg.end.year, seg.end.month, seg.end.day);
        while (!d.isAfter(last)) {
          ownDays.add(d);
          d = d.add(const Duration(days: 1));
        }
      }
      final sortedDays = ownDays.toList()..sort();

      // Merge consecutive days into single all-day segments
      effectiveOwnSegments = [];
      for (final day in sortedDays) {
        final dayStart = DateTime(day.year, day.month, day.day);
        final dayEnd = DateTime(day.year, day.month, day.day, 23, 59);
        if (effectiveOwnSegments.isNotEmpty) {
          final prev = effectiveOwnSegments.last;
          final prevEndDay = DateTime(prev.end.year, prev.end.month, prev.end.day);
          if (dayStart.isAtSameMomentAs(prevEndDay.add(const Duration(days: 1)))) {
            // Extend previous segment
            effectiveOwnSegments[effectiveOwnSegments.length - 1] = OwnershipSegment(
              start: prev.start,
              end: dayEnd,
              isOwn: true,
              orgId: prev.orgId,
            );
            continue;
          }
        }
        effectiveOwnSegments.add(OwnershipSegment(
          start: dayStart,
          end: dayEnd,
          isOwn: true,
          orgId: userOrgId,
        ));
      }
    } else {
      effectiveOwnSegments = ownSegments.where((s) => s.end.isAfter(s.start)).toList();
    }

    final effectivePrimary = effectiveOwnSegments.isNotEmpty ? effectiveOwnSegments.first : null;
    final effectiveHasOwn = effectivePrimary != null;

    final ownSegmentPayload = effectiveOwnSegments
        .map((s) => {
              'start_time': s.start.toUtc().toIso8601String(),
              'end_time': s.end.toUtc().toIso8601String(),
            })
        .toList();

    final intendedStart = allDayIntent ? _normalizeAllDayStart(start) : start;
    final intendedEnd = allDayIntent ? _normalizeAllDayEnd(end) : end;

    final baseEventData = {
      'title': title,
      'event_type': eventType,
      'location': location,
      'participants': participants,
      'event_scope': 'organization',
      'owner_user_id': null,
      'organization_id': userOrgId,
      'created_by': _currentUserId,
    };

    final offerPayload = {
      ...baseEventData,
      'all_day_intent': allDayIntent,
      'intended_start_time': intendedStart.toUtc().toIso8601String(),
      'intended_end_time': intendedEnd.toUtc().toIso8601String(),
      if (hasForeign) 'overflow_group_id': overflowGroupId,
      if (hasForeign) 'owned_segments': ownSegmentPayload,
    };

    final eventData = {
      ...baseEventData,
      'start_time': effectiveHasOwn
          ? effectivePrimary.start.toUtc().toIso8601String()
          : foreignSegments.first.start.toUtc().toIso8601String(),
      'end_time': effectiveHasOwn
          ? effectivePrimary.end.toUtc().toIso8601String()
          : foreignSegments.first.end.toUtc().toIso8601String(),
    };

    final msg = (requestMessage ?? '').trim().isEmpty
        ? 'Cerere pentru prelungire interval.'
        : requestMessage!.trim();

    if (existingEventId != null) {
      // EDIT mode
      if (effectiveHasOwn) {
        await _events.update(existingEventId, eventData);
      } else {
        await _requests.deleteByEventId(existingEventId, status: 'open');
        await _events.delete(existingEventId);
      }

      await _upsertOverflowRequests(
        eventId: effectiveHasOwn ? existingEventId : null,
        offerPayload: offerPayload,
        foreignSegments: foreignSegments,
        userOrgId: userOrgId,
        message: msg,
        organizations: organizations,
        requestedStart: foreignSegments.isNotEmpty ? foreignSegments.first.start : start,
        requestedEnd: foreignSegments.isNotEmpty ? foreignSegments.first.end : end,
      );

      // Insert additional own segments if applicable
      if (effectiveHasOwn && effectiveOwnSegments.length > 1) {
        for (final segment in effectiveOwnSegments.skip(1)) {
          try {
            await _events.insert({
              ...eventData,
              'start_time': segment.start.toUtc().toIso8601String(),
              'end_time': segment.end.toUtc().toIso8601String(),
            });
          } catch (error) {
            if (!_isOverlapConstraint(error)) rethrow;
          }
        }
      }
    } else {
      // CREATE mode
      String? createdEventId;
      if (effectiveHasOwn) {
        try {
          createdEventId = await _events.insert(eventData);
        } catch (error) {
          if (_isOverlapConstraint(error)) {
            createdEventId = null;
          } else {
            rethrow;
          }
        }
      }

      await _upsertOverflowRequests(
        eventId: createdEventId,
        offerPayload: offerPayload,
        foreignSegments: foreignSegments,
        userOrgId: userOrgId,
        message: msg,
        organizations: organizations,
        requestedStart: foreignSegments.isNotEmpty ? foreignSegments.first.start : start,
        requestedEnd: foreignSegments.isNotEmpty ? foreignSegments.first.end : end,
      );

      // Insert additional own segments
      if (createdEventId != null && effectiveOwnSegments.length > 1) {
        for (final segment in effectiveOwnSegments.skip(1)) {
          try {
            await _events.insert({
              ...eventData,
              'start_time': segment.start.toUtc().toIso8601String(),
              'end_time': segment.end.toUtc().toIso8601String(),
            });
          } catch (error) {
            if (!_isOverlapConstraint(error)) rethrow;
          }
        }
      }
    }

    // Notify participants
    await _notifyParticipants(
      title: title,
      start: start,
      end: end,
      participants: participants,
      userOrgId: userOrgId,
    );
  }

  /// Delete an event and its associated requests.
  Future<void> deleteEvent(String eventId) async {
    await _requests.deleteByEventId(eventId);
    await _events.delete(eventId);
  }

  Future<void> _upsertOverflowRequests({
    required String? eventId,
    required Map<String, dynamic> offerPayload,
    required List<OwnershipSegment> foreignSegments,
    required String userOrgId,
    required String message,
    required List<Organization> organizations,
    required DateTime requestedStart,
    required DateTime requestedEnd,
  }) async {
    if (eventId != null && eventId.isNotEmpty) {
      await _requests.deleteByEventId(eventId, status: 'open');
    }
    if (foreignSegments.isEmpty) return;

    final inserts = foreignSegments.map((segment) => {
      if (eventId != null && eventId.isNotEmpty) 'event_id': eventId,
      'requested_start': segment.start.toUtc().toIso8601String(),
      'requested_end': segment.end.toUtc().toIso8601String(),
      'request_type': 'overflow',
      'status': 'open',
      'requested_by_org_id': userOrgId,
      'target_org_id': segment.orgId,
      'offer_payload_json': offerPayload,
      'message': message,
      'created_by': _currentUserId,
    }).toList();

    await _requests.insertMany(inserts);

    // Notify target organizations
    await _notifyTargetOrgs(
      targetOrgIds: foreignSegments.map((s) => s.orgId).whereType<String>().toSet().toList(),
      requestedStart: requestedStart,
      requestedEnd: requestedEnd,
    );
  }

  Future<void> _notifyTargetOrgs({
    required List<String> targetOrgIds,
    required DateTime requestedStart,
    required DateTime requestedEnd,
  }) async {
    if (targetOrgIds.isEmpty) return;

    final receivers = await Supabase.instance.client
        .from('profiles')
        .select('id,organization_id')
        .inFilter('organization_id', targetOrgIds)
        .neq('id', _currentUserId);

    final rows = List<Map<String, dynamic>>.from(receivers);
    if (rows.isEmpty) return;

    final month = _monthNames[requestedStart.month - 1];
    final body = 'Ai o cerere pentru un eveniment din $month, '
        'ziua ${requestedStart.day}, intervalul '
        '${_fmtTime(requestedStart)}-${_fmtTime(requestedEnd)}.';

    final inserts = rows.map((r) => {
      'sender_id': _currentUserId,
      'receiver_id': r['id'],
      'title': 'Ai o cerere pentru un eveniment',
      'content': body,
      'read': false,
      'recipient_scope': 'organization',
    }).toList();

    await _messages.sendBatch(inserts);
  }

  Future<void> _notifyParticipants({
    required String title,
    required DateTime start,
    required DateTime end,
    required List<String> participants,
    required String userOrgId,
  }) async {
    if (participants.isEmpty) return;

    // Look up user IDs from names
    final users = await _profiles.fetchByOrg(userOrgId);
    final nameToId = <String, String>{};
    for (final u in users) {
      nameToId[u.displayName] = u.id;
    }

    final date = '${start.day.toString().padLeft(2, '0')}.${start.month.toString().padLeft(2, '0')}.${start.year}';
    final interval = '${_fmtTime(start)}-${_fmtTime(end)}';
    final body = 'Ai fost adăugat la evenimentul "$title" din data $date, interval $interval.';

    final inserts = <Map<String, dynamic>>[];
    for (final member in participants) {
      final uid = nameToId[member];
      if (uid == null || uid.isEmpty || uid == _currentUserId) continue;
      inserts.add({
        'sender_id': _currentUserId,
        'receiver_id': uid,
        'title': 'Ai fost adăugat la eveniment',
        'content': body,
        'read': false,
        'recipient_scope': 'user',
      });
    }

    if (inserts.isNotEmpty) {
      await _messages.sendBatch(inserts);
    }
  }

  bool _isOverlapConstraint(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('prevent_overlapping_events') ||
        message.contains('exclusion constraint') ||
        message.contains('23p01');
  }

  String _formatDateForError(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  String _formatTimeForError(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  static DateTime _normalizeAllDayStart(DateTime d) => DateTime(d.year, d.month, d.day, 0, 0);
  static DateTime _normalizeAllDayEnd(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59);

  static String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static const _monthNames = [
    'ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie',
    'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie',
  ];
}
