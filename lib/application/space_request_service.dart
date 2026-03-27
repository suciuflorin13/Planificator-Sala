// Request handling service – approve, reject, delete requests.
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/enums.dart';
import '../domain/models.dart';
import '../data/repositories.dart';
import 'space_ownership_service.dart';

class SpaceRequestService {
  final RequestRepository _requests;
  final EventRepository _events;
  final ScheduleRepository _schedule;

  SpaceRequestService({
    RequestRepository? requests,
    EventRepository? events,
    ScheduleRepository? schedule,
  })  : _requests = requests ?? RequestRepository(),
        _events = events ?? EventRepository(),
        _schedule = schedule ?? ScheduleRepository();

  String get _currentUserId => Supabase.instance.client.auth.currentUser!.id;

  /// Approve a request – creates event, adds schedule override, deletes request.
  Future<void> approveRequest(
    EventRequest request,
    SpaceOwnershipService ownership,
  ) async {
    final segmentedMode = request.offerPayload['segmented_mode'] == true;
    if (request.hasAllDayIntent && !segmentedMode) {
      await _approveAllDayMasterRequest(request, ownership);
    } else if (request.hasAllDayIntent && segmentedMode) {
      await _approveSegmentedSimpleRequest(request, ownership);
    } else {
      await _approveSingleRequest(request, ownership);
    }
  }

  /// Reject a request.
  /// For all-day master flows, this triggers segmentation and switches remaining
  /// requests to simple-event mode.
  Future<void> rejectRequest(
    EventRequest request,
    SpaceOwnershipService ownership,
  ) async {
    final segmentedMode = request.offerPayload['segmented_mode'] == true;
    if (request.hasAllDayIntent && !segmentedMode) {
      await _segmentAllDayOnReject(request, ownership);
    } else {
      await _requests.delete(request.id);
    }
  }

  /// Delete a request (by the creator).
  Future<void> deleteRequest(String requestId) async {
    await _requests.delete(requestId);
  }

  /// Update request time range and message.
  Future<void> updateRequest(
    String requestId, {
    required DateTime start,
    required DateTime end,
    required String message,
  }) async {
    await _requests.update(requestId, {
      'requested_start': start.toUtc().toIso8601String(),
      'requested_end': end.toUtc().toIso8601String(),
      'message': message,
    });
  }

  // ─────── Private ───────

  Future<void> _approveAllDayMasterRequest(
    EventRequest request,
    SpaceOwnershipService ownership,
  ) async {
    final payload = request.offerPayload;
    final byOrgId = request.requestedByOrgId ??
        payload['organization_id']?.toString() ??
        '';

    await _validateFoaierConflict(
      request: request,
      ownership: ownership,
      location: (payload['location'] ?? 'Sala').toString(),
      type: (payload['event_type'] ?? 'Eveniment').toString(),
      ignoreEventId: request.eventId,
    );

    await _schedule.insertOverride(
      start: request.requestedStart,
      end: request.requestedEnd,
      organizationId: byOrgId,
      createdBy: _currentUserId,
    );
    await _requests.delete(request.id);
  }

  Future<void> _approveSegmentedSimpleRequest(
    EventRequest request,
    SpaceOwnershipService ownership,
  ) async {
    final payload = request.offerPayload;
    final orgId = (request.requestedByOrgId ??
            payload['organization_id']?.toString() ??
            '')
        .trim();
    if (orgId.isEmpty) {
      throw Exception('Nu s-a putut determina organizația pentru aprobarea cererii.');
    }

    final location = (payload['location'] ?? 'Sala').toString();
    final type = (payload['event_type'] ?? 'Eveniment').toString();

    await _validateFoaierConflict(
      request: request,
      ownership: ownership,
      location: location,
      type: type,
      ignoreEventId: request.eventId,
    );

    await _mergeOrInsertSimpleEvent(
      request: request,
      payload: payload,
      orgId: orgId,
    );

    await _schedule.insertOverride(
      start: request.requestedStart,
      end: request.requestedEnd,
      organizationId: orgId,
      createdBy: _currentUserId,
    );

    await _requests.delete(request.id);
  }

