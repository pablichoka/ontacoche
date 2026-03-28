import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String _kParkingDiameterMeters = 'parking_diameter_m';
const double _kDefaultParkingDiameterMeters = 100.0; // meters

class SettingsRepository {
  SettingsRepository._(this._prefs);

  final SharedPreferences _prefs;

  double get parkingDiameterMeters =>
      _prefs.getDouble(_kParkingDiameterMeters) ?? _kDefaultParkingDiameterMeters;

  Future<void> setParkingDiameterMeters(double meters) async {
    await _prefs.setDouble(_kParkingDiameterMeters, meters);
  }

  static Future<SettingsRepository> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return SettingsRepository._(prefs);
  }
}

final settingsRepositoryProvider = FutureProvider<SettingsRepository>((ref) async {
  return SettingsRepository.load();
});
