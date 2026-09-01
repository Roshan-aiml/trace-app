import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/auth.dart';
import 'result_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _picker = ImagePicker();
  final _productName = TextEditingController();

  Uint8List? _bytes;
  String _filename = 'label.jpg';
  String _captureMode = 'live_scan';
  bool _useLlm = true;
  bool _running = false;
  String _progress = '';

  @override
  void dispose() {
    _productName.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final XFile? x = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        imageQuality: 92,
      );
      if (x == null) return;
      final b = await x.readAsBytes();
      setState(() {
        _bytes = b;
        _filename = x.name.isNotEmpty ? x.name : 'label.jpg';
        _captureMode = source == ImageSource.camera ? 'live_scan' : 'upload';
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not get image: $e')));
      }
    }
  }

  Future<void> _run() async {
    final auth = context.read<AuthState>();
    final app = context.read<AppState>();
    if (_bytes == null) return;
    setState(() {
      _running = true;
      _progress = 'Uploading…';
    });
    try {
      final id = await auth.api.createScan(
        bytes: _bytes!,
        filename: _filename,
        sessionId: app.activeSession?.id,
        productName: _productName.text.trim(),
        captureMode: _captureMode,
        useLlm: _useLlm,
      );
      setState(() => _progress = 'Quality gate · OCR · field checks…');
      final insp = await auth.api.awaitScan(
        id,
        auth.fieldLabels,
        onTick: (n) => setState(() => _progress =
            'Analyzing label…  (${(n * 1.5).toStringAsFixed(0)}s)'),
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResultScreen(inspectionId: insp.id, initial: insp),
      ));
      if (mounted) setState(() => _bytes = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Scan failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan a label'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                app.activeSession == null
                    ? 'No session — scans are filed loose'
                    : 'Session: ${app.activeSession!.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: _bytes == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_a_photo_outlined,
                              size: 44,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 8),
                          Text('Capture or choose a label photo',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    )
                  : Image.memory(_bytes!, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _running ? null : () => _pick(ImageSource.camera),
                icon: const Icon(Icons.photo_camera),
                label: const Text('Camera'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _running ? null : () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Gallery'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _productName,
            decoration: const InputDecoration(
                labelText: 'Product name (optional, for the log)'),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _useLlm,
            onChanged: _running ? null : (v) => setState(() => _useLlm = v),
            title: const Text('LLM correction + VLM escalation'),
            subtitle: const Text(
                'Uses the Groq passes when a key is configured server-side'),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'live_scan',
                  icon: Icon(Icons.center_focus_strong),
                  label: Text('Live')),
              ButtonSegment(
                  value: 'upload',
                  icon: Icon(Icons.upload_file),
                  label: Text('Upload')),
            ],
            selected: {_captureMode},
            onSelectionChanged: _running
                ? null
                : (s) => setState(() => _captureMode = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _captureMode == 'upload'
                ? 'Upload mode: a poor photo is rejected outright.'
                : 'Live mode: a poor photo can still be pushed through with a manual override.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (_bytes == null || _running) ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.play_arrow),
            label: Text(_running ? _progress : 'Run inspection'),
          ),
        ],
      ),
    );
  }
}
