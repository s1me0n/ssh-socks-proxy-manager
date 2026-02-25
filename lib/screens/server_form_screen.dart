import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../services/proxy_service.dart';
import '../utils/id_generator.dart';

class ServerFormScreen extends StatefulWidget {
  final ServerConfig? server;
  const ServerFormScreen({super.key, this.server});
  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _host, _sshPort, _username,
      _password, _socksPort, _privateKey, _keyPassphrase, _keyPath;
  bool _obscurePassword = true;
  bool _obscurePassphrase = true;
  late String _authType;
  late bool _autoReconnect;
  late bool _connectOnStartup;
  late bool _reverseProxy;
  late TextEditingController _reverseProxyPort;

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _name = TextEditingController(text: s?.name ?? '');
    _host = TextEditingController(text: s?.host ?? '');
    _sshPort = TextEditingController(text: '${s?.sshPort ?? 22}');
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: s?.password ?? '');
    _socksPort = TextEditingController(text: '${s?.socksPort ?? 1080}');
    _privateKey = TextEditingController(text: s?.privateKey ?? '');
    _keyPassphrase = TextEditingController(text: s?.keyPassphrase ?? '');
    _keyPath = TextEditingController(text: s?.keyPath ?? '');
    _authType = s?.authType ?? 'password';
    _autoReconnect = s?.autoReconnect ?? true;
    _connectOnStartup = s?.connectOnStartup ?? false;
    _reverseProxy = s?.reverseProxy ?? false;
    _reverseProxyPort = TextEditingController(text: '${s?.reverseProxyPort ?? 1080}');
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _sshPort.dispose();
    _username.dispose();
    _password.dispose();
    _socksPort.dispose();
    _privateKey.dispose();
    _keyPassphrase.dispose();
    _keyPath.dispose();
    _reverseProxyPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.server != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Server' : 'Add Server')),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Name', prefixIcon: Icon(Icons.label)),
              validator: (v) => v!.isEmpty ? 'Required' : null),
          const SizedBox(height: 12),
          TextFormField(
              controller: _host,
              decoration: const InputDecoration(
                  labelText: 'Host / IP',
                  prefixIcon: Icon(Icons.computer)),
              validator: (v) => v!.isEmpty ? 'Required' : null),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: TextFormField(
                    controller: _sshPort,
                    decoration: const InputDecoration(
                        labelText: 'SSH Port',
                        prefixIcon: Icon(Icons.settings_ethernet)),
                    keyboardType: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(
                child: TextFormField(
                    controller: _socksPort,
                    decoration: const InputDecoration(
                        labelText: 'SOCKS Port',
                        prefixIcon: Icon(Icons.router)),
                    keyboardType: TextInputType.number)),
          ]),
          const SizedBox(height: 12),
          TextFormField(
              controller: _username,
              decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixIcon: Icon(Icons.person)),
              validator: (v) => v!.isEmpty ? 'Required' : null),
          const SizedBox(height: 16),

          // ─── Auth type selector ───────────────────────────────
          const Text('Authentication',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'password',
                  label: Text('Password'),
                  icon: Icon(Icons.lock)),
              ButtonSegment(
                  value: 'key',
                  label: Text('SSH Key'),
                  icon: Icon(Icons.vpn_key)),
            ],
            selected: {_authType},
            onSelectionChanged: (v) =>
                setState(() => _authType = v.first),
          ),
          const SizedBox(height: 12),

          // ─── Password field ───────────────────────────────────
          if (_authType == 'password')
            TextFormField(
                controller: _password,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword),
                    ))),

          // ─── Private key fields ───────────────────────────────
          if (_authType == 'key') ...[
            TextFormField(
              controller: _keyPath,
              decoration: const InputDecoration(
                labelText: 'Key File Path (optional)',
                prefixIcon: Icon(Icons.folder_open),
                hintText: '/data/data/com.termux/files/home/.ssh/id_ed25519',
                hintStyle: TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Provide a key file path OR paste the key below. '
                'If both are provided, the pasted key takes priority.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _privateKey,
              maxLines: 8,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'Private Key (PEM)',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.vpn_key),
                hintText:
                    '-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----',
                hintStyle: TextStyle(fontSize: 11),
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (_authType == 'key' &&
                    (v == null || v.isEmpty) &&
                    _keyPath.text.isEmpty) {
                  return 'Private key or key file path is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _keyPassphrase,
              obscureText: _obscurePassphrase,
              decoration: InputDecoration(
                labelText: 'Key Passphrase (optional)',
                prefixIcon: const Icon(Icons.password),
                hintText: 'Leave empty if key is not encrypted',
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassphrase
                      ? Icons.visibility
                      : Icons.visibility_off),
                  onPressed: () => setState(
                      () => _obscurePassphrase = !_obscurePassphrase),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),

          // ─── Connection options ───────────────────────────────
          const Text('Connection Options',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Auto-reconnect'),
            subtitle: const Text(
                'Automatically reconnect if tunnel drops',
                style: TextStyle(fontSize: 12)),
            value: _autoReconnect,
            onChanged: (v) => setState(() => _autoReconnect = v),
          ),
          SwitchListTile(
            title: const Text('Connect on startup'),
            subtitle: const Text(
                'Auto-connect when app starts',
                style: TextStyle(fontSize: 12)),
            value: _connectOnStartup,
            onChanged: (v) => setState(() => _connectOnStartup = v),
          ),
          const Divider(),
          const Text('Reverse Proxy',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Expose SOCKS to server'),
            subtitle: const Text(
                'Forward local SOCKS proxy to the SSH server',
                style: TextStyle(fontSize: 12)),
            value: _reverseProxy,
            onChanged: (v) => setState(() => _reverseProxy = v),
          ),
          if (_reverseProxy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextFormField(
                controller: _reverseProxyPort,
                decoration: const InputDecoration(
                  labelText: 'Remote Port',
                  prefixIcon: Icon(Icons.upload),
                  hintText: '1080',
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          const SizedBox(height: 16),

          FilledButton.icon(
            icon: Icon(isEdit ? Icons.save : Icons.add),
            label: Text(isEdit ? 'Save Changes' : 'Add Server'),
            onPressed: () {
              if (!_formKey.currentState!.validate()) return;
              final svc = context.read<ProxyService>();
              final cfg = ServerConfig(
                id: widget.server?.id ?? generateUniqueId(),
                name: _name.text,
                host: _host.text,
                sshPort: int.tryParse(_sshPort.text) ?? 22,
                username: _username.text,
                password: _authType == 'password' ? _password.text : '',
                socksPort: int.tryParse(_socksPort.text) ?? 1080,
                authType: _authType,
                privateKey:
                    _authType == 'key' && _privateKey.text.isNotEmpty
                        ? _privateKey.text
                        : null,
                keyPassphrase:
                    _authType == 'key' && _keyPassphrase.text.isNotEmpty
                        ? _keyPassphrase.text
                        : null,
                keyPath: _authType == 'key' && _keyPath.text.isNotEmpty
                    ? _keyPath.text
                    : null,
                autoReconnect: _autoReconnect,
                connectOnStartup: _connectOnStartup,
                reverseProxy: _reverseProxy,
                reverseProxyPort: int.tryParse(_reverseProxyPort.text) ?? 1080,
              );
              if (isEdit) {
                svc.updateServer(cfg);
              } else {
                svc.addServer(cfg);
              }
              Navigator.pop(context);
            },
          ),
        ]),
      ),
    );
  }
}