  Future<void> _approveSingleRequest(
    EventRequest request,
    SpaceOwnershipService ownership,
  ) async {
    final payload = request.offerPayload;

    // Foaier conflict check
    Map<String, dynamic>? event;
    if (request.eventId != null && request.eventId!.isNotEmpty) {
      try {
        event = (await _events.fetchById(request.eventId!)).toInsertMap();
        event['id'] = request.eventId;
      } catch (_) {
        event = null;
      }
    }

    final location = (event?['location'] ?? payload['location'] ?? '').toString();
    final type = (event?['event_type'] ?? payload['event_type'] ?? '').toString();

    if (ManagedLocation.fromString(location) == ManagedLocation.sala &&
        (EventTypes.isHallBlocking(type) ||
            ManagedLocation.isSalaWithBlockedFoaier(location))) {
      if (ownership.hasFoaierOverlap(
        request.requestedStart,
        request.requestedEnd,
        ignoreEventId: request.eventId,
      )) {
        throw Exception(
          'Cererea nu poate fi acceptată: intervalul se suprapune cu un eveniment din Foaier.',
        );
      }
    }

    if (event != null && request.eventId != null) {
      final eventStart = DateTime.parse(event['start_time']).toLocal();
      final eventEnd = DateTime.parse(event['end_time']).toLocal();
      final alreadyCovered =
          !request.requestedStart.isBefore(eventStart) &&
          !request.requestedEnd.isAfter(eventEnd);

      if (!alreadyCovered) {
        final contiguousForward =
            eventEnd.isAtSameMomentAs(request.requestedStart);
        final contiguousBackward =
            eventStart.isAtSameMomentAs(request.requestedEnd);

        if (contiguousForward || contiguousBackward) {
          final newStart = contiguousBackward
              ? request.requestedStart.toUtc().toIso8601String()
              : event['start_time'];
          final newEnd = contiguousForward
              ? request.requestedEnd.toUtc().toIso8601String()
              : event['end_time'];
          await _events.update(request.eventId!, {
            'start_time': newStart,
            'end_time': newEnd,
          });
        } else {
          final testOverlap = !request.requestedStart.isAfter(eventEnd) &&
              !request.requestedEnd.isBefore(eventStart);
          if (!testOverlap) {
            await _events.insert({
              'title': event['title'],
              'event_type': event['event_type'],
              'location': event['location'],
              'participants': event['participants'] ?? [],
              'start_time': request.requestedStart.toUtc().toIso8601String(),
              'end_time': request.requestedEnd.toUtc().toIso8601String(),
              'organization_id': event['organization_id'],
              'created_by': event['created_by'],
              'source_request_id': request.id,
              'event_scope': 'organization',
            });
          }
        }
      }
    } else {
      await _events.insert({
        'title': (payload['title'] ?? 'Eveniment').toString(),
        'event_type': (payload['event_type'] ?? 'special').toString(),
        'location': (payload['location'] ?? 'Sala').toString(),
        'participants': payload['participants'] ?? [],
        'start_time': request.requestedStart.toUtc().toIso8601String(),
        'end_time': request.requestedEnd.toUtc().toIso8601String(),
        'organization_id': payload['organization_id'] ?? request.requestedByOrgId,
        'created_by': payload['created_by'] ?? request.createdBy,
        'source_request_id': request.id,
        'event_scope': 'organization',
      });
    }

    // Add schedule override for the approved slot
    await _schedule.insertOverride(
      start: request.requestedStart,
      end: request.requestedEnd,
      organizationId: request.requestedByOrgId,
      createdBy: _currentUserId,
    );

    // Delete the request
    await _requests.delete(request.id);
  }

