import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/auth.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<InspectionSession> _sessions = [];
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
      final s = await context.read<AuthState>().api.sessions();
      setState(() {
        _sessions = s;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final created = await showDialog<InspectionSession>(
      context: context,
      builder: (_) => const _NewSessionDialog(),
    );
    if (created != null && mounted) {
      context.read<AppState>().setActiveSession(created);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Inspection sessions')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New session'),
      ),
      body: _error != null
          ? ErrorNote('$_error', onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: _loading && _sessions.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        if (_sessions.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 80),
                            child: Center(
                                child: Text(
                                    'No sessions yet — create one to group a shipment’s scans')),
                          ),
                        for (final s in _sessions)
                          Card(
                            child: ListTile(
                              onTap: () {
                                app.setActiveSession(
                                    app.activeSession?.id == s.id ? null : s);
                              },
                              leading: CircleAvatar(
                                backgroundColor: app.activeSession?.id == s.id
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                foregroundColor: app.activeSession?.id == s.id
                                    ? Colors.white
                                    : null,
                                child: Icon(s.isOpen
                                    ? Icons.folder_open
                                    : Icons.folder_off),
                              ),
                              title: Text(s.name),
                              subtitle: Text([
                                if (s.location?.isNotEmpty == true) s.location!,
                                '${s.counts.total} scans',
                                if (s.counts.hold > 0) '${s.counts.hold} hold',
                                if (s.counts.processing > 0)
                                  '${s.counts.processing} running',
                              ].join(' · ')),
                              trailing: app.activeSession?.id == s.id
                                  ? const Chip(label: Text('active'))
                                  : _MiniCounts(s.counts),
                            ),
                          ),
                      ],
                    ),
            ),
    );
  }
}

class _MiniCounts extends StatelessWidget {
  final SessionCounts c;
  const _MiniCounts(this.c);
  @override
  Widget build(BuildContext context) {
    Widget dot(int n, String v) => n == 0
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(left: 4),
            child: CircleAvatar(
              radius: 11,
              backgroundColor: Verdict.color(v).withValues(alpha: 0.18),
              child: Text('$n',
                  style: TextStyle(fontSize: 11, color: Verdict.color(v))),
            ),
          );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      dot(c.pass, 'PASS'),
      dot(c.review, 'REVIEW'),
      dot(c.hold, 'HOLD'),
    ]);
  }
}

class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog();
  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  final _name = TextEditingController();
  final _location = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New inspection session'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Name (e.g. "Warehouse A – 30 Aug")')),
          const SizedBox(height: 8),
          TextField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'Location (optional)')),
          const SizedBox(height: 8),
          TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)')),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  if (_name.text.trim().isEmpty) return;
                  setState(() => _busy = true);
                  try {
                    final s = await context.read<AuthState>().api.createSession(
                          _name.text.trim(),
                          location: _location.text.trim(),
                          note: _note.text.trim(),
                        );
                    if (context.mounted) Navigator.pop(context, s);
                  } catch (e) {
                    setState(() => _busy = false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$e')));
                    }
                  }
                },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
