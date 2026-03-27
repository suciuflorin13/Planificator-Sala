// Data layer – all Supabase repository classes.
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/enums.dart';
import '../domain/models.dart';

SupabaseClient get _db => Supabase.instance.client;

// ──────────────────────────────────────────────
// AuthRepository
// ──────────────────────────────────────────────

class AuthRepository {
  String? get currentUserId => _db.auth.currentUser?.id;

  Future<void> signIn(String email, String password) async {
    await _db.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signUp({
    required String email,
    required String password,
    required Map<String, dynamic> metadata,
  }) async {
    await _db.auth.signUp(email: email, password: password, data: metadata);
  }

  Future<void> signOut() async {
    await _db.auth.signOut();
  }

  Stream<AuthState> get onAuthStateChange => _db.auth.onAuthStateChange;
}

// ──────────────────────────────────────────────
// OrganizationRepository
// ──────────────────────────────────────────────

class OrganizationRepository {
  Future<List<Organization>> fetchAll() async {
    final rows = await _db.from('organizations').select();
    return rows.map((r) => Organization.fromMap(r)).toList();
  }

  Future<Organization> fetchById(String id) async {
    final row = await _db.from('organizations').select().eq('id', id).single();
    return Organization.fromMap(row);
  }
}

// ──────────────────────────────────────────────
// ProfileRepository
// ──────────────────────────────────────────────

class ProfileRepository {
  Future<UserProfile> fetchById(String userId) async {
    final row = await _db
        .from('profiles')
        .select('*, organizations(name)')
        .eq('id', userId)
        .single();
    return UserProfile.fromMap(row);
  }

  Future<UserProfile> fetchCurrent() async {
    final userId = _db.auth.currentUser!.id;
    return fetchById(userId);
  }

  Future<List<UserProfile>> fetchByOrg(String orgId) async {
    final rows = await _db
        .from('profiles')
        .select('*, organizations(name)')
        .eq('organization_id', orgId)
        .order('first_name');
    return rows.map((r) => UserProfile.fromMap(r)).toList();
  }

  Future<List<UserProfile>> fetchAll() async {
    final rows = await _db
        .from('profiles')
        .select('*, organizations(name)')
        .order('first_name');
    return rows.map((r) => UserProfile.fromMap(r)).toList();
  }

  Future<void> updateRole(String userId, String newRole) async {
    await _db.from('profiles').update({'role': newRole}).eq('id', userId);
  }

  Future<void> upsert(Map<String, dynamic> data) async {
    await _db.from('profiles').upsert(data, onConflict: 'id');
  }

  Future<void> update(String userId, Map<String, dynamic> patch) async {
    await _db.from('profiles').update(patch).eq('id', userId);
  }
}

// ──────────────────────────────────────────────
// EventRepository
// ──────────────────────────────────────────────

class EventRepository {
  Future<List<CalendarEvent>> fetchAll() async {
    final rows = await _db.from('events').select();
    return rows.map((r) => CalendarEvent.fromMap(r)).toList();
  }

  Future<List<CalendarEvent>> fetchByOrg(String orgId) async {
    final rows = await _db.from('events').select().eq('organization_id', orgId);
    return rows.map((r) => CalendarEvent.fromMap(r)).toList();
  }

  Future<List<CalendarEvent>> fetchForSchedule() async {
    final rows = await _db.from('events').select();
    return rows
        .map((r) => CalendarEvent.fromMap(r))
        .where((e) =>
            e.scope != EventScope.personal &&
            e.managedLocation != null)
        .toList();
  }

  Future<CalendarEvent> fetchById(String id) async {
    final row = await _db.from('events').select().eq('id', id).single();
    return CalendarEvent.fromMap(row);
  }

  Future<String> insert(Map<String, dynamic> data) async {
    final res = await _db.from('events').insert(data).select().single();
    return res['id'].toString();
  }

  Future<void> update(String id, Map<String, dynamic> data) async {
    await _db.from('events').update(data).eq('id', id);
  }

  Future<void> delete(String id) async {
    await _db.from('events').delete().eq('id', id);
  }

