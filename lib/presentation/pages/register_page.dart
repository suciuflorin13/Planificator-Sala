import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/repositories.dart';
import '../../domain/models.dart';
import '../theme.dart';
import '../helpers/status_dialog_helper.dart';
import 'home_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  String? _selectedOrgId;
  List<Organization> _organizations = [];
  bool _isLoading = false;

  final _orgRepo = OrganizationRepository();
  final _profileRepo = ProfileRepository();

  @override
  void initState() {
    super.initState();
    _loadOrganizations();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOrganizations() async {
    try {
      final orgs = await _orgRepo.fetchAll();
      setState(() => _organizations = orgs);
    } catch (e) {
      debugPrint('Eroare la încărcarea organizațiilor: $e');
    }
  }

  Future<void> _register() async {
    final firstName = _firstNameCtrl.text.trim();
    final lastName = _lastNameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text.trim();

    if (firstName.isEmpty || lastName.isEmpty || email.isEmpty || password.isEmpty || _selectedOrgId == null) {
      await StatusDialogHelper.show(
        context,
        title: 'Date incomplete',
        message: 'Te rugăm să completezi toate câmpurile!',
        isError: true,
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final client = Supabase.instance.client;
      final fullName = '$firstName $lastName';

      final response = await client.auth.signUp(
        email: email,
        password: password,
        data: {
          'first_name': firstName,
          'last_name': lastName,
          'full_name': fullName,
          'organization_id': _selectedOrgId,
          'role': 'utilizator',
        },
      );

      final user = response.user ?? client.auth.currentUser;
      if (user == null) {
        throw Exception('Contul a fost creat. Verifică emailul, apoi autentifică-te.');
      }

      await _profileRepo.upsert({
        'id': user.id,
        'first_name': firstName,
        'last_name': lastName,
        'full_name': fullName,
        'email': email,
        'organization_id': _selectedOrgId,
        'role': 'utilizator',
      });

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } catch (e) {
      if (mounted) {
        await StatusDialogHelper.show(
          context,
          title: 'Eroare la înregistrare',
          message: '$e',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.appBg,
      appBar: AppBar(title: const Text('Creează Cont Nou')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const Icon(Icons.person_add, size: 80, color: AppTheme.textMuted),
            const SizedBox(height: 20),
            TextField(
              controller: _firstNameCtrl,
              decoration: const InputDecoration(labelText: 'Prenume', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _lastNameCtrl,
              decoration: const InputDecoration(labelText: 'Nume', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _emailCtrl,
              decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _passwordCtrl,
              decoration: const InputDecoration(labelText: 'Parolă (minim 6 caractere)', border: OutlineInputBorder()),
              obscureText: true,
            ),
            const SizedBox(height: 15),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Alege Organizația', border: OutlineInputBorder()),
              initialValue: _selectedOrgId,
              items: _organizations
                  .map((org) => DropdownMenuItem(value: org.id, child: Text(org.name)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedOrgId = v),
            ),
            const SizedBox(height: 30),
            if (_isLoading)
              const CircularProgressIndicator()
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _register,
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: const Text('Creează Contul'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
