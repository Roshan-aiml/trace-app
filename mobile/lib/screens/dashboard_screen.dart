import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'result_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardStats? _stats;
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
      final s = await context.read<AuthState>().api.dashboard();
      setState(() {
        _stats = s;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance dashboard'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _error != null
          ? ErrorNote('$_error', onRetry: _load)
          : _loading && _stats == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(onRefresh: _load, child: _body(_stats!)),
    );
  }

  Widget _body(DashboardStats s) {
    final total = s.byVerdict.values.fold<int>(0, (a, b) => a + b);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.7,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            StatTile(
                label: 'Total inspections',
                value: '${s.totalInspections}',
                icon: Icons.fact_check_outlined),
            StatTile(
                label: 'Pass rate',
                value: s.passRate == null
                    ? '—'
                    : '${(s.passRate! * 100).round()}%',
                color: Verdict.color('PASS'),
                icon: Icons.verified_outlined),
            StatTile(
                label: 'Manager overrides',
                value: '${s.overridden}',
                icon: Icons.edit_note),
            StatTile(
                label: 'Open sessions',
                value: '${s.openSessions}',
                icon: Icons.folder_open),
          ],
        ),
        const SectionHeader('Verdict mix'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                for (final e in _sortedVerdicts(s.byVerdict))
                  _Bar(
                    label: e.key,
                    value: e.value,
                    fraction: total == 0 ? 0 : e.value / total,
                    color: Verdict.color(e.key),
                  ),
                if (s.byVerdict.isEmpty) const Text('No data yet'),
              ],
            ),
          ),
        ),
        const SectionHeader('Capture mode'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              for (final e in s.byCaptureMode.entries)
                _Bar(
                  label: e.key,
                  value: e.value,
                  fraction: s.totalInspections == 0
                      ? 0
                      : e.value / s.totalInspections,
                  color: Theme.of(context).colorScheme.primary,
                ),
              if (s.byCaptureMode.isEmpty) const Text('No data yet'),
            ]),
          ),
        ),
        const SectionHeader('Recent'),
        for (final r in s.recent)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: Icon(
                  Verdict.icon((r['override_verdict'] ?? r['verdict'] ?? r['status'])
                      ?.toString()),
                  color: Verdict.color(
                      (r['override_verdict'] ?? r['verdict'] ?? r['status'])
                          ?.toString())),
              title: Text(r['product_name']?.toString().isNotEmpty == true
                  ? r['product_name'].toString()
                  : 'Inspection #${r['id']}'),
              subtitle: Text(
                  (r['created_at'] ?? '').toString().replaceFirst('T', ' ').split('+').first),
              trailing: Text(
                  (r['override_verdict'] ?? r['verdict'] ?? r['status'] ?? '')
                      .toString()),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      ResultScreen(inspectionId: r['id'] as int))),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  List<MapEntry<String, int>> _sortedVerdicts(Map<String, int> m) {
    const order = ['PASS', 'REVIEW', 'HOLD', 'REJECTED', 'PENDING'];
    int rank(String k) => order.contains(k) ? order.indexOf(k) : 99;
    final list = m.entries.toList()
      ..sort((a, b) => rank(a.key).compareTo(rank(b.key)));
    return list;
  }
}

class _Bar extends StatelessWidget {
  final String label;
  final int value;
  final double fraction;
  final Color color;
  const _Bar(
      {required this.label,
      required this.value,
      required this.fraction,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
            width: 78,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: fraction.clamp(0, 1),
              minHeight: 14,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        SizedBox(
            width: 34,
            child: Text('  $value',
                style: Theme.of(context).textTheme.bodySmall)),
      ]),
    );
  }
}