  /// Fetch events limited to columns needed for availability checking.
  Future<List<Map<String, dynamic>>> fetchRawForAvailability(String orgId) async {
    final rows = await _db
        .from('events')
        .select('id,start_time,end_time,participants,organization_id,event_scope,owner_user_id,event_type,title')
        .eq('organization_id', orgId);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> fetchPersonalByUserIds(List<String> userIds) async {
    if (userIds.isEmpty) return [];
    final rows = await _db
        .from('events')
        .select('id,start_time,end_time,participants,organization_id,event_scope,owner_user_id,event_type,title')
        .eq('event_scope', 'personal')
        .inFilter('owner_user_id', userIds);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Fetch event history for autocomplete (titles + participants).
  Future<List<Map<String, dynamic>>> fetchHistory(String orgId, {int limit = 300}) async {
    final rows = await _db
        .from('events')
        .select('title,event_type,participants')
        .eq('organization_id', orgId)
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Fetch all raw events for an organization, sorted by start_time (for merging contiguous all-day events).
  Future<List<Map<String, dynamic>>> fetchRawByOrgSorted(String orgId) async {
    final rows = await _db
        .from('events')
        .select()
        .eq('organization_id', orgId)
        .eq('event_scope', 'organization')
        .order('start_time', ascending: true);
    return List<Map<String, dynamic>>.from(rows);
  }
}

// ──────────────────────────────────────────────
// RequestRepository
// ──────────────────────────────────────────────

class RequestRepository {
  static const String _selectWithJoins = '''
    *,
    events (title, event_type, location),
    solicitant:profiles!event_requests_created_by_fkey (full_name)
  ''';

  Future<List<EventRequest>> fetchAll() async {
    final rows = await _db.from('event_requests').select(_selectWithJoins);
    return rows.map((r) => EventRequest.fromMap(r)).toList();
  }

  Future<List<EventRequest>> fetchForOrg(String orgId) async {
    final rows = await _db
        .from('event_requests')
        .select('*, events(title, event_type, location)')
        .or('requested_by_org_id.eq.$orgId,target_org_id.eq.$orgId');
    return rows.map((r) => EventRequest.fromMap(r)).toList();
  }

  Future<List<EventRequest>> fetchOpenByTargetOrg(String orgId) async {
    final rows = await _db
        .from('event_requests')
        .select('id')
        .eq('target_org_id', orgId)
        .eq('status', 'open');
    return rows.map((r) => EventRequest.fromMap(r)).toList();
  }

  Future<EventRequest> fetchById(String id) async {
    final row = await _db
        .from('event_requests')
        .select('*, events(*)')
        .eq('id', id)
        .single();
    return EventRequest.fromMap(row);
  }

  Future<void> insert(Map<String, dynamic> data) async {
    await _db.from('event_requests').insert(data);
  }

  Future<void> insertMany(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    await _db.from('event_requests').insert(rows);
  }

  Future<void> update(String id, Map<String, dynamic> data) async {
    await _db.from('event_requests').update(data).eq('id', id);
  }

  Future<void> delete(String id) async {
    await _db.from('event_requests').delete().eq('id', id);
  }

  Future<void> deleteByEventId(String eventId, {String? status}) async {
    var query = _db.from('event_requests').delete().eq('event_id', eventId);
    if (status != null) {
      query = query.eq('status', status);
    }
    await query;
  }

  Future<void> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    await _db.from('event_requests').delete().inFilter('id', ids);
  }

  /// Fetch all open overflow requests for matching overflow_group_id.
  Future<List<EventRequest>> fetchGroupedRequests({
    required String requestedByOrgId,
    required String overflowGroupId,
  }) async {
    final rows = await _db
        .from('event_requests')
        .select()
        .eq('status', 'open')
        .eq('request_type', 'overflow')
        .eq('requested_by_org_id', requestedByOrgId);

    return List<Map<String, dynamic>>.from(rows)
        .where((item) {
          final payload = item['offer_payload_json'];
          if (payload is! Map) return false;
          if (overflowGroupId.isEmpty) return false;
          return (payload['overflow_group_id'] ?? '').toString() == overflowGroupId;
        })
        .map((r) => EventRequest.fromMap(r))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchOpenByOrgRaw(String orgId) async {
    final rows = await _db
        .from('event_requests')
        .select('requested_start,requested_end,offer_payload_json,requested_by_org_id,status')
        .eq('requested_by_org_id', orgId)
        .eq('status', 'open');
    return List<Map<String, dynamic>>.from(rows);
  }
}

// ──────────────────────────────────────────────
// ScheduleRepository
// ──────────────────────────────────────────────

class ScheduleRepository {
  Future<List<ScheduleAnchor>> fetchAnchors() async {
    final rows = await _db
        .from('schedule_anchors')
        .select()
        .order('created_at', ascending: false);
    return rows.map((r) => ScheduleAnchor.fromMap(r)).toList();
  }

  Future<List<ScheduleOverride>> fetchOverrides() async {
    final rows = await _db
        .from('schedule_overrides')
        .select()
        .order('created_at', ascending: false);
    return rows.map((r) => ScheduleOverride.fromMap(r)).toList();
  }

  Future<void> insertOverride({
    required DateTime start,
    required DateTime end,
    required String? organizationId,
    required String createdBy,
  }) async {
    await _db.from('schedule_overrides').insert({
      'start_time': start.toUtc().toIso8601String(),
      'end_time': end.toUtc().toIso8601String(),
      'organization_id': organizationId,
      'created_by': createdBy,
    });
  }

  Future<void> deleteOverridesInRange(DateTime start, DateTime end) async {
    final existing = await _db
        .from('schedule_overrides')
        .select('id')
        .gte('start_time', start.toUtc().toIso8601String())
        .lt('start_time', end.toUtc().toIso8601String());
    for (final row in List<Map<String, dynamic>>.from(existing)) {
      await _db.from('schedule_overrides').delete().eq('id', row['id']);
    }
  }
}

// ──────────────────────────────────────────────
// MessageRepository
// ──────────────────────────────────────────────

class MessageRepository {
  Future<List<AppMessage>> fetchInbox(String userId) async {
    final rows = await _db
        .from('messages')
        .select()
        .eq('receiver_id', userId)
        .order('created_at', ascending: false);
    return rows.map((r) => AppMessage.fromMap(r)).toList();
  }

  Future<List<AppMessage>> fetchSent(String userId) async {
    final rows = await _db
        .from('messages')
        .select()
        .eq('sender_id', userId)
        .order('created_at', ascending: false);
    return rows.map((r) => AppMessage.fromMap(r)).toList();
  }

  Future<int> countUnread(String userId) async {
    final rows = await _db
        .from('messages')
        .select('id')
        .eq('receiver_id', userId)
        .eq('read', false);
    return (rows as List).length;
  }

  Future<void> markRead(String messageId) async {
    await _db.from('messages').update({'read': true}).eq('id', messageId);
  }

  Future<void> markAllRead(String userId) async {
    await _db
        .from('messages')
        .update({'read': true})
        .eq('receiver_id', userId)
        .eq('read', false);
  }

  Future<void> delete(String messageId) async {
    await _db.from('messages').delete().eq('id', messageId);
  }

  Future<void> send({
    required String senderId,
    required String receiverId,
    required String content,
    String? title,
    String? recipientScope,
  }) async {
    await _db.from('messages').insert({
      'sender_id': senderId,
      'receiver_id': receiverId,
      'content': content,
      ...?(title == null ? null : {'title': title}),
      'read': false,
      ...?(recipientScope == null ? null : {'recipient_scope': recipientScope}),
    });
  }

  Future<void> sendBatch(List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty) return;
    try {
      await _db.from('messages').insert(messages);
    } catch (_) {
      // Fallback without title/scope columns if they don't exist
      final fallback = messages.map((r) => {
        'sender_id': r['sender_id'],
        'receiver_id': r['receiver_id'],
        'content': '${r['title'] ?? ''}\n${r['content'] ?? ''}'.trim(),
        'read': false,
      }).toList();
      await _db.from('messages').insert(fallback);
    }
  }
}

// ──────────────────────────────────────────────
// NotificationRepository
// ──────────────────────────────────────────────

class NotificationRepository {
  Future<List<AppNotification>> fetchForUser(String userId) async {
    final rows = await _db
        .from('notifications')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false);
    return rows.map((r) => AppNotification.fromMap(r)).toList();
  }

  Future<int> countUnread(String userId) async {
    final rows = await _db
        .from('notifications')
        .select('id')
        .eq('user_id', userId)
        .eq('read', false);
    return (rows as List).length;
  }

  Future<void> markRead(String notificationId) async {
    await _db
        .from('notifications')
        .update({'read': true})
        .eq('id', notificationId);
  }

  Future<void> insert({
    required String userId,
    required String type,
    required String title,
    String? body,
    Map<String, dynamic>? data,
  }) async {
    await _db.from('notifications').insert({
      'user_id': userId,
      'type': type,
      'title': title,
      ...?(body == null ? null : {'body': body}),
      'data_json': data ?? {},
      'read': false,
    });
  }
}
