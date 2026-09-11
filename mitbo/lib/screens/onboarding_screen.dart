import 'package:flutter/material.dart';

import '../state/profile_controller.dart';
import '../widgets/profile_form.dart';

/// One-time setup screen collecting height/wingspan before first use.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.controller});

  final ProfileController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your profile')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'mitbo uses your height and wingspan to tailor beta to your reach.',
              ),
              const SizedBox(height: 24),
              ProfileForm(
                submitLabel: 'Get started',
                onSubmit: controller.save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
