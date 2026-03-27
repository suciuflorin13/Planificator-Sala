// All domain enumerations for the application.

enum UserRole {
  admin,
  manager,
  editor,
  utilizator;

  static UserRole fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'admin':
        return UserRole.admin;
      case 'manager':
        return UserRole.manager;
      case 'editor':
        return UserRole.editor;
      default:
        return UserRole.utilizator;
    }
  }

  bool get canManageOrg =>
      this == UserRole.admin || this == UserRole.manager;
  bool get canCreateOrgEvents =>
      this == UserRole.admin ||
      this == UserRole.manager ||
      this == UserRole.editor;
  bool get canRespondToRequests =>
      this == UserRole.admin || this == UserRole.manager;
  bool get canManageUsers =>
      this == UserRole.admin || this == UserRole.manager;
  bool get canModifySchedule => this == UserRole.admin;
  bool get canMarkOwnOrgFree =>
      this == UserRole.admin || this == UserRole.manager;
}

enum RequestStatus {
  open,
  approved,
  rejected;

  static RequestStatus fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'approved':
        return RequestStatus.approved;
      case 'rejected':
        return RequestStatus.rejected;
      default:
        return RequestStatus.open;
    }
  }
}

enum EventScope {
  organization,
  personal;

  static EventScope fromString(String? value) {
    if (value == 'personal') return EventScope.personal;
    return EventScope.organization;
  }
}

enum ManagedLocation {
  sala,
  foaier;

  static const String salaWithBlockedFoaierLabel = 'Sala (foaier ocupat)';

  static ManagedLocation? fromString(String? value) {
    if (value == null) return null;
    final normalized = value
        .toLowerCase()
        .replaceAll('ă', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ș', 's')
        .replaceAll('ş', 's')
        .replaceAll('ț', 't')
        .replaceAll('ţ', 't')
        .trim();
    if (normalized.contains('sala')) return ManagedLocation.sala;
    if (normalized.contains('foaier')) return ManagedLocation.foaier;
    return null;
  }

  static bool isSalaWithBlockedFoaier(String? value) {
    if (value == null) return false;
    final normalized = value
        .toLowerCase()
        .replaceAll('ă', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ș', 's')
        .replaceAll('ş', 's')
        .replaceAll('ț', 't')
        .replaceAll('ţ', 't')
        .trim();
    return normalized.contains('sala') &&
        normalized.contains('foaier') &&
        normalized.contains('ocupat');
  }

  String get displayName {
    switch (this) {
      case ManagedLocation.sala:
        return 'Sala';
      case ManagedLocation.foaier:
        return 'Foaier';
    }
  }
}

/// Calendar event types as defined in the business requirements.
class EventTypes {
  EventTypes._();

  static const List<String> all = <String>[
    'Activități conexe',
    'Atelier',
    'Casting',
    'Conferință',
    'Expoziție',
    'Montare',
    'Petrecere',
    'Proiect cultural',
    'Repetiție',
    'Spațiu închiriat',
    'Spectacol',
    'Spectacol invitat',
  ];

  /// Types that block the Foaier when in Sala.
  static const Set<String> hallBlockingTypes = {
    'spectacol',
    'expozitie',
    'conferinta',
    'atelier',
  };

  static String normalize(String type) {
    return type
        .toLowerCase()
        .replaceAll('ă', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ș', 's')
        .replaceAll('ş', 's')
        .replaceAll('ț', 't')
        .replaceAll('ţ', 't')
        .trim();
  }

  static bool isHallBlocking(String type) {
    return hallBlockingTypes.contains(normalize(type));
  }

  static bool isProjectCultural(String rawType) {
    return normalize(rawType).startsWith('proiect cultural/');
  }

  static String projectName(String rawType, {String? fallback}) {
    final parts = rawType.split('/');
    if (parts.length >= 2) {
      final name = parts[1].trim();
      if (name.isNotEmpty) return name;
    }
    return (fallback ?? 'Proiect cultural').trim().isEmpty
        ? 'Proiect cultural'
        : fallback!.trim();
  }

  static String displayLabel(String rawType, {String? fallback}) {
    if (isProjectCultural(rawType)) {
      return projectName(rawType, fallback: fallback);
    }
    return rawType.trim().isEmpty ? 'Eveniment' : rawType.trim();
  }

  static String baseLabel(String rawType) {
    if (isProjectCultural(rawType)) return 'Proiect cultural';
    return rawType.trim().isEmpty ? 'Eveniment' : rawType.trim();
  }
}
