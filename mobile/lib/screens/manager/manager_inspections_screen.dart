import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/auth.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../result_screen.dart';

/// Manager Inspection-Monitoring page.
/// Displays full operational inspection records with product name, category,
/// AI recommendation, human decision, inspector details, and timestamps.
class ManagerInspectionsScreen extends StatefulWidget {
  const ManagerInspectionsScreen({super.key});

  @override
  State<ManagerInspectionsScreen> createState() =>
      _ManagerInspectionsScreenState();
}

class _ManagerInspectionsScreenState extends State<ManagerInspectionsScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  final List<Inspection> _items = [];
  int _page = 1;
  int _pages = 1;
  int _total = 0;
  bool _loading = false;
  Object? _error;
  String? _verdict;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
        _loadMore();
      }
    });
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  Future<void> _reload() async {
    setState(() {
      _page = 1;
      _items.clear();
      _error = null;
    });
    await _fetch();
  }

  Future<void> _loadMore() async {
    if (_loading || _page >= _pages) return;
    setState(() => _page += 1);
    await _fetch();
  }

  Future<void> _fetch() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthState>();
      final res = await auth.api.inspections(
        q: _search.text.trim(),
        verdict: _verdict,
        page: _page,
        pageSize: 20,
        fieldLabels: auth.fieldLabels,
      );
      setState(() {
        _items.addAll(res.items);
        _pages = res.pages == 0 ? 1 : res.pages;
        _total = res.total;
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
        title: const Text('Inspections Monitoring'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
            tooltip: 'Refresh inspections',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search inspections by product name…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          _reload();
                        },
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: [
                for (final v in const [null, 'PASS', 'REVIEW', 'HOLD', 'REJECTED'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(v ?? 'All Verdicts'),
                      selected: _verdict == v,
                      onSelected: (_) {
                        setState(() => _verdict = v);
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Row(
              children: [
                Text(
                  '$_total recorded inspection${_total == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const Spacer(),
                Text(
                  'Tap any item for full report',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _error != null && _items.isEmpty
                ? ErrorNote('$_error', onRetry: _reload)
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: _items.isEmpty && !_loading
                        ? ListView(children: const [
                            SizedBox(height: 120),
                            Center(child: Text('No inspections recorded yet')),
                          ])
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: _items.length + 1,
                            itemBuilder: (context, i) {
                              if (i == _items.length) {
                                return Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Center(
                                    child: _loading
                                        ? const CircularProgressIndicator()
                                        : (_page >= _pages
                                            ? const Text('— end of records —')
                                            : const SizedBox()),
                                  ),
                                );
                              }
                              final it = _items[i];
                              return _InspectionCard(
                                inspection: it,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ResultScreen(inspectionId: it.id),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _InspectionCard extends StatelessWidget {
  final Inspection inspection;
  final VoidCallback onTap;

  const _InspectionCard({
    required this.inspection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final it = inspection;
    final dateStr = (it.createdAt ?? '')
        .replaceFirst('T', ' · ')
        .split('+')
        .first
        .split('.')
        .first;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.productName?.isNotEmpty == true
                              ? it.productName!
                              : 'Inspection #${it.id}',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                it.category ?? 'Packaged Commodity',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'ID: #${it.id}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600),
                            ),
                            if (it.sessionName != null &&
                                it.sessionName!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                '• ${it.sessionName}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  VerdictBadge(it.shownVerdict),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('AI Recommendation',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Verdict.icon(it.verdict),
                                  size: 13,
                                  color: Verdict.color(it.verdict)),
                              const SizedBox(width: 4),
                              Text(
                                it.verdict ?? 'PROCESSING',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Verdict.color(it.verdict)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Container(
                        height: 24,
                        width: 1,
                        color: scheme.outlineVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Human Decision',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          Text(
                            it.humanDecision ??
                                (it.overrideVerdict != null
                                    ? 'Overridden'
                                    : 'Pending Review'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: it.humanDecision != null
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.person_outline,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Inspector: ${it.inspectorDisplayName}',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.schedule,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    dateStr,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
