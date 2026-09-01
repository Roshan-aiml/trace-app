import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'result_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  final List<Inspection> _items = [];
  int _page = 1;
  int _pages = 1;
  int _total = 0;
  bool _loading = false;
  Object? _error;
  String? _verdict; // filter

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
    return Scaffold(
      appBar: AppBar(title: const Text('Inspection history')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search by product name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          _reload();
                        }),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final v in const [null, 'PASS', 'REVIEW', 'HOLD', 'REJECTED'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(v ?? 'All'),
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
          if (_total > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text('$_total result${_total == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          Expanded(
            child: _error != null && _items.isEmpty
                ? ErrorNote('$_error', onRetry: _reload)
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: _items.isEmpty && !_loading
                        ? ListView(children: const [
                            SizedBox(height: 120),
                            Center(child: Text('No inspections yet')),
                          ])
                        : ListView.builder(
                            controller: _scroll,
                            itemCount: _items.length + 1,
                            itemBuilder: (context, i) {
                              if (i == _items.length) {
                                return Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Center(
                                    child: _loading
                                        ? const CircularProgressIndicator()
                                        : (_page >= _pages
                                            ? const Text('— end —')
                                            : const SizedBox()),
                                  ),
                                );
                              }
                              final it = _items[i];
                              return Card(
                                margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                                child: ListTile(
                                  leading: Icon(Verdict.icon(it.shownVerdict),
                                      color: Verdict.color(it.shownVerdict)),
                                  title: Text(
                                    it.productName?.isNotEmpty == true
                                        ? it.productName!
                                        : 'Inspection #${it.id}',
                                  ),
                                  subtitle: Text(
                                    '${it.captureMode ?? ''} · '
                                    '${(it.createdAt ?? '').replaceFirst('T', ' ').split('+').first}'
                                    '${it.humanDecision != null ? ' · ${it.humanDecision}' : ''}',
                                  ),
                                  trailing: VerdictBadge(it.shownVerdict),
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ResultScreen(inspectionId: it.id),
                                    ),
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
