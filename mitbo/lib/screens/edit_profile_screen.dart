import 'package:flutter/material.dart';

import '../state/profile_controller.dart';
import '../widgets/profile_form.dart';

/// Lets the climber update their stored height/wingspan after onboarding.
class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key, required this.controller});

  final ProfileController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ProfileForm(
          initialProfile: controller.profile,
          submitLabel: 'Save',
          onSubmit: (profile) {
            controller.save(profile);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }
}
