import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/camera_screen.dart';
import 'screens/edit_profile_screen.dart';
import 'screens/onboarding_screen.dart';
import 'state/profile_controller.dart';

void main() {
  runApp(MitboApp());
}

class MitboApp extends StatefulWidget {
  MitboApp({super.key});

  final ProfileController profileController = ProfileController();

  @override
  State<MitboApp> createState() => _MitboAppState();
}

class _MitboAppState extends State<MitboApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final controller = widget.profileController;
    _router = GoRouter(
      initialLocation: '/splash',
      refreshListenable: controller,
      routes: [
        GoRoute(
          path: '/splash',
          builder: (context, state) => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (context, state) => OnboardingScreen(controller: controller),
        ),
        GoRoute(
          path: '/camera',
          builder: (context, state) => const CameraScreen(),
        ),
        GoRoute(
          path: '/edit-profile',
          builder: (context, state) => EditProfileScreen(controller: controller),
        ),
      ],
      redirect: (context, state) {
        final location = state.matchedLocation;
        if (controller.loading) {
          return location == '/splash' ? null : '/splash';
        }
        final hasProfile = controller.profile != null;
        if (location == '/splash') {
          return hasProfile ? '/camera' : '/onboarding';
        }
        if (!hasProfile && location != '/onboarding') return '/onboarding';
        if (hasProfile && location == '/onboarding') return '/camera';
        return null;
      },
    );
    controller.load();
  }

  @override
  void dispose() {
    widget.profileController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'mitbo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      routerConfig: _router,
    );
  }
}
