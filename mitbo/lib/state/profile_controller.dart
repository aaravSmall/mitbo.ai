import 'package:flutter/foundation.dart';

import '../models/climber_profile.dart';
import '../services/profile_service.dart';

/// Holds the app's current profile and whether it has finished loading.
///
/// Kept as a plain [ChangeNotifier] (driven with Flutter's built-in
/// `ListenableBuilder`) rather than pulling in a state management package —
/// revisit once app state grows beyond a single profile object.
class ProfileController extends ChangeNotifier {
  ProfileController({ProfileService? service}) : _service = service ?? ProfileService();

  final ProfileService _service;

  ClimberProfile? _profile;
  ClimberProfile? get profile => _profile;

  bool _loading = true;
  bool get loading => _loading;

  Future<void> load() async {
    _profile = await _service.loadProfile();
    _loading = false;
    notifyListeners();
  }

  Future<void> save(ClimberProfile profile) async {
    await _service.saveProfile(profile);
    _profile = profile;
    notifyListeners();
  }
}
