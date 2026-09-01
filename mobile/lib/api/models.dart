/// Plain data classes mirroring the TRACE backend JSON, 1:1.
library;

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  ApiException(this.message, {this.statusCode});
  @override
  String toString() => 'ApiException(${statusCode ?? '-'}): $message';
}

class User {
  final int id;
  final String email;
  final String role; // worker | manager
  final String? fullName;

  User({required this.id, required this.email, required this.role, this.fullName});

  bool get isManager => role == 'manager';

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        email: j['email'] as String,
        role: j['role'] as String? ?? 'worker',
        fullName: j['full_name'] as String?,
      );
}

class AuthResult {
  final String token;
  final User user;
  AuthResult({required this.token, required this.user});

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token: j['access_token'] as String,
        user: User.fromJson(j['user'] as Map<String, dynamic>),
      );
}

class SessionCounts {
  final int total, pass, review, hold, rejected, processing;
  SessionCounts(this.total, this.pass, this.review, this.hold, this.rejected,
      this.processing);
  factory SessionCounts.fromJson(Map<String, dynamic> j) => SessionCounts(
        (j['total'] ?? 0) as int,
        (j['pass'] ?? 0) as int,
        (j['review'] ?? 0) as int,
        (j['hold'] ?? 0) as int,
        (j['rejected'] ?? 0) as int,
        (j['processing'] ?? 0) as int,
      );
}

class InspectionSession {
  final int id;
  final String name;
  final String? location;
  final String? note;
  final String createdAt;
  final String? closedAt;
  final SessionCounts counts;

  InspectionSession({
    required this.id,
    required this.name,
    this.location,
    this.note,
    required this.createdAt,
    this.closedAt,
    required this.counts,
  });

  bool get isOpen => closedAt == null;

  factory InspectionSession.fromJson(Map<String, dynamic> j) => InspectionSession(
        id: j['id'] as int,
        name: j['name'] as String,
        location: j['location'] as String?,
        note: j['note'] as String?,
        createdAt: j['created_at'] as String? ?? '',
        closedAt: j['closed_at'] as String?,
        counts: SessionCounts.fromJson(
            (j['counts'] as Map<String, dynamic>?) ?? const {}),
      );
}

/// One extracted declaration (manufacturer, MRP, ...).
class FieldResult {
  final String key;
  final String label;
  final String? value;
  final double confidence;
  final String? level; // PASS | REVIEW | HOLD
  final String? status;

  FieldResult({
    required this.key,
    required this.label,
    this.value,
    this.confidence = 0,
    this.level,
    this.status,
  });

  factory FieldResult.fromJson(
          String key, String label, Map<String, dynamic> j) =>
      FieldResult(
        key: key,
        label: label,
        value: j['value'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        level: j['level'] as String?,
        status: j['status'] as String?,
      );
}

class QualityMetrics {
  final num? clarityPct;
  final num? exposurePct;
  final String? exposureLabel;
  final int? width;
  final int? height;

  QualityMetrics(
      {this.clarityPct,
      this.exposurePct,
      this.exposureLabel,
      this.width,
      this.height});

  factory QualityMetrics.fromJson(Map<String, dynamic> j) => QualityMetrics(
        clarityPct: j['clarity_pct'] as num?,
        exposurePct: j['exposure_pct'] as num?,
        exposureLabel: j['exposure_label'] as String?,
        width: j['width'] as int?,
        height: j['height'] as int?,
      );
}

/// The `run_pipeline` result payload.
class PipelineResult {
  final String? verdict; // PASS | REVIEW | HOLD | REJECTED
  final bool qualityPassed;
  final bool qualityOverridden;
  final List<String> qualityReasons;
  final QualityMetrics quality;
  final List<FieldResult> fields;
  final List<String> violations;
  final List<String> reviewNotes;
  final List<String> fontWarnings;
  final String? ocrSource;
  final String rawText;

  PipelineResult({
    this.verdict,
    this.qualityPassed = false,
    this.qualityOverridden = false,
    this.qualityReasons = const [],
    required this.quality,
    this.fields = const [],
    this.violations = const [],
    this.reviewNotes = const [],
    this.fontWarnings = const [],
    this.ocrSource,
    this.rawText = '',
  });

  static List<String> _strList(dynamic v) =>
      (v as List?)?.map((e) => e.toString()).toList() ?? const [];

