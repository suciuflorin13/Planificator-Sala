import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/repositories.dart';
import '../../domain/models.dart';
import '../theme.dart';

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  final _messageRepo = MessageRepository();
  final _profileRepo = ProfileRepository();
  final _orgRepo = OrganizationRepository();

  UserProfile? _currentUser;
  List<UserProfile> _allProfiles = [];
  List<Organization> _organizations = [];
  List<AppMessage> _inbox = [];
  List<AppMessage> _sent = [];
  bool _isLoading = true;
  StreamSubscription? _realtimeSub;

  String get _userId => Supabase.instance.client.auth.currentUser!.id;
  int get _unreadCount => _inbox.where((m) => !m.read).length;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _setupRealtime();
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    super.dispose();
  }

  void _setupRealtime() {
    _realtimeSub = Supabase.instance.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .listen((_) {
          if (mounted) _loadMessages();
        });
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait([
        _profileRepo.fetchById(_userId),
        _profileRepo.fetchAll(),
        _orgRepo.fetchAll(),
      ]);
      _currentUser = results[0] as UserProfile;
      _allProfiles = results[1] as List<UserProfile>;
      _organizations = results[2] as List<Organization>;
      await _loadMessages();
    } catch (e) {
      debugPrint('MessagesPage._loadAll error: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadMessages() async {
    final inbox = await _messageRepo.fetchInbox(_userId);
    final sent = await _messageRepo.fetchSent(_userId);
    if (mounted) setState(() { _inbox = inbox; _sent = sent; });
  }

  String _displayName(String? uid) {
    if (uid == null) return '-';
    final p = _allProfiles.where((p) => p.id == uid);
    return p.isNotEmpty ? p.first.displayName : uid;
  }



  String _formatTimestamp(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _markRead(String id) async {
    await _messageRepo.markRead(id);
    _loadMessages();
  }

  Future<void> _markAllRead() async {
    await _messageRepo.markAllRead(_userId);
    _loadMessages();
  }

  Future<void> _deleteMessage(String id) async {
    await _messageRepo.delete(id);
    _loadMessages();
  }

  void _showMessageDetails(AppMessage msg, bool isInbox) {
    if (isInbox && !msg.read) _markRead(msg.id);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(msg.title ?? 'Mesaj', style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('De la: ${_displayName(msg.senderId)}', style: const TextStyle(color: AppTheme.textMuted)),
              Text('Către: ${_displayName(msg.receiverId)}', style: const TextStyle(color: AppTheme.textMuted)),
              Text('Data: ${_formatTimestamp(msg.createdAt)}', style: const TextStyle(color: AppTheme.textMuted)),
              const Divider(),
              Text(msg.content),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage(msg.id);
            },
            child: const Text('ȘTERGE', style: TextStyle(color: AppTheme.notification)),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ÎNCHIDE')),
        ],
      ),
    );
  }

  void _openCompose() {
    String? recipientMode = 'user';
    String? selectedUserId;
    String? selectedOrgId;
    String? roleFilter;
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    bool sending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setBS) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Mesaj nou', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: 'Titlu', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  decoration: const InputDecoration(labelText: 'Mesaj', border: OutlineInputBorder()),
                  maxLines: 4,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: recipientMode,
                  decoration: const InputDecoration(labelText: 'Trimite către', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'user', child: Text('Utilizator')),
                    DropdownMenuItem(value: 'org', child: Text('Organizație')),
                  ],
                  onChanged: (v) => setBS(() { recipientMode = v; selectedUserId = null; selectedOrgId = null; }),
                ),
                const SizedBox(height: 12),
                if (recipientMode == 'user')
                  DropdownButtonFormField<String>(
                    initialValue: selectedUserId,
                    decoration: const InputDecoration(labelText: 'Destinatar', border: OutlineInputBorder()),
                    items: _allProfiles
                        .where((p) => p.id != _userId)
                        .map((p) => DropdownMenuItem(value: p.id, child: Text(p.displayName)))
                        .toList(),
                    onChanged: (v) => setBS(() => selectedUserId = v),
                  ),
                if (recipientMode == 'org') ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedOrgId,
                    decoration: const InputDecoration(labelText: 'Organizație', border: OutlineInputBorder()),
                    items: _organizations
                        .map((o) => DropdownMenuItem(value: o.id, child: Text(o.name)))
                        .toList(),
                    onChanged: (v) => setBS(() => selectedOrgId = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: roleFilter,
                    decoration: const InputDecoration(labelText: 'Rol (opțional)', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('Toți')),
                      DropdownMenuItem(value: 'admin', child: Text('Admin')),
                      DropdownMenuItem(value: 'manager', child: Text('Manager')),
                    ],
                    onChanged: (v) => setBS(() => roleFilter = v),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('RENUNȚĂ')),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: sending
                          ? null
                          : () async {
                              if (bodyCtrl.text.trim().isEmpty) return;
                              setBS(() => sending = true);
                              try {
                                if (recipientMode == 'user' && selectedUserId != null) {
                                  await _messageRepo.send(
                                    senderId: _userId,
                                    receiverId: selectedUserId!,
                                    content: bodyCtrl.text.trim(),
                                    title: titleCtrl.text.trim().isEmpty ? null : titleCtrl.text.trim(),
                                  );
                                } else if (recipientMode == 'org' && selectedOrgId != null) {
                                  var targets = _allProfiles
                                      .where((p) => p.organizationId == selectedOrgId && p.id != _userId);
                                  if (roleFilter != null) {
                                    targets = targets.where((p) => p.role.name == roleFilter);
                                  }
                                  final inserts = targets
                                      .map((p) => {
                                            'sender_id': _userId,
                                            'receiver_id': p.id,
                                            'title': titleCtrl.text.trim().isEmpty ? null : titleCtrl.text.trim(),
                                            'content': bodyCtrl.text.trim(),
                                            'read': false,
                                            'recipient_scope': 'organization',
                                            ...?(roleFilter == null ? null : {'recipient_role_filter': roleFilter}),
                                          })
                                      .toList();
                                  await _messageRepo.sendBatch(inserts);
                                }
                                if (!ctx.mounted) return;
                                Navigator.pop(ctx);
                                if (!mounted) return;
                                _loadMessages();
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Eroare: $e')));
                                }
                              } finally {
                                setBS(() => sending = false);
                              }
                            },
                      child: sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('TRIMITE'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(List<AppMessage> messages, bool isInbox) {
    if (messages.isEmpty) {
      return const Center(child: Text('Niciun mesaj', style: TextStyle(color: AppTheme.textMuted)));
    }
    return ListView.separated(
      itemCount: messages.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final msg = messages[i];
        final fromTo = isInbox
            ? 'De la: ${_displayName(msg.senderId)}'
            : 'Către: ${_displayName(msg.receiverId)}';
        final preview = msg.content.length > 80 ? '${msg.content.substring(0, 80)}...' : msg.content;

        return ListTile(
            leading: isInbox && !msg.read
              ? const Icon(Icons.circle, color: AppTheme.newMessage, size: 10)
              : const Icon(Icons.mail_outline, color: AppTheme.textMuted, size: 18),
          title: Text(
            msg.title ?? fromTo,
            style: TextStyle(fontWeight: isInbox && !msg.read ? FontWeight.bold : FontWeight.normal, fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fromTo, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              Text(preview, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
          trailing: Text(_formatTimestamp(msg.createdAt), style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          isThreeLine: true,
          onTap: () => _showMessageDetails(msg, isInbox),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('MESAJE', style: TextStyle(fontWeight: FontWeight.w700)),
          actions: [
            if (_unreadCount > 0)
              IconButton(
                icon: const Icon(Icons.done_all),
                tooltip: 'Marchează toate ca citite',
                onPressed: _markAllRead,
              ),
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Mesaj nou',
              onPressed: _openCompose,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: 'Primite ($_unreadCount)'),
              const Tab(text: 'Trimise'),
            ],
          ),
        ),
        body: Column(
          children: [
            // Stats header
            if (_currentUser != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: AppTheme.surface,
                child: Row(
                  children: [
                    Text(
                      '${_currentUser!.organizationName ?? '-'} • ${_currentUser!.role.name}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    ),
                    const Spacer(),
                    Text(
                      '$_unreadCount necitite',
                      style: TextStyle(
                        fontSize: 12,
                        color: _unreadCount > 0 ? AppTheme.newMessage : AppTheme.textMuted,
                        fontWeight: _unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildMessageList(_inbox, true),
                  _buildMessageList(_sent, false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
