import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../services/proxy_service.dart';

class ServerFormScreen extends StatefulWidget {
  final ServerConfig? server;
  const ServerFormScreen({super.key, this.server});
  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _host, _sshPort, _username,
      _password, _socksPort;
  bool _obscurePassword = true;

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
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.server != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Server' : 'Add Server')),
      body: Form(
        key: _formKey,
        child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
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
              const SizedBox(height: 12),
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
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: Icon(isEdit ? Icons.save : Icons.add),
                label: Text(isEdit ? 'Save Changes' : 'Add Server'),
                onPressed: () {
                  if (!_formKey.currentState!.validate()) return;
                  final svc = context.read<ProxyService>();
                  final cfg = ServerConfig(
                    id: widget.server?.id ??
                        DateTime.now().millisecondsSinceEpoch.toString(),
                    name: _name.text,
                    host: _host.text,
                    sshPort: int.tryParse(_sshPort.text) ?? 22,
                    username: _username.text,
                    password: _password.text,
                    socksPort: int.tryParse(_socksPort.text) ?? 1080,
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
