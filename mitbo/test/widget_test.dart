import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mitbo/main.dart';

// The camera screen checks camera permission on load. There's no platform
// implementation in the test environment, so stub the channel to resolve
// as "denied" (rather than hang) — these tests only check navigation, not
// the permission flow itself, which is covered by manual device testing.
const _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _permissionChannel,
          (call) async => call.method == 'checkPermissionStatus' ? 0 : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, null);
  });

  testWidgets('shows onboarding when no profile is stored', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(MitboApp());
    await tester.pumpAndSettle();

    expect(find.text('Set up your profile'), findsOneWidget);
  });

  testWidgets(
    'completing onboarding saves the profile and shows the camera screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(MitboApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Height (cm)'),
        '180',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Wingspan (cm)'),
        '182',
      );
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      expect(find.text('Set up your profile'), findsNothing);
      expect(find.text('Camera'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('profile_height_cm'), 180.0);
      expect(prefs.getDouble('profile_wingspan_cm'), 182.0);
    },
  );

  testWidgets(
    'skips onboarding and goes straight to the camera screen when a profile exists',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'profile_height_cm': 180.0,
        'profile_wingspan_cm': 182.0,
      });

      await tester.pumpWidget(MitboApp());
      await tester.pumpAndSettle();

      expect(find.text('Set up your profile'), findsNothing);
      expect(find.text('Camera'), findsOneWidget);
    },
  );

  testWidgets(
    'edit profile is reachable from the camera screen and returns to it',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'profile_height_cm': 180.0,
        'profile_wingspan_cm': 182.0,
      });

      await tester.pumpWidget(MitboApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit profile'));
      await tester.pumpAndSettle();

      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Height (cm)'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Height (cm)'),
        '190',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Camera'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('profile_height_cm'), 190.0);
    },
  );

  testWidgets('pose debug readout toggle is off by default and flips', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'profile_height_cm': 180.0,
      'profile_wingspan_cm': 182.0,
    });

    await tester.pumpWidget(MitboApp());
    await tester.pumpAndSettle();

    expect(find.byTooltip('Show pose debug'), findsOneWidget);
    await tester.tap(find.byTooltip('Show pose debug'));
    await tester.pump();
    expect(find.byTooltip('Hide pose debug'), findsOneWidget);
  });
}
