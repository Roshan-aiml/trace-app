/// Compile-time / runtime configuration.
///
/// The API base URL resolves in this order:
///   1. a value the user typed on the login screen (persisted)
///   2. --dart-define=API_BASE=... passed to `flutter run` / `flutter build`
///   3. the platform default below
///
/// Defaults:
///   * web / desktop  -> http://localhost:8000   (backend on the same machine)
///   * Android emulator needs 10.0.2.2 to reach the host; a physical device
///     needs the host's LAN IP -- set those via the login screen or --dart-define.
library;

import 'package:flutter/foundation.dart';

class AppConfig {
  static const String _definedBase =
      String.fromEnvironment('API_BASE', defaultValue: '');

  static String get defaultApiBase {
    if (_definedBase.isNotEmpty) return _definedBase;
    if (kIsWeb) return 'http://localhost:8000';
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Works for the standard Android emulator. Real devices: use the LAN IP.
      return 'http://10.0.2.2:8000';
    }
    return 'http://localhost:8000';
  }

  static const Duration pollInterval = Duration(milliseconds: 1500);
  static const Duration pollTimeout = Duration(minutes: 4);
}
