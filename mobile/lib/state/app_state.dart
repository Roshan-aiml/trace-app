/// Small cross-screen state: which inspection session new scans are filed under.
library;

import 'package:flutter/foundation.dart';

import '../api/models.dart';

class AppState extends ChangeNotifier {
  InspectionSession? _activeSession;
  InspectionSession? get activeSession => _activeSession;

  void setActiveSession(InspectionSession? s) {
    _activeSession = s;
    notifyListeners();
  }

  void clear() {
    _activeSession = null;
    notifyListeners();
  }
}
