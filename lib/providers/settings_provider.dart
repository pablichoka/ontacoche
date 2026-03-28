import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String _kParkingRadiusMeters = 'parking_diameter_m';
const double _kDefaultParkingRadiusMeters = 100.0; // meters

class SettingsRepository {
  SettingsRepository._(this._prefs);

  final SharedPreferences _prefs;

  double get parkingRadiusMeters =>
      _prefs.getDouble(_kParkingRadiusMeters) ?? _kDefaultParkingRadiusMeters;

  Future<void> setParkingDiameterMeters(double meters) async {
    await _prefs.setDouble(_kParkingRadiusMeters, meters);
  }

  static Future<SettingsRepository> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return SettingsRepository._(prefs);
  }
}

final settingsRepositoryProvider = FutureProvider<SettingsRepository>((ref) async {
  return SettingsRepository.load();
});
