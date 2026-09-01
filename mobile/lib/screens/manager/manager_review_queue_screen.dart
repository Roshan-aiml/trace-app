import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models.dart';
import '../../state/auth.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/field_table.dart';

/// Manager Review Queue page.
/// Dedicated inspection exception inbox: REVIEW, HOLD, low confidence,
/// missing mandatory declarations, or human overrides requiring manager verification.
class ManagerReviewQueueScreen extends StatefulWidget {
  const ManagerReviewQueueScreen({super.key});

  @override
  State<ManagerReviewQueueScreen> createState() =>
      _ManagerReviewQueueScreenState();
}

class _ManagerReviewQueueScreenState extends State<ManagerReviewQueueScreen> {
  List<Inspection> _items = [];
  int _totalPending = 0;
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
      final res = await auth.api.reviewQueue(fieldLabels: auth.fieldLabels);
      setState(() {
        _items = res.items;
        _totalPending = res.totalPending;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDetail(Inspection item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ReviewQueueDetailSheet(
        inspection: item,
        onActionComplete: () {
          Navigator.of(context).pop();
          _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Review Queue'),
            const SizedBox(width: 8),
            if (_totalPending > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFB3261E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$_totalPending pending',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh review queue',
          ),
        ],
      ),
      body: _error != null && _items.isEmpty
          ? ErrorNote('$_error', onRetry: _load)
          : _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Overview Banner
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.rule_folder_outlined,
                                size: 28, color: scheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Exception & Quality Review Inbox',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Products flagged with low OCR confidence, missing declarations, violations, or inspector overrides.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      if (_items.isEmpty && !_loading)
                        Padding(
                          padding: const EdgeInsets.only(top: 60),
                          child: Center(
                            child: Column(
                              children: [
                                Icon(Icons.verified_outlined,
                                    size: 56, color: const Color(0xFF1E874B)),
                                const SizedBox(height: 12),
                                Text(
                                  'Review Queue is Clear!',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'No pending exceptions or inspection holds requiring manager action.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ),

                      for (final item in _items)
                        _QueueItemCard(
                          inspection: item,
                          onTap: () => _openDetail(item),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _QueueItemCard extends StatelessWidget {
  final Inspection inspection;
  final VoidCallback onTap;

  const _QueueItemCard({
    required this.inspection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final it = inspection;

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
                        const SizedBox(height: 3),
                        Text(
                          'ID #${it.id} • ${it.inspectorDisplayName} • ${(it.createdAt ?? '').replaceFirst('T', ' ').split('+').first}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  VerdictBadge(it.shownVerdict),
                ],
              ),
              const SizedBox(height: 10),

              // Review reason tags
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final r in it.reviewReasons)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _reasonColor(r).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: _reasonColor(r).withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.flag_outlined,
                              size: 11, color: _reasonColor(r)),
                          const SizedBox(width: 4),
                          Text(
                            r,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _reasonColor(r),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'Review & Decide',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 16, color: scheme.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _reasonColor(String reason) {
    final r = reason.toLowerCase();
    if (r.contains('violation') || r.contains('hold')) {
      return const Color(0xFFB3261E);
    }
    if (r.contains('review') || r.contains('manual') || r.contains('uncertain')) {
      return const Color(0xFFB26A00);
    }
    if (r.contains('override')) {
      return const Color(0xFF1F6FEB);
    }
    return const Color(0xFF8E44AD);
  }
}

class _ReviewQueueDetailSheet extends StatefulWidget {
  final Inspection inspection;
  final VoidCallback onActionComplete;

  const _ReviewQueueDetailSheet({
    required this.inspection,
    required this.onActionComplete,
  });

  @override
  State<_ReviewQueueDetailSheet> createState() =>
      _ReviewQueueDetailSheetState();
}

class _ReviewQueueDetailSheetState extends State<_ReviewQueueDetailSheet> {
  Inspection? _full;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _full = widget.inspection;
    _fetchFull();
  }

  Future<void> _fetchFull() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthState>();
      final item = await auth.api.inspection(
        widget.inspection.id,
        auth.fieldLabels,
      );
      setState(() {
        _full = item;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _performAction(String action) async {
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Manager $action Inspection #${widget.inspection.id}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter justification / decision note:'),
            const SizedBox(height: 8),
            TextField(
              controller: noteController,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'e.g. Verified mandatory batch & MRP manually on packaging',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final auth = context.read<AuthState>();
    final res = await showBusy(
      context,
      () => auth.api.reviewAction(
        inspectionId: widget.inspection.id,
        action: action,
        note: noteController.text.trim(),
        fieldLabels: auth.fieldLabels,
      ),
      message: 'Executing manager $action…',
    );

    if (res != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action recorded: $action for #${widget.inspection.id}')),
      );
      widget.onActionComplete();
    }
  }

  Future<void> _openPdf() async {
    final auth = context.read<AuthState>();
    final url = auth.api.reportPdfUrl(widget.inspection.id);
    final uri = Uri.parse(
        '$url${url.contains('?') ? '&' : '?'}token=${auth.api.tokenForLinks}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final it = _full ?? widget.inspection;
    final res = it.result;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (context, scrollCtrl) {
        return Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              height: 4,
              width: 36,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Manager Review: ${it.productName ?? 'Inspection #${it.id}'}',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  VerdictBadge(it.shownVerdict),
                ],
              ),
            ),
            const Divider(height: 1),

            // Sheet Body
            Expanded(
              child: _loading && _full?.result == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Evidence image preview if available
                        Container(
                          height: 180,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.network(
                                context.read<AuthState>().api.inspectionImageUrl(it.id),
                                fit: BoxFit.cover,
                                headers: {
                                  'Authorization': 'Bearer ${context.read<AuthState>().api.tokenForLinks}',
                                },
                                errorBuilder: (context, error, stackTrace) => Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.image_not_supported_outlined,
                                          size: 36,
                                          color: scheme.onSurfaceVariant),
                                      const SizedBox(height: 4),
                                      Text('Product photo preview',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: scheme.onSurfaceVariant)),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${res?.quality.width ?? ''}x${res?.quality.height ?? ''} • Clarity ${res?.quality.clarityPct ?? 0}%',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 11),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Inspection Meta
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text('AI Recommendation: ',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12.5,
                                          color: scheme.onSurfaceVariant)),
                                  Text(it.verdict ?? 'PROCESSING',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 12.5,
                                          color: Verdict.color(it.verdict))),
                                  const Spacer(),
                                  Text('Inspector: ${it.inspectorDisplayName}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: scheme.onSurfaceVariant)),
                                ],
                              ),
                              if (it.humanDecision != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Inspector Decision: ${it.humanDecision} ${it.decisionNote != null ? "— '${it.decisionNote}'" : ""}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Violations section if present
                        if (res?.violations.isNotEmpty == true) ...[
                          const SectionHeader('Detected Violations'),
                          for (final v in res!.violations)
                            Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFB3261E).withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: const Color(0xFFB3261E).withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.error_outline,
                                      size: 16, color: Color(0xFFB3261E)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      v,
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: Color(0xFFB3261E),
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                        ],

                        // Review notes if present
                        if (res?.reviewNotes.isNotEmpty == true) ...[
                          const SectionHeader('Manual Verification Checks'),
                          for (final n in res!.reviewNotes)
                            Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFB26A00).withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: const Color(0xFFB26A00).withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.help_outline,
                                      size: 16, color: Color(0xFFB26A00)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      n,
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: Color(0xFFB26A00),
                                          fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                        ],

                        // Extracted declaration fields table
                        if (res?.fields.isNotEmpty == true) ...[
                          const SectionHeader('Extracted Declarations & Confidence'),
                          FieldTable(res!.fields),
                        ],
                        const SizedBox(height: 24),
                      ],
                    ),
            ),

            // Manager Action Toolbar
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    offset: const Offset(0, -2),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF1E874B),
                            ),
                            onPressed: () => _performAction('Approve'),
                            icon: const Icon(Icons.check_circle_outline, size: 16),
                            label: const Text('Approve'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFB3261E),
                            ),
                            onPressed: () => _performAction('Hold'),
                            icon: const Icon(Icons.pan_tool_outlined, size: 16),
                            label: const Text('Keep on Hold'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _performAction('Rescan'),
                            icon: const Icon(Icons.replay, size: 16),
                            label: const Text('Request Rescan'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _performAction('Confirm'),
                            icon: const Icon(Icons.how_to_reg, size: 16),
                            label: const Text('Confirm/Review'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: _openPdf,
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          tooltip: 'View Full PDF Report',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
