import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/auth.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../result_screen.dart';

/// Manager Session Summary page.
/// Displays high-level aggregate metrics for an inspection batch/session:
/// total products, pass/review/hold mix, approvals, rescans, overrides,
/// inspection duration, and compliance percentage with visual stats cards.
class ManagerSessionSummaryScreen extends StatefulWidget {
  const ManagerSessionSummaryScreen({super.key});

  @override
  State<ManagerSessionSummaryScreen> createState() =>
      _ManagerSessionSummaryScreenState();
}

class _ManagerSessionSummaryScreenState
    extends State<ManagerSessionSummaryScreen> {
  List<InspectionSession> _sessions = [];
  int? _selectedSessionId;
  SessionSummary? _summary;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthState>();
      final sessions = await auth.api.sessions();
      final summary = await auth.api.sessionSummary(
        sessionId: _selectedSessionId,
        fieldLabels: auth.fieldLabels,
      );
      setState(() {
        _sessions = sessions;
        _summary = summary;
        if (_selectedSessionId == null && summary.session != null) {
          _selectedSessionId = summary.session!.id;
        }
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectSession(int? sid) async {
    setState(() {
      _selectedSessionId = sid;
      _loading = true;
    });
    try {
      final auth = context.read<AuthState>();
      final summary = await auth.api.sessionSummary(
        sessionId: sid,
        fieldLabels: auth.fieldLabels,
      );
      setState(() {
        _summary = summary;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Summary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh session statistics',
          ),
        ],
      ),
      body: _error != null && _summary == null
          ? ErrorNote('$_error', onRetry: _load)
          : _loading && _summary == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Session selector dropdown
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Select Inspection Session',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<int?>(
                                initialValue: _selectedSessionId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                hint: const Text('All / Latest active session'),
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text('Latest Active Session'),
                                  ),
                                  for (final s in _sessions)
                                    DropdownMenuItem<int?>(
                                      value: s.id,
                                      child: Text(
                                        '${s.name} ${s.location != null ? '(${s.location})' : ''} • ${s.counts.total} scans',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (v) => _selectSession(v),
                              ),
                              if (_summary?.session != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(
                                      _summary!.session!.isOpen
                                          ? Icons.lock_open
                                          : Icons.lock_outline,
                                      size: 14,
                                      color: _summary!.session!.isOpen
                                          ? const Color(0xFF1E874B)
                                          : scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _summary!.session!.isOpen
                                          ? 'Open Session'
                                          : 'Closed Session',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: _summary!.session!.isOpen
                                          ? const Color(0xFF1E874B)
                                          : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const Spacer(),
                                    Icon(Icons.timer_outlined,
                                        size: 14,
                                        color: scheme.onSurfaceVariant),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Duration: ${_summary!.durationStr}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // High level compliance banner
                      _ComplianceBanner(summary: _summary!),
                      const SizedBox(height: 16),

                      const SectionHeader('Inspection Breakdown'),
                      // 2x2 Primary Stats Grid
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        childAspectRatio: 1.6,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        children: [
                          StatTile(
                            label: 'Total Inspected',
                            value: '${_summary!.totalInspections}',
                            icon: Icons.inventory_2_outlined,
                          ),
                          StatTile(
                            label: 'Passed Products',
                            value: '${_summary!.passedCount}',
                            color: Verdict.color('PASS'),
                            icon: Icons.check_circle_outline,
                          ),
                          StatTile(
                            label: 'Under Review',
                            value: '${_summary!.reviewCount}',
                            color: Verdict.color('REVIEW'),
                            icon: Icons.help_outline,
                          ),
                          StatTile(
                            label: 'Held / Violations',
                            value: '${_summary!.heldCount}',
                            color: Verdict.color('HOLD'),
                            icon: Icons.pan_tool_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      const SectionHeader('Human-in-the-Loop Actions'),
                      // 3-column Human Decision cards
                      Row(
                        children: [
                          Expanded(
                            child: StatTile(
                              label: 'Approvals',
                              value: '${_summary!.humanApprovals}',
                              color: const Color(0xFF1E874B),
                              icon: Icons.thumb_up_outlined,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: StatTile(
                              label: 'Rescans',
                              value: '${_summary!.rescans}',
                              color: const Color(0xFFB26A00),
                              icon: Icons.replay_outlined,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: StatTile(
                              label: 'Overrides',
                              value: '${_summary!.overrides}',
                              color: scheme.primary,
                              icon: Icons.edit_note,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Visual Progress Bar Breakdown
                      const SectionHeader('Session Verdict Distribution'),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _DistributionBar(
                                label: 'PASS',
                                count: _summary!.passedCount,
                                total: _summary!.totalInspections,
                                color: Verdict.color('PASS'),
                              ),
                              const SizedBox(height: 10),
                              _DistributionBar(
                                label: 'REVIEW',
                                count: _summary!.reviewCount,
                                total: _summary!.totalInspections,
                                color: Verdict.color('REVIEW'),
                              ),
                              const SizedBox(height: 10),
                              _DistributionBar(
                                label: 'HOLD',
                                count: _summary!.heldCount,
                                total: _summary!.totalInspections,
                                color: Verdict.color('HOLD'),
                              ),
                              if (_summary!.rejectedCount > 0) ...[
                                const SizedBox(height: 10),
                                _DistributionBar(
                                  label: 'REJECTED',
                                  count: _summary!.rejectedCount,
                                  total: _summary!.totalInspections,
                                  color: Verdict.color('REJECTED'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Inspected products list in this session
                      if (_summary!.inspections.isNotEmpty) ...[
                        SectionHeader(
                            'Session Products (${_summary!.inspections.length})'),
                        for (final it in _summary!.inspections)
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(
                                Verdict.icon(it.shownVerdict),
                                color: Verdict.color(it.shownVerdict),
                              ),
                              title: Text(
                                it.productName?.isNotEmpty == true
                                    ? it.productName!
                                    : 'Inspection #${it.id}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                '${it.inspectorDisplayName} • ${(it.createdAt ?? '').replaceFirst('T', ' ').split('+').first}',
                              ),
                              trailing: VerdictBadge(it.shownVerdict),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ResultScreen(inspectionId: it.id),
                                ),
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }
}

class _ComplianceBanner extends StatelessWidget {
  final SessionSummary summary;

  const _ComplianceBanner({required this.summary});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = summary.compliancePercentage;
    final isGood = pct >= 80.0;
    final isMid = pct >= 50.0 && pct < 80.0;
    final color = isGood
        ? const Color(0xFF1E874B)
        : (isMid ? const Color(0xFFB26A00) : const Color(0xFFB3261E));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${pct.toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Overall Compliance Rate',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${summary.passedCount} out of ${summary.totalInspections} commodities passed Legal Metrology checks in this session.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DistributionBar extends StatelessWidget {
  final String label;
  final int count;
  final int total;
  final Color color;

  const _DistributionBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? count / total : 0.0;

    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 12,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 48,
          child: Text(
            '$count (${(fraction * 100).round()}%)',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
