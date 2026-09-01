import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../widgets/common.dart';

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  final List<AuditEntry> _items = [];
  int _page = 1;
  int _total = 0;
  bool _loading = false;
  Object? _error;

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
      final res = await context
          .read<AuthState>()
          .api
          .audit(page: _page, pageSize: 50);
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

  IconData _iconFor(String action) {
    if (action.startsWith('auth')) return Icons.login;
    if (action.startsWith('scan')) return Icons.document_scanner;
    if (action.startsWith('session')) return Icons.inventory_2;
    if (action.contains('override')) return Icons.edit_note;
    if (action.contains('verify')) return Icons.how_to_reg;
    return Icons.circle;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Audit log${_total > 0 ? '  ($_total)' : ''}')),
      body: _error != null && _items.isEmpty
          ? ErrorNote('$_error', onRetry: () => _fetch(reset: true))
          : RefreshIndicator(
              onRefresh: () => _fetch(reset: true),
              child: ListView.separated(
                itemCount: _items.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  if (i == _items.length) {
                    if (_items.length >= _total) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: Text('— end —')),
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
                              : const Text('Load more'),
                        ),
                      ),
                    );
                  }
                  final e = _items[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(_iconFor(e.action), size: 20),
                    title: Text(e.action),
                    subtitle: Text([
                      e.userEmail ?? 'system',
                      if (e.entity != null) '${e.entity}#${e.entityId ?? '?'}',
                      if (e.detail != null && e.detail!.isNotEmpty) e.detail!,
                    ].join('  ·  ')),
                    trailing: Text(
                      e.ts.replaceFirst('T', '\n').split('+').first,
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.right,
                    ),
                  );
                },
              ),
            ),
    );
  }
}