  Future<void> _segmentAllDayOnReject(
    EventRequest request,
    SpaceOwnershipService ownership,
  ) async {
    final payload = request.offerPayload;
    final orgId = (request.requestedByOrgId ??
            payload['organization_id']?.toString() ??
            '')
        .trim();
    if (orgId.isEmpty) {
      throw Exception('Nu s-a putut determina organizația pentru segmentare.');
    }

    final location = (payload['location'] ?? 'Sala').toString();
    final type = (payload['event_type'] ?? 'Eveniment').toString();
    final title = (payload['title'] ?? 'Eveniment').toString();
    final participants = payload['participants'] ?? <dynamic>[];
    final createdBy = payload['created_by'] ?? request.createdBy;
    final overflowGroupId = request.overflowGroupId;

    final intendedStart = _dayStart(request.intendedStart ?? request.requestedStart);
    final intendedEnd = _dayEnd(request.intendedEnd ?? request.requestedEnd);
    final managedLocation = ManagedLocation.fromString(location);

    // IMPORTANT FK order: requests -> events
    // Clear event_id references in grouped open requests before deleting master events.
    await _detachGroupedOpenRequestEventRefs(
      requestedByOrgId: orgId,
      overflowGroupId: overflowGroupId,
    );

    await _requests.delete(request.id);

    // Ensure master all-day blocks are removed before rebuilding segmented events.
    await _removeStaleAllDayMasters(
      orgId: orgId,
      title: title,
      location: location,
      intendedStart: intendedStart,
      intendedEnd: intendedEnd,
    );

    final remaining = await _requests.fetchGroupedRequests(
      requestedByOrgId: orgId,
      overflowGroupId: overflowGroupId,
    );

    for (final req in remaining) {
      final updatedPayload = Map<String, dynamic>.from(req.offerPayload);
      updatedPayload['segmented_mode'] = true;
      await _requests.update(req.id, {
        'event_id': null,
        'offer_payload_json': updatedPayload,
      });
    }

    if (managedLocation == null) return;

    final allDayDays = <DateTime>[];
    final timedSegments = <Map<String, DateTime>>[];

    var day = _dayStart(intendedStart);
    final lastDay = _dayStart(intendedEnd);
    while (!day.isAfter(lastDay)) {
      final dayStart = DateTime(day.year, day.month, day.day, 9);
      final dayEnd = DateTime(day.year, day.month, day.day, 23);
      final segments = ownership.computeSegments(
        start: dayStart,
        end: dayEnd,
        location: managedLocation,
        userOrgId: orgId,
      );

      final own = segments.where((s) => s.isOwn && s.end.isAfter(s.start)).toList();
      if (own.isNotEmpty) {
        final fullDayOwn = own.length == 1 &&
            own.first.start.isAtSameMomentAs(dayStart) &&
            own.first.end.isAtSameMomentAs(dayEnd);

        if (fullDayOwn) {
          allDayDays.add(day);
        } else {
          for (final s in own) {
            timedSegments.add({'start': s.start, 'end': s.end});
          }
        }
      }

      day = day.add(const Duration(days: 1));
    }

    for (final seg in timedSegments) {
      try {
        await _events.insert({
          'title': title,
          'event_type': type,
          'location': location,
          'participants': participants,
          'start_time': seg['start']!.toUtc().toIso8601String(),
          'end_time': seg['end']!.toUtc().toIso8601String(),
          'organization_id': orgId,
          'created_by': createdBy,
          'source_request_id': request.id,
          'event_scope': 'organization',
        });
      } catch (e) {
        if (!_isOverlapConstraint(e)) rethrow;
      }
    }

    if (allDayDays.isEmpty) return;
    allDayDays.sort((a, b) => a.compareTo(b));
    DateTime blockStart = allDayDays.first;
    DateTime blockEnd = allDayDays.first;

    for (int i = 1; i < allDayDays.length; i++) {
      final cur = allDayDays[i];
      final expected = blockEnd.add(const Duration(days: 1));
      if (_dayStart(cur).isAtSameMomentAs(_dayStart(expected))) {
        blockEnd = cur;
        continue;
      }
      try {
        await _events.insert({
          'title': title,
          'event_type': type,
          'location': location,
          'participants': participants,
          'start_time': _dayStart(blockStart).toUtc().toIso8601String(),
          'end_time': _dayEnd(blockEnd).toUtc().toIso8601String(),
          'organization_id': orgId,
          'created_by': createdBy,
          'source_request_id': request.id,
          'event_scope': 'organization',
        });
      } catch (e) {
        if (!_isOverlapConstraint(e)) rethrow;
      }
      blockStart = cur;
      blockEnd = cur;
    }

    try {
      await _events.insert({
        'title': title,
        'event_type': type,
        'location': location,
        'participants': participants,
        'start_time': _dayStart(blockStart).toUtc().toIso8601String(),
        'end_time': _dayEnd(blockEnd).toUtc().toIso8601String(),
        'organization_id': orgId,
        'created_by': createdBy,
        'source_request_id': request.id,
        'event_scope': 'organization',
      });
    } catch (e) {
      if (!_isOverlapConstraint(e)) rethrow;
    }
  }