  factory PipelineResult.fromJson(
      Map<String, dynamic> j, Map<String, String> fieldLabels) {
    final rawFields = (j['fields'] as Map<String, dynamic>?) ?? const {};
    final fields = <FieldResult>[];
    rawFields.forEach((key, value) {
      fields.add(FieldResult.fromJson(
          key, fieldLabels[key] ?? key, (value as Map).cast<String, dynamic>()));
    });
    return PipelineResult(
      verdict: j['verdict'] as String?,
      qualityPassed: j['quality_passed'] as bool? ?? false,
      qualityOverridden: j['quality_overridden'] as bool? ?? false,
      qualityReasons: _strList(j['quality_reasons']),
      quality: QualityMetrics.fromJson(
          (j['quality_metrics'] as Map<String, dynamic>?) ?? const {}),
      fields: fields,
      violations: _strList(j['violations']),
      reviewNotes: _strList(j['review_notes']),
      fontWarnings: _strList(j['font_warnings']),
      ocrSource: j['ocr_source'] as String?,
      rawText: j['raw_text'] as String? ?? '',
    );
  }
}

/// A row from `inspections` -- the full record (detail view) or a lighter
/// version (list view, no `result`).
class Inspection {
  final int id;
  final int? sessionId;
  final String? sessionName;
  final String? productName;
  final String? category;
  final String? captureMode;
  final String status; // PROCESSING | DONE | FAILED
  final String? verdict;
  final String? overrideVerdict;
  final String? effectiveVerdict;
  final String? humanDecision;
  final String? decisionNote;
  final String? overrideReason;
  final String? error;
  final String? createdAt;
  final String? completedAt;
  final String? inspectorEmail;
  final String? inspectorName;
  final String? inspectorRole;
  final List<String> reviewReasons;
  final PipelineResult? result;

  Inspection({
    required this.id,
    this.sessionId,
    this.sessionName,
    this.productName,
    this.category,
    this.captureMode,
    required this.status,
    this.verdict,
    this.overrideVerdict,
    this.effectiveVerdict,
    this.humanDecision,
    this.decisionNote,
    this.overrideReason,
    this.error,
    this.createdAt,
    this.completedAt,
    this.inspectorEmail,
    this.inspectorName,
    this.inspectorRole,
    this.reviewReasons = const [],
    this.result,
  });

  String get shownVerdict =>
      effectiveVerdict ?? overrideVerdict ?? verdict ?? status;

  String get inspectorDisplayName =>
      (inspectorName?.isNotEmpty == true) ? inspectorName! : (inspectorEmail ?? 'Inspector');

  factory Inspection.fromJson(
      Map<String, dynamic> j, Map<String, String> fieldLabels) {
    final rawResult = j['result'];
    final rawReasons = j['review_reasons'];
    return Inspection(
      id: j['id'] as int,
      sessionId: j['session_id'] as int?,
      sessionName: j['session_name'] as String?,
      productName: j['product_name'] as String?,
      category: j['category'] as String? ?? 'Packaged Commodity',
      captureMode: j['capture_mode'] as String?,
      status: j['status'] as String? ?? 'PROCESSING',
      verdict: j['verdict'] as String?,
      overrideVerdict: j['override_verdict'] as String?,
      effectiveVerdict: j['effective_verdict'] as String?,
      humanDecision: j['human_decision'] as String?,
      decisionNote: j['decision_note'] as String?,
      overrideReason: j['override_reason'] as String?,
      error: j['error'] as String?,
      createdAt: j['created_at'] as String?,
      completedAt: j['completed_at'] as String?,
      inspectorEmail: j['inspector_email'] as String?,
      inspectorName: j['inspector_name'] as String?,
      inspectorRole: j['inspector_role'] as String?,
      reviewReasons: (rawReasons is List)
          ? rawReasons.map((e) => e.toString()).toList()
          : const [],
      result: rawResult is Map
          ? PipelineResult.fromJson(
              rawResult.cast<String, dynamic>(), fieldLabels)
          : null,
    );
  }
}

class Paginated<T> {
  final List<T> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;
  Paginated(
      {required this.items,
      required this.total,
      required this.page,
      required this.pageSize,
      required this.pages});
}

class SessionSummary {
  final InspectionSession? session;
  final int totalInspections;
  final int passedCount;
  final int reviewCount;
  final int heldCount;
  final int rejectedCount;
  final int humanApprovals;
  final int rescans;
  final int overrides;
  final double compliancePercentage;
  final int durationSeconds;
  final String durationStr;
  final List<Inspection> inspections;

  SessionSummary({
    this.session,
    required this.totalInspections,
    required this.passedCount,
    required this.reviewCount,
    required this.heldCount,
    required this.rejectedCount,
    required this.humanApprovals,
    required this.rescans,
    required this.overrides,
    required this.compliancePercentage,
    required this.durationSeconds,
    required this.durationStr,
    this.inspections = const [],
  });

