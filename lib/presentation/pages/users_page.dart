import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/repositories.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../theme.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  final _profileRepo = ProfileRepository();
  List<UserProfile> _users = [];
  UserProfile? _viewer;
  bool _isLoading = true;

  static const _roles = ['admin', 'manager', 'editor', 'utilizator'];

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<void> _fetchUsers() async {
    setState(() => _isLoading = true);
    try {
      final userId = Supabase.instance.client.auth.currentUser!.id;
      _viewer = await _profileRepo.fetchById(userId);

      if (_viewer!.role == UserRole.admin) {
        _users = await _profileRepo.fetchAll();
      } else if (_viewer!.role == UserRole.manager && _viewer!.organizationId != null) {
        _users = await _profileRepo.fetchByOrg(_viewer!.organizationId!);
      } else {
        _users = [];
      }
    } catch (e) {
      debugPrint('UsersPage._fetchUsers error: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  bool _canChangeRole(String targetUserId, String newRole) {
    if (_viewer == null) return false;
    if (_viewer!.role == UserRole.admin) return true;
    if (_viewer!.role == UserRole.manager) {
      if (targetUserId == _viewer!.id) return false;
      if (newRole == 'admin') return false;
      return true;
    }
    return false;
  }

  List<String> _availableRoles() {
    if (_viewer?.role == UserRole.admin) return _roles;
    return _roles.where((r) => r != 'admin').toList();
  }

  Future<void> _updateRole(String userId, String newRole) async {
    if (!_canChangeRole(userId, newRole)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nu ai permisiunea pentru această acțiune.')),
      );
      return;
    }
    try {
      await _profileRepo.updateRole(userId, newRole);
      _fetchUsers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Eroare: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Gestionare Utilizatori')),
      body: ListView.builder(
        itemCount: _users.length,
        itemBuilder: (_, i) {
          final user = _users[i];
          final initials = '${user.firstName.isNotEmpty ? user.firstName[0] : ''}${user.lastName.isNotEmpty ? user.lastName[0] : ''}'.toUpperCase();

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: CircleAvatar(child: Text(initials, style: const TextStyle(fontSize: 14))),
              title: Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.email, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  if (user.organizationName != null)
                    Text(user.organizationName!, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                ],
              ),
              isThreeLine: true,
              trailing: DropdownButton<String>(
                value: user.role.name,
                underline: const SizedBox.shrink(),
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                items: _availableRoles()
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: (v) {
                  if (v != null && v != user.role.name) _updateRole(user.id, v);
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