  Future<void> _mergeOrInsertSimpleEvent({
    required EventRequest request,
    required Map<String, dynamic> payload,
    required String orgId,
  }) async {
    final title = (payload['title'] ?? 'Eveniment').toString();
    final type = (payload['event_type'] ?? 'special').toString();
    final location = (payload['location'] ?? 'Sala').toString();
    final participants = payload['participants'] ?? <dynamic>[];
    final createdBy = payload['created_by'] ?? request.createdBy;

    final allEvents = await _events.fetchRawByOrgSorted(orgId);
    final candidates = allEvents.where((e) {
      final evTitle = (e['title'] ?? '').toString();
      final evLocation = (e['location'] ?? '').toString();
      return evTitle == title && evLocation == location;
    }).toList();

    final touching = <Map<String, dynamic>>[];
    for (final c in candidates) {
      final cStart = DateTime.parse(c['start_time'].toString()).toLocal();
      final cEnd = DateTime.parse(c['end_time'].toString()).toLocal();
      if (_timeTouchOrOverlap(request.requestedStart, request.requestedEnd, cStart, cEnd)) {
        touching.add(c);
      }
    }

    DateTime mergedStart = request.requestedStart;
    DateTime mergedEnd = request.requestedEnd;
    for (final e in touching) {
      final s = DateTime.parse(e['start_time'].toString()).toLocal();
      final en = DateTime.parse(e['end_time'].toString()).toLocal();
      if (s.isBefore(mergedStart)) mergedStart = s;
      if (en.isAfter(mergedEnd)) mergedEnd = en;
    }

    final touchingIds = touching
        .map((e) => (e['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    for (final e in allEvents) {
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty || touchingIds.contains(id)) continue;
      if ((e['location'] ?? '').toString() != location) continue;
      final s = DateTime.parse(e['start_time'].toString()).toLocal();
      final en = DateTime.parse(e['end_time'].toString()).toLocal();
      if (_timeOverlap(mergedStart, mergedEnd, s, en)) {
        throw Exception('Cererea nu poate fi acceptată: intervalul rezultat se suprapune cu un alt eveniment existent.');
      }
    }

    if (touching.isEmpty) {
      await _events.insert({
        'title': title,
        'event_type': type,
        'location': location,
        'participants': participants,
        'start_time': mergedStart.toUtc().toIso8601String(),
        'end_time': mergedEnd.toUtc().toIso8601String(),
        'organization_id': orgId,
        'created_by': createdBy,
        'source_request_id': request.id,
        'event_scope': 'organization',
      });
      return;
    }

    touching.sort((a, b) => DateTime.parse(a['start_time'].toString())
        .compareTo(DateTime.parse(b['start_time'].toString())));
    final anchorId = (touching.first['id'] ?? '').toString();
    if (anchorId.isEmpty) {
      throw Exception('Nu s-a putut identifica evenimentul principal pentru unificare.');
    }

    for (final e in touching.skip(1)) {
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;
      await _events.delete(id);
    }

    await _events.update(anchorId, {
      'start_time': mergedStart.toUtc().toIso8601String(),
      'end_time': mergedEnd.toUtc().toIso8601String(),
    });
  }

  Future<void> _validateFoaierConflict({
    required EventRequest request,
    required SpaceOwnershipService ownership,
    required String location,
    required String type,
    String? ignoreEventId,
  }) async {
    if (ManagedLocation.fromString(location) == ManagedLocation.sala &&
        (EventTypes.isHallBlocking(type) ||
            ManagedLocation.isSalaWithBlockedFoaier(location))) {
      if (ownership.hasFoaierOverlap(
        request.requestedStart,
        request.requestedEnd,
        ignoreEventId: ignoreEventId,
      )) {
        throw Exception(
          'Cererea nu poate fi acceptată: intervalul se suprapune cu un eveniment din Foaier.',
        );
      }
    }
  }

  Future<void> _detachGroupedOpenRequestEventRefs({
    required String requestedByOrgId,
    required String overflowGroupId,
  }) async {
    if (requestedByOrgId.isEmpty || overflowGroupId.isEmpty) return;

    final grouped = await _requests.fetchGroupedRequests(
      requestedByOrgId: requestedByOrgId,
      overflowGroupId: overflowGroupId,
    );

    for (final req in grouped) {
      final payload = Map<String, dynamic>.from(req.offerPayload);
      payload['segmented_mode'] = true;

      if ((req.eventId ?? '').isNotEmpty) {
        await _requests.update(req.id, {
          'event_id': null,
          'offer_payload_json': payload,
        });
      } else {
        await _requests.update(req.id, {
          'offer_payload_json': payload,
        });
      }
    }
  }

  Future<void> _removeStaleAllDayMasters({
    required String orgId,
    required String title,
    required String location,
    required DateTime intendedStart,
    required DateTime intendedEnd,
  }) async {
    final seriesStart = _dayStart(intendedStart);
    final seriesEnd = _dayEnd(intendedEnd);
    final allEvents = await _events.fetchRawByOrgSorted(orgId);

    for (final e in allEvents) {
      if ((e['title'] ?? '').toString() != title) continue;
      if ((e['location'] ?? '').toString() != location) continue;

      final start = DateTime.parse(e['start_time'].toString()).toLocal();
      final end = DateTime.parse(e['end_time'].toString()).toLocal();
      final isAllDay = CalendarEvent.isAllDayRange(start, end);
      final overlapsSeries = _timeOverlap(start, end, seriesStart, seriesEnd);
      // Only delete a true master interval (covers the whole intended range).
      // Keep segmented all-day blocks (e.g. single day 24 or 27) intact.
      final coversFullRange =
          !start.isAfter(seriesStart) && !end.isBefore(seriesEnd);
      if (!isAllDay || !overlapsSeries || !coversFullRange) continue;

      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;
      await _events.delete(id);
    }
  }

  DateTime _dayStart(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  DateTime _dayEnd(DateTime value) =>
      DateTime(value.year, value.month, value.day, 23, 59);

  bool _timeOverlap(
    DateTime startA,
    DateTime endA,
    DateTime startB,
    DateTime endB,
  ) {
    return !startA.isAfter(endB) && !startB.isAfter(endA);
  }

  bool _timeTouchOrOverlap(
    DateTime startA,
    DateTime endA,
    DateTime startB,
    DateTime endB,
  ) {
    return !startA.isAfter(endB) && !startB.isAfter(endA);
  }

  bool _isOverlapConstraint(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('prevent_overlapping_events') ||
        message.contains('exclusion constraint') ||
        message.contains('23p01');
  }
}

