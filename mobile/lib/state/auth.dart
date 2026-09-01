/// App-wide auth + shared API client. Persists the token, base URL and a
/// cached copy of the user so the app opens straight to the right screen.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../config.dart';

class AuthState extends ChangeNotifier {
  final TraceApi api = TraceApi();

  User? _user;
  String? _token;
  String _baseUrl = AppConfig.defaultApiBase;
  Map<String, String> _fieldLabels = const {};
  bool _booting = true;

  User? get user => _user;
  bool get isLoggedIn => _token != null && _user != null;
  bool get isManager => _user?.isManager ?? false;
  String get baseUrl => _baseUrl;
  bool get booting => _booting;
  Map<String, String> get fieldLabels => _fieldLabels;

  static const _kToken = 'trace_token';
  static const _kBase = 'trace_base_url';
  static const _kUser = 'trace_user_json';

  Future<void> boot() async {
    final sp = await SharedPreferences.getInstance();
    _baseUrl = sp.getString(_kBase) ?? AppConfig.defaultApiBase;
    api.setBaseUrl(_baseUrl);
    _token = sp.getString(_kToken);
    api.setToken(_token);

    final uj = sp.getString(_kUser);
    if (uj != null) {
      try {
        _user = User.fromJson(jsonDecode(uj) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (_token != null) {
      try {
        _user = await api.me(); // validates the token
        await _loadLabels();
      } catch (_) {
        await _clear(sp);
      }
    }
    _booting = false;
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = TraceApi.normalise(url);
    api.setBaseUrl(_baseUrl);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kBase, _baseUrl);
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    final res = await api.login(email, password);
    await _apply(res.token, res.user);
  }

  Future<void> register(String email, String password,
      {required String role, String? fullName}) async {
    await api.register(email, password, role: role, fullName: fullName);
    final res = await api.login(email, password);
    await _apply(res.token, res.user);
  }

  Future<void> logout() async {
    final sp = await SharedPreferences.getInstance();
    await _clear(sp);
    notifyListeners();
  }

  Future<Map<String, dynamic>> health() => api.health();

  Future<void> _apply(String token, User user) async {
    _token = token;
    _user = user;
    api.setToken(token);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kToken, token);
    await sp.setString(
        _kUser,
        jsonEncode({
          'id': user.id,
          'email': user.email,
          'role': user.role,
          'full_name': user.fullName,
        }));
    await _loadLabels();
    notifyListeners();
  }

  Future<void> _loadLabels() async {
    try {
      _fieldLabels = await api.fieldLabels();
    } catch (_) {
      _fieldLabels = const {};
    }
  }

  Future<void> _clear(SharedPreferences sp) async {
    _token = null;
    _user = null;
    api.setToken(null);
    await sp.remove(_kToken);
    await sp.remove(_kUser);
  }
}
