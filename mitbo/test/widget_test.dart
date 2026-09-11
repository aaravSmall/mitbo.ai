import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mitbo/main.dart';

void main() {
  testWidgets('shows onboarding when no profile is stored', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MitboApp());
    await tester.pumpAndSettle();

    expect(find.text('Set up your profile'), findsOneWidget);
  });

  testWidgets('completing onboarding saves the profile and shows the home screen', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MitboApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Height (cm)'), '180');
    await tester.enterText(find.widgetWithText(TextFormField, 'Wingspan (cm)'), '182');
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.text('Set up your profile'), findsNothing);
    expect(find.text('mitbo'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('profile_height_cm'), 180.0);
    expect(prefs.getDouble('profile_wingspan_cm'), 182.0);
  });

  testWidgets('skips onboarding when a profile already exists', (tester) async {
    SharedPreferences.setMockInitialValues({
      'profile_height_cm': 180.0,
      'profile_wingspan_cm': 182.0,
    });

    await tester.pumpWidget(const MitboApp());
    await tester.pumpAndSettle();

    expect(find.text('Set up your profile'), findsNothing);
    expect(find.text('mitbo'), findsOneWidget);
  });
}
