// User availability service – detects busy intervals for organization members.
import '../data/repositories.dart';

class BusyInfo {
  final double ratio;
  final List<String> details;
  const BusyInfo({required this.ratio, required this.details});
  bool get isBusy => ratio >= 1.0;
}

class UserAvailabilityService {
  final EventRepository _events;
  final RequestRepository _requests;

  UserAvailabilityService({
    EventRepository? events,
    RequestRepository? requests,
  })  : _events = events ?? EventRepository(),
        _requests = requests ?? RequestRepository();

  /// Compute busy ratio and details for each user in [userNames] during [start]-[end].
  Future<Map<String, BusyInfo>> computeBusy({
    required String orgId,
    required Map<String, String> nameToUserId,
    required DateTime start,
    required DateTime end,
    String? excludeEventId,
  }) async {
    if (nameToUserId.isEmpty || !end.isAfter(start)) return {};

    final totalMinutes = end.difference(start).inMinutes;
    if (totalMinutes <= 0) return {};

    // Fetch org events + personal events + open requests
    final orgEventsRaw = await _events.fetchRawForAvailability(orgId);
    final personalEventsRaw = await _events.fetchPersonalByUserIds(
      nameToUserId.values.toList(),
    );
    final openRequestsRaw = await _requests.fetchOpenByOrgRaw(orgId);

    final ranges = <String, List<_TimeRange>>{};
    final details = <String, List<String>>{};

    void addRange(String name, DateTime overlapStart, DateTime overlapEnd, String label) {
      ranges.putIfAbsent(name, () => []).add(_TimeRange(overlapStart, overlapEnd));
      details.putIfAbsent(name, () => []).add(label);
    }

    // Process org events
    for (final raw in orgEventsRaw) {
      final eid = raw['id']?.toString() ?? '';
      if (eid == excludeEventId) continue;
      final evStart = DateTime.tryParse(raw['start_time']?.toString() ?? '')?.toLocal();
      final evEnd = DateTime.tryParse(raw['end_time']?.toString() ?? '')?.toLocal();
      if (evStart == null || evEnd == null) continue;
      if (!evStart.isBefore(end) || !evEnd.isAfter(start)) continue;

      final overlapStart = evStart.isAfter(start) ? evStart : start;
      final overlapEnd = evEnd.isBefore(end) ? evEnd : end;
      final participants = (raw['participants'] as List<dynamic>?)?.map((p) => p.toString()).toList() ?? [];
      final label = '${raw['event_type'] ?? 'Eveniment'}: ${raw['title'] ?? ''} '
          '(${_fmtTime(overlapStart)}-${_fmtTime(overlapEnd)})';

      for (final name in participants) {
        if (nameToUserId.containsKey(name)) {
          addRange(name, overlapStart, overlapEnd, label);
        }
      }
    }

    // Process personal events
    for (final raw in personalEventsRaw) {
      final evStart = DateTime.tryParse(raw['start_time']?.toString() ?? '')?.toLocal();
      final evEnd = DateTime.tryParse(raw['end_time']?.toString() ?? '')?.toLocal();
      if (evStart == null || evEnd == null) continue;
      if (!evStart.isBefore(end) || !evEnd.isAfter(start)) continue;

      final overlapStart = evStart.isAfter(start) ? evStart : start;
      final overlapEnd = evEnd.isBefore(end) ? evEnd : end;
      final ownerId = raw['owner_user_id']?.toString() ?? '';
      final label = 'Personal: ${raw['title'] ?? ''} '
          '(${_fmtTime(overlapStart)}-${_fmtTime(overlapEnd)})';

      for (final entry in nameToUserId.entries) {
        if (entry.value == ownerId) {
          addRange(entry.key, overlapStart, overlapEnd, label);
        }
      }
    }

    // Process open requests
    for (final raw in openRequestsRaw) {
      final rStart = DateTime.tryParse(raw['requested_start']?.toString() ?? '')?.toLocal();
      final rEnd = DateTime.tryParse(raw['requested_end']?.toString() ?? '')?.toLocal();
      if (rStart == null || rEnd == null) continue;
      if (!rStart.isBefore(end) || !rEnd.isAfter(start)) continue;

      final payload = raw['offer_payload_json'];
      if (payload is! Map) continue;
      final participants = (payload['participants'] as List<dynamic>?)?.map((p) => p.toString()).toList() ?? [];
      final overlapStart = rStart.isAfter(start) ? rStart : start;
      final overlapEnd = rEnd.isBefore(end) ? rEnd : end;
      final label = 'Cerere: ${payload['title'] ?? ''} '
          '(${_fmtTime(overlapStart)}-${_fmtTime(overlapEnd)})';

      for (final name in participants) {
        if (nameToUserId.containsKey(name)) {
          addRange(name, overlapStart, overlapEnd, label);
        }
      }
    }

    // Compute ratios
    final result = <String, BusyInfo>{};
    for (final name in nameToUserId.keys) {
      final userRanges = ranges[name];
      if (userRanges == null || userRanges.isEmpty) {
        result[name] = const BusyInfo(ratio: 0.0, details: []);
        continue;
      }
      final merged = _mergeRanges(userRanges);
      int busyMinutes = 0;
      for (final r in merged) {
        busyMinutes += r.end.difference(r.start).inMinutes;
      }
      final ratio = (busyMinutes / totalMinutes).clamp(0.0, 1.0);
      result[name] = BusyInfo(ratio: ratio, details: details[name] ?? []);
    }
    return result;
  }

  static List<_TimeRange> _mergeRanges(List<_TimeRange> ranges) {
    if (ranges.isEmpty) return [];
    final sorted = List<_TimeRange>.from(ranges)..sort((a, b) => a.start.compareTo(b.start));
    final merged = <_TimeRange>[sorted.first];
    for (int i = 1; i < sorted.length; i++) {
      final last = merged.last;
      if (sorted[i].start.isBefore(last.end) || sorted[i].start.isAtSameMomentAs(last.end)) {
        merged[merged.length - 1] = _TimeRange(
          last.start,
          sorted[i].end.isAfter(last.end) ? sorted[i].end : last.end,
        );
      } else {
        merged.add(sorted[i]);
      }
    }
    return merged;
  }

  static String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

class _TimeRange {
  final DateTime start;
  final DateTime end;
  const _TimeRange(this.start, this.end);
}
