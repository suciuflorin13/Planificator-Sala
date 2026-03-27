import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'presentation/pages/login_page.dart';
import 'presentation/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://gtrowdtuzdiepdbewrdc.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd0cm93ZHR1emRpZXBkYmV3cmRjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM5MDU0MTUsImV4cCI6MjA4OTQ4MTQxNX0.cIcrop7orWhTLLJ_9n7OndBUP9dF2V7JJvJZY0QvEx4',
  );

  runApp(const AplicatiaMea());
}

class AplicatiaMea extends StatelessWidget {
  const AplicatiaMea({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Management Sală',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ro', 'RO')],
      locale: const Locale('ro', 'RO'),
      theme: AppTheme.lightTheme(),
      home: const LoginPage(),
    );
  }
}