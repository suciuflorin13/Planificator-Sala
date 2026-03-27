import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/repositories.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../theme.dart';
import 'login_page.dart';
import 'schedule_page.dart';
import 'org_events_page.dart';
import 'messages_page.dart';
import 'users_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _profileRepo = ProfileRepository();
  final _messageRepo = MessageRepository();
  final _requestRepo = RequestRepository();
  final _orgRepo = OrganizationRepository();

  UserProfile? _profile;
  bool _isLoading = true;
  int _unreadMessages = 0;
  int _pendingRequests = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final userId = Supabase.instance.client.auth.currentUser!.id;
      var profile = await _profileRepo.fetchById(userId);

      // Bootstrap for OAuth users without a profile row
      if (profile.organizationId == null || profile.organizationId!.isEmpty) {
        await _bootstrapProfile(userId);
        profile = await _profileRepo.fetchById(userId);
      }

      final unread = await _messageRepo.countUnread(userId);
      int pending = 0;
      if (profile.organizationId != null && profile.role.canRespondToRequests) {
        final openReqs = await _requestRepo.fetchOpenByTargetOrg(profile.organizationId!);
        pending = openReqs.length;
      }

      if (mounted) {
        setState(() {
          _profile = profile;
          _unreadMessages = unread;
          _pendingRequests = pending;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      debugPrint('Eroare la încărcarea profilului: $e');
    }
  }

  Future<void> _bootstrapProfile(String userId) async {
    final user = Supabase.instance.client.auth.currentUser!;
    final meta = user.userMetadata ?? {};
    final orgs = await _orgRepo.fetchAll();

    String? orgId = meta['organization_id']?.toString();
    if (orgId == null || orgId.isEmpty) {
      if (orgs.length == 1) {
        orgId = orgs.first.id;
      } else if (mounted) {
        orgId = await _pickOrganization(orgs);
      }
    }

    await _profileRepo.upsert({
      'id': userId,
      'first_name': (meta['first_name'] ?? '').toString(),
      'last_name': (meta['last_name'] ?? '').toString(),
      'full_name': (meta['full_name'] ?? '').toString(),
      'email': user.email ?? '',
      'organization_id': orgId,
      'role': 'utilizator',
    });
  }

  Future<String?> _pickOrganization(List<Organization> orgs) async {
    String? selected;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Alege organizația'),
          content: DropdownButtonFormField<String>(
            decoration: const InputDecoration(labelText: 'Organizație'),
            items: orgs.map((o) => DropdownMenuItem(value: o.id, child: Text(o.name))).toList(),
            initialValue: selected,
            onChanged: (v) => setDialogState(() => selected = v),
          ),
          actions: [
            TextButton(
              onPressed: selected == null ? null : () => Navigator.pop(ctx, selected),
              child: const Text('Confirmă'),
            ),
          ],
        ),
      ),
    );
  }

  void _navigate(Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => page))
        .then((_) => _loadData());
  }

  Future<void> _logout() async {
    await Supabase.instance.client.auth.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    }
  }

  String _permissionsText(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'Acces complet: gestionare spațiu, utilizatori, cereri, evenimente.';
      case UserRole.manager:
        return 'Gestionare cereri, evenimente organizație, utilizatori.';
      case UserRole.editor:
        return 'Creare și editare evenimente pentru organizație.';
      case UserRole.utilizator:
        return 'Poți crea evenimente în Program Sală și vizualiza evenimente personale.';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final profile = _profile;
    if (profile == null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Eroare la încărcarea profilului.'),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadData, child: const Text('Reîncearcă')),
          ]),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.appBg,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        title: const Text('Panou Control', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          _BadgeIcon(
            icon: Icons.mail_outline,
            count: _unreadMessages,
            badgeColor: AppTheme.newMessage,
            onTap: () => _navigate(const MessagesPage()),
          ),
          if (profile.role.canManageUsers)
            _BadgeIcon(
              icon: Icons.people_outline,
              count: 0,
              badgeColor: AppTheme.newMessage,
              onTap: () => _navigate(const UsersPage()),
            ),
          _BadgeIcon(
            icon: Icons.notifications_none,
            count: _pendingRequests,
            badgeColor: AppTheme.notification,
            onTap: () => _navigate(const SchedulePage()),
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Welcome card
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bun venit, ${profile.firstName.isNotEmpty ? profile.firstName : profile.displayName}!',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    if (profile.organizationName != null)
                      Text('Organizație: ${profile.organizationName}',
                          style: const TextStyle(color: AppTheme.textMuted)),
                    const SizedBox(height: 4),
                    Chip(label: Text(profile.role.name, style: const TextStyle(fontSize: 12))),
                    const SizedBox(height: 8),
                    Text(_permissionsText(profile.role),
                        style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            _ActionTile(
              icon: Icons.calendar_today,
              title: 'Program Sală',
              subtitle: 'Vizualizare și gestionare spațiu comun',
              onTap: () => _navigate(const SchedulePage()),
            ),
            const SizedBox(height: 12),
            _ActionTile(
              icon: Icons.event,
              title: 'Evenimente Organizație',
              subtitle: 'Calendarul organizației tale',
              onTap: () => _navigate(const OrgEventsPage(personalMode: false)),
            ),
            const SizedBox(height: 12),
            _ActionTile(
              icon: Icons.person,
              title: 'Evenimente Personale',
              subtitle: 'Calender personal',
              onTap: () => _navigate(const OrgEventsPage(personalMode: true)),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Small shared widgets
// ──────────────────────────────────────────────

class _BadgeIcon extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color badgeColor;
  final VoidCallback onTap;
  const _BadgeIcon({required this.icon, required this.count, required this.badgeColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        IconButton(icon: Icon(icon), onPressed: onTap),
        if (count > 0)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
              child: Text('$count',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surfaceElevated,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.textPrimary, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