  factory SessionSummary.fromJson(
      Map<String, dynamic> j, Map<String, String> fieldLabels) {
    final rawS = j['session'];
    final rawList = j['inspections'] as List? ?? [];
    return SessionSummary(
      session: rawS is Map
          ? InspectionSession.fromJson(rawS.cast<String, dynamic>())
          : null,
      totalInspections: (j['total_inspections'] ?? 0) as int,
      passedCount: (j['passed_count'] ?? 0) as int,
      reviewCount: (j['review_count'] ?? 0) as int,
      heldCount: (j['held_count'] ?? 0) as int,
      rejectedCount: (j['rejected_count'] ?? 0) as int,
      humanApprovals: (j['human_approvals'] ?? 0) as int,
      rescans: (j['rescans'] ?? 0) as int,
      overrides: (j['overrides'] ?? 0) as int,
      compliancePercentage: ((j['compliance_percentage'] ?? 0) as num).toDouble(),
      durationSeconds: (j['duration_seconds'] ?? 0) as int,
      durationStr: j['duration_str'] as String? ?? '0 mins',
      inspections: rawList
          .map((e) =>
              Inspection.fromJson((e as Map).cast<String, dynamic>(), fieldLabels))
          .toList(),
    );
  }
}

class ReviewQueueResponse {
  final List<Inspection> items;
  final int totalPending;

  ReviewQueueResponse({required this.items, required this.totalPending});

  factory ReviewQueueResponse.fromJson(
      Map<String, dynamic> j, Map<String, String> fieldLabels) {
    final list = (j['items'] as List? ?? []);
    return ReviewQueueResponse(
      items: list
          .map((e) =>
              Inspection.fromJson((e as Map).cast<String, dynamic>(), fieldLabels))
          .toList(),
      totalPending: (j['total_pending'] ?? list.length) as int,
    );
  }
}

class DashboardStats {
  final int totalInspections;
  final int completed;
  final Map<String, int> byVerdict;
  final Map<String, int> byCaptureMode;
  final double? passRate;
  final int overridden;
  final int openSessions;
  final List<Map<String, dynamic>> byDay;
  final List<Map<String, dynamic>> recent;

  DashboardStats({
    required this.totalInspections,
    required this.completed,
    required this.byVerdict,
    required this.byCaptureMode,
    required this.passRate,
    required this.overridden,
    required this.openSessions,
    required this.byDay,
    required this.recent,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> j) => DashboardStats(
        totalInspections: (j['total_inspections'] ?? 0) as int,
        completed: (j['completed'] ?? 0) as int,
        byVerdict: ((j['by_verdict'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
        byCaptureMode: ((j['by_capture_mode'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
        passRate: (j['pass_rate'] as num?)?.toDouble(),
        overridden: (j['overridden'] ?? 0) as int,
        openSessions: (j['open_sessions'] ?? 0) as int,
        byDay: ((j['by_day'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList(),
        recent: ((j['recent'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList(),
      );
}

class AuditEntry {
  final int id;
  final String ts;
  final String? userEmail;
  final String? userName;
  final String? userRole;
  final String action;
  final String? entity;
  final int? entityId;
  final String? detail;

  AuditEntry({
    required this.id,
    required this.ts,
    this.userEmail,
    this.userName,
    this.userRole,
    required this.action,
    this.entity,
    this.entityId,
    this.detail,
  });

  String get displayRole {
    if (userRole == 'worker') return 'Health Inspector';
    if (userRole == 'manager') return 'Manager';
    if (userEmail == 'system' || userRole == null) return 'System / AI';
    return userRole!;
  }

  String get displayName {
    if (userName != null && userName!.isNotEmpty) return userName!;
    if (userEmail != null && userEmail!.isNotEmpty) return userEmail!;
    return 'System';
  }

  String get actionTitle {
    switch (action.toLowerCase()) {
      case 'scan.create':
        return 'Product Scanned';
      case 'ai.recommendation':
        return 'AI Analysis Completed & Recommendation Generated';
      case 'decision.approve':
      case 'inspection.verify':
        return 'Human Approval';
      case 'decision.hold':
        return 'Product Placed on Hold';
      case 'decision.rescan':
        return 'Rescan Requested';
      case 'decision.reject':
        return 'Human Rejection';
      case 'manager.override':
        return 'Manager Override';
      case 'manager.approve':
        return 'Manager Approval';
      case 'manager.hold':
        return 'Manager Hold Decision';
      case 'manager.rescan':
        return 'Manager Rescan Request';
      case 'manager.confirm':
        return 'Manager Confirmed Decision';
      case 'report.generate':
        return 'Report Generated (PDF)';
      case 'session.create':
        return 'Inspection Session Created';
      case 'session.close':
        return 'Inspection Session Closed';
      case 'auth.login':
        return 'User Signed In';
      case 'auth.register':
        return 'User Registered';
      default:
        return action;
    }
  }

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'] as int,
        ts: j['ts'] as String? ?? '',
        userEmail: j['user_email'] as String?,
        userName: j['user_name'] as String?,
        userRole: j['user_role'] as String?,
        action: j['action'] as String? ?? '',
        entity: j['entity'] as String?,
        entityId: j['entity_id'] as int?,
        detail: j['detail'] as String?,
      );
}
