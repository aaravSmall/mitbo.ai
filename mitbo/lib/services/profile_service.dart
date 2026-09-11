import 'package:shared_preferences/shared_preferences.dart';

import '../models/climber_profile.dart';

/// Persists the climber's profile locally via [SharedPreferences].
///
/// Measurements are stored in centimeters only for now — supporting inches
/// as an input unit is a stretch goal, not implemented here.
class ProfileService {
  static const _heightKey = 'profile_height_cm';
  static const _wingspanKey = 'profile_wingspan_cm';

  Future<bool> hasProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_heightKey) && prefs.containsKey(_wingspanKey);
  }

  Future<ClimberProfile?> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final heightCm = prefs.getDouble(_heightKey);
    final wingspanCm = prefs.getDouble(_wingspanKey);
    if (heightCm == null || wingspanCm == null) return null;
    return ClimberProfile(heightCm: heightCm, wingspanCm: wingspanCm);
  }

  Future<void> saveProfile(ClimberProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_heightKey, profile.heightCm);
    await prefs.setDouble(_wingspanKey, profile.wingspanCm);
  }
}
