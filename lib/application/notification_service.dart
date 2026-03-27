// Notification service – sends in-app messages for key events.
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/repositories.dart';

class NotificationService {
  final MessageRepository _messages;
  final ProfileRepository _profiles;

  NotificationService({
    MessageRepository? messages,
    ProfileRepository? profiles,
  })  : _messages = messages ?? MessageRepository(),
        _profiles = profiles ?? ProfileRepository();

  String get _currentUserId => Supabase.instance.client.auth.currentUser!.id;

  /// Notify a user that they've been added to an event.
  Future<void> notifyAddedToEvent({
    required String userId,
    required String eventTitle,
    required DateTime start,
    required DateTime end,
  }) async {
    if (userId == _currentUserId) return;
    final date =
        '${start.day.toString().padLeft(2, '0')}.${start.month.toString().padLeft(2, '0')}.${start.year}';
    final interval = '${_fmtTime(start)}-${_fmtTime(end)}';
    await _messages.send(
      senderId: _currentUserId,
      receiverId: userId,
      title: 'Ai fost adăugat la eveniment',
      content:
          'Ai fost adăugat la evenimentul "$eventTitle" din data $date, interval $interval.',
      recipientScope: 'user',
    );
  }

  /// Send detail messages to selected participants.
  Future<void> sendDetailsToParticipants({
    required String eventTitle,
    required String details,
    required List<String> participantNames,
    required String orgId,
  }) async {
    if (details.trim().isEmpty || participantNames.isEmpty) return;

    final orgUsers = await _profiles.fetchByOrg(orgId);
    final nameToId = <String, String>{};
    for (final u in orgUsers) {
      nameToId[u.displayName] = u.id;
    }

    final inserts = <Map<String, dynamic>>[];
    for (final name in participantNames) {
      final uid = nameToId[name];
      if (uid == null || uid == _currentUserId) continue;
      inserts.add({
        'sender_id': _currentUserId,
        'receiver_id': uid,
        'title': 'Detalii eveniment: $eventTitle',
        'content': 'Detalii eveniment "$eventTitle": $details',
        'read': false,
        'recipient_scope': 'user',
      });
    }
    if (inserts.isNotEmpty) {
      await _messages.sendBatch(inserts);
    }
  }

  /// Notify target org members about a new request.
  Future<void> notifyOrgOfRequest({
    required List<String> targetOrgIds,
    required DateTime requestedStart,
    required DateTime requestedEnd,
  }) async {
    if (targetOrgIds.isEmpty) return;
    final rows = await Supabase.instance.client
        .from('profiles')
        .select('id,organization_id')
        .inFilter('organization_id', targetOrgIds)
        .neq('id', _currentUserId);

    final profiles = List<Map<String, dynamic>>.from(rows);
    if (profiles.isEmpty) return;

    final month = _monthNames[requestedStart.month - 1];
    final body = 'Ai o cerere pentru un eveniment din $month, '
        'ziua ${requestedStart.day}, intervalul '
        '${_fmtTime(requestedStart)}-${_fmtTime(requestedEnd)}.';

    final inserts = profiles
        .map((r) => {
              'sender_id': _currentUserId,
              'receiver_id': r['id'],
              'title': 'Ai o cerere pentru un eveniment',
              'content': body,
              'read': false,
              'recipient_scope': 'organization',
            })
        .toList();

    await _messages.sendBatch(inserts);
  }

  static String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static const _monthNames = [
    'ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie',
    'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie',
  ];
}
