import 'package:flutter_test/flutter_test.dart';
import 'package:programator_sala/presentation/helpers/calendar_helpers.dart';

void main() {
  test('buildCalendarSubject stores location metadata', () {
    final encoded = buildCalendarSubject(
      isRequest: false,
      type: 'Workshop',
      title: 'Repetitie',
      organization: 'Magic Puppet',
      location: 'Teatrul National Bucuresti',
    );

    final parsed = parseCalendarSubject(encoded);

    expect(parsed.isRequest, isFalse);
    expect(parsed.type, 'Workshop');
    expect(parsed.title, 'REPETITIE');
    expect(parsed.organization, 'Magic Puppet');
    expect(parsed.location, 'Teatrul National Bucuresti');
  });

  test('parseCalendarSubject remains backward compatible without location', () {
    const oldSubject = 'EVENT|Sedinta|Planificare|Organizatie X';
    final parsed = parseCalendarSubject(oldSubject);

    expect(parsed.isRequest, isFalse);
    expect(parsed.type, 'Sedinta');
    expect(parsed.title, 'PLANIFICARE');
    expect(parsed.organization, 'Organizatie X');
    expect(parsed.location, isEmpty);
  });
}
