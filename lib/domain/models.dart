// Domain models with Supabase serialization.
import 'enums.dart';

// ──────────────────────────────────────────────
// Organization
// ──────────────────────────────────────────────

class Organization {
  final String id;
  final String name;
  final String? googleEmail;

  const Organization({
    required this.id,
    required this.name,
    this.googleEmail,
  });

  factory Organization.fromMap(Map<String, dynamic> map) {
    return Organization(
      id: (map['id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      googleEmail: map['google_email']?.toString(),
    );
  }
}

// ──────────────────────────────────────────────
// UserProfile
// ──────────────────────────────────────────────

class UserProfile {
  final String id;
  final String firstName;
  final String lastName;
  final String fullName;
  final String email;
  final String? organizationId;
  final UserRole role;
  final String? organizationName;
  final String? gmailAddress;

  const UserProfile({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.fullName,
    required this.email,
    this.organizationId,
    required this.role,
    this.organizationName,
    this.gmailAddress,
  });

  String get displayName {
    if (fullName.isNotEmpty) return fullName;
    final merged = '$firstName $lastName'.trim();
    return merged.isNotEmpty ? merged : email.split('@').first;
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    final orgData = map['organizations'];
    String? orgName;
    if (orgData is Map) {
      orgName = (orgData['name'] ?? '').toString();
    }

    return UserProfile(
      id: (map['id'] ?? '').toString(),
      firstName: (map['first_name'] ?? '').toString().trim(),
      lastName: (map['last_name'] ?? '').toString().trim(),
      fullName: (map['full_name'] ?? '').toString().trim(),
      email: (map['email'] ?? '').toString().trim(),
      organizationId: map['organization_id']?.toString(),
      role: UserRole.fromString(map['role']?.toString()),
      organizationName: orgName,
      gmailAddress: map['gmail_address']?.toString(),
    );
  }
}

// ──────────────────────────────────────────────
// CalendarEvent
// ──────────────────────────────────────────────

class CalendarEvent {
  final String id;
  final String title;
  final String eventType;
  final String location;
  final DateTime startTime;
  final DateTime endTime;
  final String organizationId;
  final String createdBy;
  final List<String> participants;
  final EventScope scope;
  final String? ownerUserId;
  final String? sourceRequestId;
  final String? status;
  final bool sourceAllDay;
  final String? sourceProvider;

  const CalendarEvent({
    required this.id,
    required this.title,
    required this.eventType,
    required this.location,
    required this.startTime,
    required this.endTime,
    required this.organizationId,
    required this.createdBy,
    this.participants = const [],
    this.scope = EventScope.organization,
    this.ownerUserId,
    this.sourceRequestId,
    this.status,
    this.sourceAllDay = false,
    this.sourceProvider,
  });

  ManagedLocation? get managedLocation => ManagedLocation.fromString(location);

  bool get isAllDay => sourceAllDay || isAllDayRange(startTime, endTime);
  bool get isImportedGoogle => (sourceProvider ?? '').toLowerCase() == 'google';

  // Google all-day events are date-based; using UTC day prevents timezone spillover
  // where a one-day all-day event appears across two local days.
  DateTime get calendarDisplayStart {
    if (!isAllDay) return startTime;
    if (!sourceAllDay) return DateTime(startTime.year, startTime.month, startTime.day, 0, 0);
    final sUtc = startTime.toUtc();
    return DateTime(sUtc.year, sUtc.month, sUtc.day, 0, 0);
  }

  DateTime get calendarDisplayEnd {
    if (!isAllDay) return endTime;
    if (!sourceAllDay) return DateTime(endTime.year, endTime.month, endTime.day, 23, 59);
    final eUtc = endTime.toUtc();
    return DateTime(eUtc.year, eUtc.month, eUtc.day, 23, 59);
  }

  /// Check if two DateTimes represent a visible all-day range.
  static bool isAllDayRange(DateTime start, DateTime end) {
    if (start.hour == 9 &&
        start.minute == 0 &&
        end.hour == 23 &&
        end.minute == 0 &&
        end.isAfter(start)) {
      return true;
    }
    return start.hour == 0 &&
        start.minute == 0 &&
        end.hour == 23 &&
        end.minute == 59 &&
        end.isAfter(start);
  }

  factory CalendarEvent.fromMap(Map<String, dynamic> map) {
    final participantsList = (map['participants'] as List<dynamic>? ?? [])
        .map((p) => p.toString().trim())
        .where((p) => p.isNotEmpty)
        .toList();

    return CalendarEvent(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      eventType: (map['event_type'] ?? '').toString(),
      location: (map['location'] ?? '').toString(),
      startTime: DateTime.parse(map['start_time']).toLocal(),
      endTime: DateTime.parse(map['end_time']).toLocal(),
      organizationId: (map['organization_id'] ?? '').toString(),
      createdBy: (map['created_by'] ?? '').toString(),
      participants: participantsList,
      scope: EventScope.fromString(map['event_scope']?.toString()),
      ownerUserId: map['owner_user_id']?.toString(),
      sourceRequestId: map['source_request_id']?.toString(),
      status: map['status']?.toString(),
      sourceAllDay: map['source_all_day'] == true,
      sourceProvider: map['source_provider']?.toString(),
    );
  }

  Map<String, dynamic> toInsertMap() {
    return {
      'title': title,
      'event_type': eventType,
      'location': location,
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': endTime.toUtc().toIso8601String(),
      'organization_id': organizationId,
      'created_by': createdBy,
      'participants': participants,
      'event_scope': scope.name,
      'source_all_day': sourceAllDay,
      if (ownerUserId != null) 'owner_user_id': ownerUserId,
      if (sourceRequestId != null) 'source_request_id': sourceRequestId,
    };
  }
}

// ──────────────────────────────────────────────
// EventRequest
// ──────────────────────────────────────────────

class EventRequest {
  final String id;
  final String? eventId;
  final DateTime requestedStart;
  final DateTime requestedEnd;
  final String? targetOrgId;
  final String? requestedByOrgId;
  final String? message;
  final RequestStatus status;
  final String? createdBy;
  final DateTime? createdAt;
  final String requestType;
  final Map<String, dynamic> offerPayload;

  // Joined data from events table
  final String? eventTitle;
  final String? eventType;
  final String? eventLocation;
  final String? solicitantName;

  const EventRequest({
    required this.id,
    this.eventId,
    required this.requestedStart,
    required this.requestedEnd,
    this.targetOrgId,
    this.requestedByOrgId,
    this.message,
    required this.status,
    this.createdBy,
    this.createdAt,
    this.requestType = 'overflow',
    this.offerPayload = const {},
    this.eventTitle,
    this.eventType,
    this.eventLocation,
    this.solicitantName,
  });

  bool get isOverflow => requestType == 'overflow';
  bool get isOpen => status == RequestStatus.open;
  bool get isOrphan => (eventId ?? '').isEmpty;
  bool get hasAllDayIntent => offerPayload['all_day_intent'] == true;

  String get displayTitle =>
      eventTitle ??
      (offerPayload['title'] ?? 'Interval').toString();

  String get displayType =>
      eventType ??
      (offerPayload['event_type'] ?? requestType).toString();

  String get overflowGroupId =>
      (offerPayload['overflow_group_id'] ?? id).toString();

  DateTime? get intendedStart {
    final raw = offerPayload['intended_start_time'];
    if (raw == null) return null;
    try {
      return DateTime.parse(raw.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  DateTime? get intendedEnd {
    final raw = offerPayload['intended_end_time'];
    if (raw == null) return null;
    try {
      return DateTime.parse(raw.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> get ownedSegments {
    final raw = offerPayload['all_day_owned_segments'] ??
        offerPayload['owned_segments'];
    if (raw is List) {
      return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    }
    return [];
  }

  factory EventRequest.fromMap(Map<String, dynamic> map) {
    final payloadRaw = map['offer_payload_json'];
    final payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : <String, dynamic>{};

    final eventsData = map['events'];
    String? evTitle, evType, evLocation;
    if (eventsData is Map) {
      evTitle = eventsData['title']?.toString();
      evType = eventsData['event_type']?.toString();
      evLocation = eventsData['location']?.toString();
    }

    final solicitantData = map['solicitant'];
    String? solicitant;
    if (solicitantData is Map) {
      solicitant = (solicitantData['full_name'] ?? '').toString();
    }

    return EventRequest(
      id: (map['id'] ?? '').toString(),
      eventId: map['event_id']?.toString(),
      requestedStart: DateTime.parse(map['requested_start']).toLocal(),
      requestedEnd: DateTime.parse(map['requested_end']).toLocal(),
      targetOrgId: map['target_org_id']?.toString(),
      requestedByOrgId: map['requested_by_org_id']?.toString(),
      message: map['message']?.toString(),
      status: RequestStatus.fromString(map['status']?.toString()),
      createdBy: map['created_by']?.toString(),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())?.toLocal()
          : null,
      requestType: (map['request_type'] ?? 'overflow').toString(),
      offerPayload: payload,
      eventTitle: evTitle,
      eventType: evType,
      eventLocation: evLocation,
      solicitantName: solicitant,
    );
  }
}

// ──────────────────────────────────────────────
// Schedule Anchor & Override
// ──────────────────────────────────────────────

class ScheduleAnchor {
  final String id;
  final DateTime anchorDate;
  final bool isMagicMondayMorning;
  final bool isMagicWeekend;

  const ScheduleAnchor({
    required this.id,
    required this.anchorDate,
    required this.isMagicMondayMorning,
    required this.isMagicWeekend,
  });

  factory ScheduleAnchor.fromMap(Map<String, dynamic> map) {
    return ScheduleAnchor(
      id: (map['id'] ?? '').toString(),
      anchorDate: DateTime.parse(map['anchor_date']).toLocal(),
      isMagicMondayMorning: map['is_magic_monday_morning'] == true,
      isMagicWeekend: map['is_magic_weekend'] == true,
    );
  }
}

class ScheduleOverride {
  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final String? organizationId;

  const ScheduleOverride({
    required this.id,
    required this.startTime,
    required this.endTime,
    this.organizationId,
  });

  factory ScheduleOverride.fromMap(Map<String, dynamic> map) {
    return ScheduleOverride(
      id: (map['id'] ?? '').toString(),
      startTime: DateTime.parse(map['start_time']).toLocal(),
      endTime: DateTime.parse(map['end_time']).toLocal(),
      organizationId: map['organization_id']?.toString(),
    );
  }
}

// ──────────────────────────────────────────────
// Ownership Segment (computed, not stored)
// ──────────────────────────────────────────────

class OwnershipSegment {
  final DateTime start;
  final DateTime end;
  final bool isOwn;
  final String? orgId;

  const OwnershipSegment({
    required this.start,
    required this.end,
    required this.isOwn,
    this.orgId,
  });
}

// ──────────────────────────────────────────────
// AppMessage
// ──────────────────────────────────────────────

class AppMessage {
  final String id;
  final String senderId;
  final String receiverId;
  final String content;
  final String? title;
  final bool read;
  final DateTime createdAt;
  final String? recipientScope;
  final String? recipientRoleFilter;

  const AppMessage({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    this.title,
    required this.read,
    required this.createdAt,
    this.recipientScope,
    this.recipientRoleFilter,
  });

  factory AppMessage.fromMap(Map<String, dynamic> map) {
    return AppMessage(
      id: (map['id'] ?? '').toString(),
      senderId: (map['sender_id'] ?? '').toString(),
      receiverId: (map['receiver_id'] ?? '').toString(),
      content: (map['content'] ?? '').toString(),
      title: map['title']?.toString(),
      read: map['read'] == true,
      createdAt: DateTime.parse(map['created_at']).toLocal(),
      recipientScope: map['recipient_scope']?.toString(),
      recipientRoleFilter: map['recipient_role_filter']?.toString(),
    );
  }
}

// ──────────────────────────────────────────────
// AppNotification
// ──────────────────────────────────────────────

class AppNotification {
  final String id;
  final String userId;
  final String type;
  final String title;
  final String? body;
  final Map<String, dynamic> data;
  final bool read;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    this.body,
    this.data = const {},
    required this.read,
    required this.createdAt,
  });

  factory AppNotification.fromMap(Map<String, dynamic> map) {
    return AppNotification(
      id: (map['id'] ?? '').toString(),
      userId: (map['user_id'] ?? '').toString(),
      type: (map['type'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      body: map['body']?.toString(),
      data: map['data_json'] is Map
          ? Map<String, dynamic>.from(map['data_json'])
          : const {},
      read: map['read'] == true,
      createdAt: DateTime.parse(map['created_at']).toLocal(),
    );
  }
}
