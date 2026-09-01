import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/auth.dart';
import '../../widgets/common.dart';
import '../result_screen.dart';

/// Manager Audit Trail page.
/// Chronological traceability log for Human-in-the-Loop verification:
/// Scans, AI recommendations, approvals, holds, rescans, overrides, reports.
class ManagerAuditTrailScreen extends StatefulWidget {
  const ManagerAuditTrailScreen({super.key});

  @override
  State<ManagerAuditTrailScreen> createState() =>
      _ManagerAuditTrailScreenState();
}

class _ManagerAuditTrailScreenState extends State<ManagerAuditTrailScreen> {
  final List<AuditEntry> _items = [];
  int _page = 1;
  int _total = 0;
  bool _loading = false;
  Object? _error;
  String? _actionFilter;

  @override
  void initState() {
    super.initState();
    _fetch(reset: true);
  }

  Future<void> _fetch({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _page = 1;
        _items.clear();
      }
    });
    try {
      final res = await context.read<AuthState>().api.audit(
            page: _page,
            pageSize: 50,
          );
      setState(() {
        _items.addAll(res.items);
        _total = res.total;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<AuditEntry> get _filteredItems {
    if (_actionFilter == null || _actionFilter == 'ALL') return _items;
    return _items.where((e) {
      final a = e.action.toLowerCase();
      switch (_actionFilter) {
        case 'DECISIONS':
          return a.contains('decision') ||
              a.contains('verify') ||
              a.contains('approve') ||
              a.contains('hold') ||
              a.contains('rescan');
        case 'AI_SCANS':
          return a.contains('scan') || a.contains('ai') || a.contains('recommendation');
        case 'OVERRIDES':
          return a.contains('override');
        case 'REPORTS':
          return a.contains('report');
        default:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayItems = _filteredItems;

    return Scaffold(
      appBar: AppBar(
        title: Text('Audit Trail${_total > 0 ? ' ($_total records)' : ''}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _fetch(reset: true),
            tooltip: 'Refresh audit log',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Chips
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              children: [
                _filterChip('ALL', 'All Events'),
                _filterChip('DECISIONS', 'Human Decisions'),
                _filterChip('AI_SCANS', 'AI & Scans'),
                _filterChip('OVERRIDES', 'Manager Overrides'),
                _filterChip('REPORTS', 'Reports Exported'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Human-in-the-Loop Traceability Log',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                ),
                const Spacer(),
                Text(
                  'Showing ${displayItems.length} events',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _error != null && _items.isEmpty
                ? ErrorNote('$_error', onRetry: () => _fetch(reset: true))
                : RefreshIndicator(
                    onRefresh: () => _fetch(reset: true),
                    child: displayItems.isEmpty && !_loading
                        ? ListView(children: const [
                            SizedBox(height: 100),
                            Center(child: Text('No audit records match the filter')),
                          ])
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: displayItems.length + 1,
                            itemBuilder: (context, i) {
                              if (i == displayItems.length) {
                                if (_items.length >= _total) {
                                  return const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(
                                        child: Text('— End of Audit Log —')),
                                  );
                                }
                                return Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Center(
                                    child: OutlinedButton(
                                      onPressed: _loading
                                          ? null
                                          : () {
                                              _page += 1;
                                              _fetch();
                                            },
                                      child: _loading
                                          ? const CircularProgressIndicator()
                                          : const Text('Load More Events'),
                                    ),
                                  ),
                                );
                              }
                              final e = displayItems[i];
                              return _AuditCard(entry: e);
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String key, String label) {
    final selected = (_actionFilter == null && key == 'ALL') ||
        _actionFilter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() => _actionFilter = key == 'ALL' ? null : key);
        },
      ),
    );
  }
}

class _AuditCard extends StatelessWidget {
  final AuditEntry entry;

  const _AuditCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = entry;
    final (icon, color) = _styleForAction(e.action);

    // Parse date & exact time
    final parts = e.ts.split('T');
    final dateStr = parts.isNotEmpty ? parts[0] : '';
    final timeStr = parts.length > 1
        ? parts[1].split('+').first.split('.').first
        : '';

    // Parse detail map if JSON
    String? detailSummary;
    if (e.detail != null && e.detail!.isNotEmpty) {
      try {
        final d = jsonDecode(e.detail!);
        if (d is Map) {
          final entries = <String>[];
          d.forEach((k, v) {
            if (v != null && '$v'.isNotEmpty) entries.add('$k: $v');
          });
          detailSummary = entries.join('  •  ');
        } else {
          detailSummary = e.detail;
        }
      } catch (_) {
        detailSummary = e.detail;
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.actionTitle,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              e.displayRole,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              e.displayName,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      dateStr,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant),
                    ),
                    Text(
                      timeStr,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
            if (e.entity != null || detailSummary != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    if (e.entity != null) ...[
                      GestureDetector(
                        onTap: e.entity == 'inspection' && e.entityId != null
                            ? () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ResultScreen(inspectionId: e.entityId!),
                                  ),
                                )
                            : null,
                        child: Text(
                          '${e.entity} #${e.entityId ?? '—'}',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: e.entity == 'inspection'
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                            decoration: e.entity == 'inspection'
                                ? TextDecoration.underline
                                : null,
                          ),
                        ),
                      ),
                      if (detailSummary != null) ...[
                        const SizedBox(width: 8),
                        Text('•',
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurfaceVariant)),
                        const SizedBox(width: 8),
                      ],
                    ],
                    if (detailSummary != null)
                      Expanded(
                        child: Text(
                          detailSummary,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (IconData, Color) _styleForAction(String action) {
    final a = action.toLowerCase();
    if (a.contains('override')) {
      return (Icons.edit_note, const Color(0xFF1F6FEB));
    }
    if (a.contains('approve') || a == 'decision.approve') {
      return (Icons.check_circle_outline, const Color(0xFF1E874B));
    }
    if (a.contains('hold') || a == 'decision.hold') {
      return (Icons.pan_tool_outlined, const Color(0xFFB3261E));
    }
    if (a.contains('rescan') || a == 'decision.rescan') {
      return (Icons.replay_outlined, const Color(0xFFB26A00));
    }
    if (a.contains('reject')) {
      return (Icons.cancel_outlined, const Color(0xFFB3261E));
    }
    if (a.contains('ai') || a.contains('recommendation')) {
      return (Icons.smart_toy_outlined, const Color(0xFF8E44AD));
    }
    if (a.contains('scan')) {
      return (Icons.document_scanner_outlined, const Color(0xFF1F6FEB));
    }
    if (a.contains('report')) {
      return (Icons.picture_as_pdf_outlined, const Color(0xFFE67E22));
    }
    if (a.contains('session')) {
      return (Icons.inventory_2_outlined, const Color(0xFF16A085));
    }
    if (a.contains('auth')) {
      return (Icons.person_outline, const Color(0xFF7F8C8D));
    }
    return (Icons.circle_outlined, const Color(0xFF7F8C8D));
  }
}
