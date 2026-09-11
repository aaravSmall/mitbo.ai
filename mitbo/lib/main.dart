import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'state/profile_controller.dart';

void main() {
  runApp(const MitboApp());
}

class MitboApp extends StatefulWidget {
  const MitboApp({super.key});

  @override
  State<MitboApp> createState() => _MitboAppState();
}

class _MitboAppState extends State<MitboApp> {
  final _profileController = ProfileController();

  @override
  void initState() {
    super.initState();
    _profileController.load();
  }

  @override
  void dispose() {
    _profileController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mitbo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: ListenableBuilder(
        listenable: _profileController,
        builder: (context, _) {
          if (_profileController.loading) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (_profileController.profile == null) {
            return OnboardingScreen(controller: _profileController);
          }
          return HomeScreen(controller: _profileController);
        },
      ),
    );
  }
}
