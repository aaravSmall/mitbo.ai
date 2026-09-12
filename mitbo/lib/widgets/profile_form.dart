import 'package:flutter/material.dart';

import '../models/climber_profile.dart';

/// Height/wingspan input form shared by onboarding and profile editing.
///
/// Units are centimeters only for now. Supporting inches as an alternate
/// input unit is a stretch goal — not implemented here to avoid overbuilding
/// unit conversion before it's needed.
class ProfileForm extends StatefulWidget {
  const ProfileForm({
    super.key,
    this.initialProfile,
    required this.onSubmit,
    required this.submitLabel,
  });

  final ClimberProfile? initialProfile;
  final ValueChanged<ClimberProfile> onSubmit;
  final String submitLabel;

  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  final _formKey = GlobalKey<FormState>();
  late final _heightController = TextEditingController(
    text: widget.initialProfile != null
        ? widget.initialProfile!.heightCm.toStringAsFixed(0)
        : '',
  );
  late final _wingspanController = TextEditingController(
    text: widget.initialProfile != null
        ? widget.initialProfile!.wingspanCm.toStringAsFixed(0)
        : '',
  );

  @override
  void dispose() {
    _heightController.dispose();
    _wingspanController.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    final parsed = double.tryParse(value);
    if (parsed == null || parsed <= 0) return 'Enter a valid number';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSubmit(
      ClimberProfile(
        heightCm: double.parse(_heightController.text),
        wingspanCm: double.parse(_wingspanController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _heightController,
            decoration: const InputDecoration(labelText: 'Height (cm)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: _validate,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _wingspanController,
            decoration: const InputDecoration(labelText: 'Wingspan (cm)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: _validate,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
        ],
      ),
    );
  }
}
