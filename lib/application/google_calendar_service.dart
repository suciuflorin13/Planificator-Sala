// Google Calendar sync service – wraps the Supabase Edge Function.
import 'package:supabase_flutter/supabase_flutter.dart';

enum GoogleSyncScope { organization, personal }

class GoogleCalendarService {
  const GoogleCalendarService();

  Future<Map<String, dynamic>> syncNow({
    required GoogleSyncScope scope,
    String? organizationId,
    bool push = true,
    bool pull = true,
    bool deletePropagation = true,
  }) async {
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'sync_google_calendar',
        body: {
          'scope': scope.name,
          ...?(organizationId == null ? null : {'organization_id': organizationId}),
          'push': push,
          'pull': pull,
          'delete_propagation': deletePropagation,
          'compose_google_title': true,
        },
      );

      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      return {'ok': false, 'message': 'Sincronizarea nu a returnat un răspuns valid.'};
    } on FunctionException catch (error) {
      return {'ok': false, 'message': _parseFunctionError(error)};
    } catch (error) {
      return {'ok': false, 'message': 'Eroare client sincronizare: $error'};
    }
  }

  Future<Map<String, dynamic>> syncOrganizationEvents({
    required String organizationId,
  }) {
    return syncNow(
      scope: GoogleSyncScope.organization,
      organizationId: organizationId,
    );
  }

  Future<Map<String, dynamic>> syncPersonalEvents() {
    return syncNow(scope: GoogleSyncScope.personal);
  }

  String _parseFunctionError(FunctionException error) {
    final dynamic details = error.details;
    if (details is Map) {
      final code = (details['code'] ?? '').toString();
      final msg = (details['message'] ?? '').toString();
      if (code == 'WORKER_LIMIT' || msg.toLowerCase().contains('compute resources')) {
        return 'Serverul este suprasolicitat momentan. Încearcă sincronizarea din nou peste câteva momente.';
      }
      if (msg.isNotEmpty) return msg;
      if (code.isNotEmpty) return 'Eroare server: $code';
    } else if (details != null && details.toString().trim().isNotEmpty) {
      return details.toString().trim();
    }
    return 'Eroare funcție: ${error.reasonPhrase ?? 'necunoscută'}';
  }
}
