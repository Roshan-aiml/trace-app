import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth.dart';
import '../widgets/common.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();
  final _server = TextEditingController();

  bool _register = false;
  String _role = 'worker';
  bool _busy = false;
  bool _showServer = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server.text = context.read<AuthState>().baseUrl;
  }

  @override
  void dispose() {
    for (final c in [_email, _password, _fullName, _server]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthState>();
    try {
      if (_server.text.trim() != auth.baseUrl) {
        await auth.setBaseUrl(_server.text.trim());
      }
      if (_register) {
        await auth.register(_email.text.trim(), _password.text,
            role: _role, fullName: _fullName.text.trim());
      } else {
        await auth.login(_email.text.trim(), _password.text);
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ping() async {
    final auth = context.read<AuthState>();
    await auth.setBaseUrl(_server.text.trim());
    if (!mounted) return;
    await showBusy(context, () async {
      final h = await auth.health();
      final p = (h['pipeline'] as Map?) ?? {};
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Reachable · pipeline '
            '${p['loaded'] == true ? 'ready' : 'NOT loaded'} · '
            'Groq ${h['groq_configured'] == true ? 'on' : 'off'}'),
      ));
    }, message: 'Contacting server…');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(Icons.qr_code_scanner,
                        size: 34, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 10),
                    Text('TRACE',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 4),
                  Text('Legal Metrology label-compliance scanner',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 28),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Sign in')),
                      ButtonSegment(value: true, label: Text('Register')),
                    ],
                    selected: {_register},
                    onSelectionChanged: (s) =>
                        setState(() => _register = s.first),
                  ),
                  const SizedBox(height: 16),
                  if (_register)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextFormField(
                        controller: _fullName,
                        decoration: const InputDecoration(
                            labelText: 'Full name (optional)'),
                      ),
                    ),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Email'),
                    validator: (v) =>
                        (v == null || !v.contains('@')) ? 'Enter an email' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'At least 6 characters'
                        : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_register) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _role,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: const [
                        DropdownMenuItem(
                            value: 'worker',
                            child: Text('Health Inspector — scan & verify')),
                        DropdownMenuItem(
                            value: 'manager',
                            child: Text('Manager — + analytics & audit')),
                      ],
                      onChanged: (v) => setState(() => _role = v ?? 'worker'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () =>
                          setState(() => _showServer = !_showServer),
                      icon: Icon(_showServer
                          ? Icons.expand_less
                          : Icons.expand_more),
                      label: const Text('Server settings'),
                    ),
                  ),
                  if (_showServer) ...[
                    TextFormField(
                      controller: _server,
                      decoration: InputDecoration(
                        labelText: 'API base URL',
                        helperText:
                            'e.g. http://localhost:8000 or http://192.168.x.x:8000',
                        suffixIcon: IconButton(
                            onPressed: _ping,
                            icon: const Icon(Icons.wifi_tethering)),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5))
                        : Text(_register ? 'Create account' : 'Sign in'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Health Inspector: worker@trace.local\nManager: manager@trace.local\nPassword: trace1234',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
