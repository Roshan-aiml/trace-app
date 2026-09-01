/// Typed HTTP client for the TRACE backend. One instance is shared app-wide via
/// [AuthState]; it holds the base URL and the bearer token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config.dart';
import 'models.dart';

class TraceApi {
  String baseUrl;
  String? _token;

  TraceApi({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.defaultApiBase;

  void setToken(String? token) => _token = token;
  void setBaseUrl(String url) => baseUrl = normalise(url);

  /// The bearer token, for building authorized plain-link download URLs
  /// (`?token=...`). Empty string when signed out.
  String get tokenForLinks => _token ?? '';

  static String normalise(String url) {
    var u = url.trim();
    if (u.isEmpty) return AppConfig.defaultApiBase;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, '$v'));
    return Uri.parse('$baseUrl$path').replace(queryParameters: q);
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Never _raise(http.Response r) {
    String msg;
    try {
      final body = jsonDecode(r.body);
      msg = (body is Map && body['detail'] != null)
          ? body['detail'].toString()
          : r.body;
    } catch (_) {
      msg = r.body.isEmpty ? 'HTTP ${r.statusCode}' : r.body;
    }
    throw ApiException(msg, statusCode: r.statusCode);
  }

  Future<dynamic> _get(String path, [Map<String, dynamic>? query]) async {
    final r = await http
        .get(_u(path, query), headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode >= 400) _raise(r);
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<dynamic> _post(String path, Object? body) async {
    final r = await http
        .post(_u(path),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode >= 400) _raise(r);
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  // --------------------------------------------------------------- health
  Future<Map<String, dynamic>> health() async =>
      (await _get('/api/health') as Map).cast<String, dynamic>();

  // ----------------------------------------------------------------- auth
  Future<AuthResult> login(String email, String password) async {
    final j = await _post('/api/auth/login', {
      'email': email,
      'password': password,
    });
    return AuthResult.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<User> register(String email, String password,
      {String role = 'worker', String? fullName}) async {
    await _post('/api/auth/register', {
      'email': email,
      'password': password,
      'role': role,
      if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
    });
    // Backend returns the user but not a token; caller logs in next.
    return login(email, password).then((a) => a.user);
  }

  Future<User> me() async =>
      User.fromJson((await _get('/api/auth/me') as Map).cast<String, dynamic>());

  // ---------------------------------------------------------------- meta
  Future<Map<String, String>> fieldLabels() async {
    final j = await _get('/api/meta/fields') as Map;
    return j.map((k, v) =>
        MapEntry(k.toString(), (v as Map)['label']?.toString() ?? k.toString()));
  }

  // -------------------------------------------------------------- sessions
  Future<List<InspectionSession>> sessions({bool mine = false}) async {
    final j = await _get('/api/sessions', {'mine': mine}) as List;
    return j
        .map((e) => InspectionSession.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<InspectionSession> createSession(String name,
      {String? location, String? note}) async {
    final j = await _post('/api/sessions', {
      'name': name,
      if (location != null && location.isNotEmpty) 'location': location,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return InspectionSession.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<InspectionSession> closeSession(int id) async {
    final j = await _post('/api/sessions/$id/close', null);
    return InspectionSession.fromJson((j as Map).cast<String, dynamic>());
  }

  // ---------------------------------------------------------------- scan
  /// Upload an image; returns the new inspection id (status PROCESSING).
  Future<int> createScan({
    required Uint8List bytes,
    required String filename,
    int? sessionId,
    String? productName,
    String captureMode = 'live_scan',
    bool useLlm = true,
    bool qualityOverride = false,
  }) async {
    final req = http.MultipartRequest('POST', _u('/api/scan'))
      ..headers.addAll(_headers)
      ..fields['capture_mode'] = captureMode
      ..fields['use_llm'] = '$useLlm'
      ..fields['quality_override'] = '$qualityOverride';
    if (sessionId != null) req.fields['session_id'] = '$sessionId';
    if (productName != null && productName.isNotEmpty) {
      req.fields['product_name'] = productName;
    }
    final ext = filename.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    req.files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: filename, contentType: MediaType('image', ext)));

    final streamed = await req.send().timeout(const Duration(seconds: 45));
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode >= 400) _raise(r);
    return (jsonDecode(r.body) as Map)['id'] as int;
  }

  Future<Inspection> getScan(int id, Map<String, String> fieldLabels) async {
    final j = await _get('/api/scan/$id') as Map;
    return Inspection.fromJson(j.cast<String, dynamic>(), fieldLabels);
  }

  /// Poll until the scan leaves PROCESSING (or times out).
  Future<Inspection> awaitScan(int id, Map<String, String> fieldLabels,
      {void Function(int attempt)? onTick}) async {
    final deadline = DateTime.now().add(AppConfig.pollTimeout);
    var attempt = 0;
    while (true) {
      final insp = await getScan(id, fieldLabels);
      if (insp.status != 'PROCESSING') return insp;
      if (DateTime.now().isAfter(deadline)) {
        throw ApiException('Scan timed out after ${AppConfig.pollTimeout.inMinutes} min');
      }
      onTick?.call(++attempt);
      await Future.delayed(AppConfig.pollInterval);
    }
  }

  // ------------------------------------------------------------ inspections
  Future<Paginated<Inspection>> inspections({
    String? q,
    String? verdict,
    String? status,
    int? sessionId,
    bool mine = false,
    int page = 1,
    int pageSize = 20,
    required Map<String, String> fieldLabels,
  }) async {
    final j = await _get('/api/inspections', {
      if (q != null && q.isNotEmpty) 'q': q,
      'verdict': ?verdict,
      'status': ?status,
      'session_id': ?sessionId,
      'mine': mine,
      'page': page,
      'page_size': pageSize,
    }) as Map;
    return Paginated<Inspection>(
      items: (j['items'] as List)
          .map((e) =>
              Inspection.fromJson((e as Map).cast<String, dynamic>(), fieldLabels))
          .toList(),
      total: j['total'] as int,
      page: j['page'] as int,
      pageSize: j['page_size'] as int,
      pages: (j['pages'] ?? 0) as int,
    );
  }

  Future<Inspection> inspection(int id, Map<String, String> fieldLabels) async {
    final j = await _get('/api/inspections/$id') as Map;
    return Inspection.fromJson(j.cast<String, dynamic>(), fieldLabels);
  }

  Future<Inspection> verify(int id, String decision,
      {String? note, required Map<String, String> fieldLabels}) async {
    final j = await _post('/api/inspections/$id/verify', {
      'decision': decision,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return Inspection.fromJson((j as Map).cast<String, dynamic>(), fieldLabels);
  }

  Future<Inspection> override(int id, String verdict, String reason,
      {required Map<String, String> fieldLabels}) async {
    final j = await _post('/api/inspections/$id/override', {
      'verdict': verdict,
      'reason': reason,
    });
    return Inspection.fromJson((j as Map).cast<String, dynamic>(), fieldLabels);
  }

  String exportUrl(int id, String format) =>
      '$baseUrl/api/inspections/$id/export?format=$format';

  String reportPdfUrl(int id) => '$baseUrl/api/inspections/$id/report.pdf';

  String inspectionImageUrl(int id) => '$baseUrl/api/inspections/$id/image';

  /// Bytes for an export file (the browser can't send the auth header on a
  /// plain link, so we fetch + hand off).
  Future<({Uint8List bytes, String contentType})> download(String url) async {
    final r = await http
        .get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 60));
    if (r.statusCode >= 400) _raise(r);
    return (
      bytes: r.bodyBytes,
      contentType: r.headers['content-type'] ?? 'application/octet-stream'
    );
  }

  // --------------------------------------------------------- analytics/audit
  Future<DashboardStats> dashboard() async => DashboardStats.fromJson(
      (await _get('/api/analytics/dashboard') as Map).cast<String, dynamic>());

  Future<Paginated<AuditEntry>> audit({int page = 1, int pageSize = 50}) async {
    final j = await _get('/api/audit', {'page': page, 'page_size': pageSize}) as Map;
    return Paginated<AuditEntry>(
      items: (j['items'] as List)
          .map((e) => AuditEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      total: j['total'] as int,
      page: j['page'] as int,
      pageSize: j['page_size'] as int,
      pages: 0,
    );
  }

  // --------------------------------------------------------- manager reports
  Future<SessionSummary> sessionSummary({int? sessionId, required Map<String, String> fieldLabels}) async {
    final j = await _get('/api/manager/session-summary', {
      'session_id': ?sessionId,
    }) as Map;
    return SessionSummary.fromJson(j.cast<String, dynamic>(), fieldLabels);
  }

  Future<ReviewQueueResponse> reviewQueue({required Map<String, String> fieldLabels}) async {
    final j = await _get('/api/manager/review-queue') as Map;
    return ReviewQueueResponse.fromJson(j.cast<String, dynamic>(), fieldLabels);
  }

  Future<Inspection> reviewAction({
    required int inspectionId,
    required String action,
    String? note,
    required Map<String, String> fieldLabels,
  }) async {
    final req = http.MultipartRequest('POST', _u('/api/manager/review-queue/$inspectionId/action'))
      ..headers.addAll(_headers)
      ..fields['action'] = action;
    if (note != null && note.isNotEmpty) {
      req.fields['note'] = note;
    }
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode >= 400) _raise(r);
    final j = jsonDecode(r.body) as Map;
    return Inspection.fromJson(j.cast<String, dynamic>(), fieldLabels);
  }
}
