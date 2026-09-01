import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/field_table.dart';

/// Verdict + extracted declarations + human-in-the-loop decision for one scan.
class ResultScreen extends StatefulWidget {
  final int inspectionId;
  final Inspection? initial;
  const ResultScreen({super.key, required this.inspectionId, this.initial});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  Inspection? _insp;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _insp = widget.initial;
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthState>();
      final full = await auth.api.inspection(widget.inspectionId, auth.fieldLabels);
      setState(() {
        _insp = full;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify(String decision) async {
    final auth = context.read<AuthState>();
    String? note;
    if (decision == 'Hold' || decision == 'Rescan') {
      note = await _promptText('Note for "$decision" (optional)');
    }
    if (!mounted) return;
    final updated = await showBusy(context,
        () => auth.api.verify(widget.inspectionId, decision,
            note: note, fieldLabels: auth.fieldLabels),
        message: 'Recording decision…');
    if (updated != null && mounted) {
      setState(() => _insp = updated);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Decision recorded: $decision')));
    }
  }

  Future<void> _override() async {
    final auth = context.read<AuthState>();
    final res = await showDialog<({String verdict, String reason})>(
      context: context,
      builder: (_) => const _OverrideDialog(),
    );
    if (res == null || !mounted) return;
    final updated = await showBusy(context,
        () => auth.api.override(widget.inspectionId, res.verdict, res.reason,
            fieldLabels: auth.fieldLabels),
        message: 'Applying override…');
    if (updated != null && mounted) setState(() => _insp = updated);
  }

  Future<String?> _promptText(String label) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(label),
        content: TextField(controller: c, autofocus: true, maxLines: 3),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Skip')),
          FilledButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _open(String url) async {
    final auth = context.read<AuthState>();
    // token in the query so a plain browser GET is authorized
    final full = Uri.parse(url.contains('?')
        ? '$url&token=${auth.api.tokenForLinks}'
        : '$url?token=${auth.api.tokenForLinks}');
    if (!await launchUrl(full, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open $full')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final insp = _insp;
    return Scaffold(
      appBar: AppBar(
        title: Text('Inspection #${widget.inspectionId}'),
        actions: [
          IconButton(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: insp == null
          ? (_error != null
              ? ErrorNote('$_error', onRetry: _refresh)
              : const Center(child: CircularProgressIndicator()))
          : _body(insp),
    );
  }

  Widget _body(Inspection insp) {
    final r = insp.result;
    final scheme = Theme.of(context).colorScheme;
    final rejected = (insp.verdict ?? '').toUpperCase() == 'REJECTED' ||
        insp.status == 'FAILED';

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- verdict banner ----
          Card(
            color: Verdict.color(insp.shownVerdict).withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(Verdict.icon(insp.shownVerdict),
                    size: 34, color: Verdict.color(insp.shownVerdict)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(insp.shownVerdict,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: Verdict.color(insp.shownVerdict))),
                      if (insp.overrideVerdict != null)
                        Text('manager override of ${insp.verdict}',
                            style: Theme.of(context).textTheme.bodySmall),
                      if (insp.productName?.isNotEmpty == true)
                        Text(insp.productName!,
                            style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
                if (insp.status == 'PROCESSING')
                  const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ]),
            ),
          ),

          if (insp.status == 'FAILED')
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(insp.error ?? 'Processing failed.',
                  style: TextStyle(color: scheme.error)),
            ),

          // ---- quality ----
          if (r != null) ...[
            const SectionHeader('Image quality'),
            Row(children: [
              Expanded(
                  child: StatTile(
                      label: 'Clarity',
                      value: '${r.quality.clarityPct?.round() ?? '—'}%',
                      icon: Icons.center_focus_weak)),
              const SizedBox(width: 10),
              Expanded(
                  child: StatTile(
                      label: 'Exposure',
                      value: r.quality.exposureLabel ?? '—',
                      icon: Icons.wb_sunny_outlined)),
              const SizedBox(width: 10),
              Expanded(
                  child: StatTile(
                      label: 'Size',
                      value: r.quality.width != null
                          ? '${r.quality.width}×${r.quality.height}'
                          : '—',
                      icon: Icons.aspect_ratio)),
            ]),
            if (rejected && r.qualityReasons.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final reason in r.qualityReasons)
                Row(children: [
                  const Icon(Icons.close, size: 16, color: Colors.red),
                  const SizedBox(width: 6),
                  Expanded(child: Text(reason)),
                ]),
            ],
            if (r.qualityOverridden)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Quality gate was manually overridden.',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('OCR source: ${r.ocrSource ?? '—'}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),

            // ---- declarations ----
            if (r.fields.isNotEmpty) ...[
              const SectionHeader('Extracted declarations'),
              FieldTable(r.fields),
            ],

            // ---- violations / notes ----
            if (r.violations.isNotEmpty) ...[
              const SectionHeader('Violations'),
              for (final v in r.violations)
                _bullet(v, Icons.gavel, scheme.error),
            ],
            if (r.reviewNotes.isNotEmpty) ...[
              const SectionHeader('Needs a manual check'),
              for (final n in r.reviewNotes)
                _bullet(n, Icons.visibility_outlined, scheme.tertiary),
            ],
            if (r.fontWarnings.isNotEmpty) ...[
              const SectionHeader('Letter-height flags'),
              for (final w in r.fontWarnings)
                _bullet(w, Icons.text_fields, scheme.tertiary),
            ],

            ExpansionTile(
              title: const Text('Raw OCR text'),
              childrenPadding: const EdgeInsets.all(12),
              children: [
                SelectableText(r.rawText.isEmpty ? '(empty)' : r.rawText,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
            ),
          ],

          // ---- decision ----
          const SectionHeader('Decision'),
          if (insp.humanDecision != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                  'Recorded: ${insp.humanDecision}'
                  '${insp.decisionNote?.isNotEmpty == true ? ' — ${insp.decisionNote}' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: insp.status == 'DONE' ? () => _verify('Approve') : null,
                icon: const Icon(Icons.check),
                label: const Text('Approve')),
            OutlinedButton.icon(
                onPressed: insp.status == 'DONE' ? () => _verify('Hold') : null,
                icon: const Icon(Icons.pan_tool),
                label: const Text('Hold')),
            OutlinedButton.icon(
                onPressed: insp.status == 'DONE' ? () => _verify('Rescan') : null,
                icon: const Icon(Icons.replay),
                label: const Text('Rescan')),
            if (context.read<AuthState>().isManager)
              OutlinedButton.icon(
                  onPressed: () => _override(),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Override verdict')),
          ]),

          const SectionHeader('Export'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: () =>
                    _open(context.read<AuthState>().api.exportUrl(insp.id, 'json')),
                icon: const Icon(Icons.data_object),
                label: const Text('JSON')),
            OutlinedButton.icon(
                onPressed: () =>
                    _open(context.read<AuthState>().api.exportUrl(insp.id, 'csv')),
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('CSV')),
            OutlinedButton.icon(
                onPressed: () =>
                    _open(context.read<AuthState>().api.reportPdfUrl(insp.id)),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('PDF report')),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _bullet(String text, IconData icon, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
      );
}

class _OverrideDialog extends StatefulWidget {
  const _OverrideDialog();
  @override
  State<_OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends State<_OverrideDialog> {
  String _verdict = 'REVIEW';
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Override verdict'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'PASS', label: Text('PASS')),
            ButtonSegment(value: 'REVIEW', label: Text('REVIEW')),
            ButtonSegment(value: 'HOLD', label: Text('HOLD')),
          ],
          selected: {_verdict},
          onSelectionChanged: (s) => setState(() => _verdict = s.first),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _reason,
          maxLines: 3,
          decoration:
              const InputDecoration(labelText: 'Reason (required)', isDense: true),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_reason.text.trim().length < 3) return;
            Navigator.pop(
                context, (verdict: _verdict, reason: _reason.text.trim()));
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
