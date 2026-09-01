import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme.dart';

/// The extracted-declarations list: one card per required/optional field with
/// its value, a confidence bar, and a PASS/REVIEW/HOLD chip.
class FieldTable extends StatelessWidget {
  final List<FieldResult> fields;
  const FieldTable(this.fields, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final f in fields) _FieldRow(f),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  final FieldResult f;
  const _FieldRow(this.f);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasValue = (f.value ?? '').trim().isNotEmpty;
    final level = f.level ?? (hasValue ? 'PASS' : 'REVIEW');
    final c = Verdict.color(level);
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
                Expanded(
                  child: Text(f.label,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(level,
                      style: TextStyle(
                          color: c,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hasValue ? f.value!.trim() : 'not found on this photo',
              style: TextStyle(
                fontSize: 14,
                fontStyle: hasValue ? FontStyle.normal : FontStyle.italic,
                color: hasValue
                    ? null
                    : scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: f.confidence.clamp(0, 1).toDouble(),
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(c),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('${(f.confidence * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
            if (f.status != null && f.status != 'matched') ...[
              const SizedBox(height: 4),
              Text(f.status!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}
