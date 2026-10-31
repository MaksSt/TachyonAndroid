import 'package:flutter/material.dart';

import 'controller.dart';
import 'dns_settings.dart';

class DnsSettingsCard extends StatefulWidget {
  const DnsSettingsCard({super.key, required this.client});
  final ClientController client;
  @override
  State<DnsSettingsCard> createState() => _DnsSettingsCardState();
}

class _DnsSettingsCardState extends State<DnsSettingsCard> {
  final form = GlobalKey<FormState>();
  late DnsMode mode;
  late final TextEditingController address;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    mode = widget.client.dns.mode;
    address = TextEditingController(text: widget.client.dns.address);
  }

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  Future<void> save({bool defaults = false}) async {
    if (!defaults && !form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      await widget.client.setDns(
        defaults
            ? const DnsSettings()
            : DnsSettings(mode: mode, address: address.text),
      );
      if (!mounted) return;
      setState(() {
        mode = widget.client.dns.mode;
        address.text = widget.client.dns.address;
      });
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('DNS подключения сохранён')));
    } catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failure is FormatException
                ? failure.message
                : 'Не удалось сохранить DNS. Повторите попытку.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy =
        saving ||
        widget.client.busy ||
        widget.client.testingProfiles.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'DNS подключения',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Определяет IP-адреса VPN-серверов перед подключением. По умолчанию используется DNS текущей сети Android.',
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<DnsMode>(
                key: ValueKey(mode),
                initialValue: mode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Режим DNS',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final value in DnsMode.values)
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            mode = value;
                          });
                        }
                      },
              ),
              if (mode != DnsMode.system) ...[
                const SizedBox(height: 16),
                TextFormField(
                  key: ValueKey('dns-address-${mode.name}'),
                  controller: address,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: widget.client.privacyMode,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: mode == DnsMode.doh
                        ? 'HTTPS-адрес DoH'
                        : 'Адрес DNS-сервера',
                    hintText: switch (mode) {
                      DnsMode.doh => 'https://dns.example/dns-query',
                      DnsMode.dot => 'dns.example:853',
                      _ => '1.1.1.1:53',
                    },
                    border: const OutlineInputBorder(),
                    errorMaxLines: 4,
                  ),
                  validator: (value) {
                    try {
                      DnsSettings(mode: mode, address: value ?? '').validated();
                      return null;
                    } on FormatException catch (failure) {
                      return failure.message;
                    }
                  },
                ),
                if (mode == DnsMode.doh || mode == DnsMode.dot) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Защищённое соединение с проверкой сертификата. Имя самого DNS-сервера определяется через DNS сети Android.',
                  ),
                ],
              ],
              const SizedBox(height: 16),
              const Text(
                'Сохранённый DNS применяется к новым подключениям и проверкам профилей. Для текущего VPN потребуется переподключение.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : () => save(),
                icon: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('Сохранить'),
              ),
              TextButton(
                onPressed: busy ? null : () => save(defaults: true),
                child: const Text('Вернуть системный DNS'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
