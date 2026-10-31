import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_tone.dart';
import 'app_version.dart';
import 'controller.dart';
import 'core_settings_card.dart';
import 'dns_settings_card.dart';

enum _Section {
  core('Ядро', Icons.memory_rounded),
  appearance('Оформление', Icons.palette_outlined),
  subscriptions('Подписки', Icons.rss_feed_rounded),
  dns('DNS', Icons.dns_outlined),
  vpn('Управление VPN', Icons.power_settings_new_rounded),
  about('О приложении', Icons.info_outline_rounded);

  const _Section(this.title, this.icon);
  final String title;
  final IconData icon;
}

class SettingsMenu extends StatelessWidget {
  const SettingsMenu({super.key, required this.client});
  final ClientController client;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final section in _Section.values) ...[
              if (section != _Section.values.first)
                const Divider(height: 1, indent: 56, endIndent: 16),
              ListTile(
                leading: Icon(section.icon),
                title: Text(section.title),
                subtitle: Text(switch (section) {
                  _Section.core =>
                    'Tachyon Core · ${client.runtime['coreVersion'] ?? 'Не установлено'}',
                  _Section.appearance =>
                    '${switch (client.themeChoice) {
                      'light' => 'Светлая',
                      'dark' => 'Тёмная',
                      _ => 'Как в системе',
                    }} · ${client.tone.label}',
                  _Section.subscriptions => 'HWID и идентификатор устройства',
                  _Section.dns => client.dns.mode.label,
                  _Section.vpn => 'Кнопка в Центре управления',
                  _Section.about => 'Tachyon Client · $clientVersion',
                }),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        _SettingsPage(client: client, section: section),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.client, required this.section});
  final ClientController client;
  final _Section section;

  Future<void> run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (failure) {
      if (!context.mounted) return;
      final message = failure is FormatException
          ? failure.message.toString()
          : failure is PlatformException && failure.message != null
          ? failure.message!
          : 'Не удалось сохранить настройку. Повторите попытку.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: client,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(section.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: switch (section) {
          _Section.dns => [DnsSettingsCard(client: client)],
          _Section.core => [
            CoreSettingsCard(
              client: client,
              run: (action) => run(context, action),
            ),
          ],
          _Section.appearance => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      key: ValueKey(client.themeChoice),
                      initialValue: client.themeChoice,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Тема',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'system',
                          child: Text('Как в системе'),
                        ),
                        DropdownMenuItem(
                          value: 'light',
                          child: Text('Светлая'),
                        ),
                        DropdownMenuItem(value: 'dark', child: Text('Тёмная')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          run(context, () => client.setTheme(value));
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                    DropdownButtonFormField<AppTone>(
                      key: ValueKey(client.tone),
                      initialValue: client.tone,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Цветовой тон',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final tone in AppTone.values)
                          DropdownMenuItem(
                            value: tone,
                            child: Row(
                              children: [
                                Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: Color(tone.lightSeed),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Flexible(child: Text(tone.label)),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          run(context, () => client.setTone(value));
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
          _Section.subscriptions => [
            Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.phonelink_lock_rounded),
                title: const Text('HWID для подписок'),
                subtitle: const Text(
                  'Передавать провайдеру постоянный идентификатор приложения, версию Android и модель устройства.',
                ),
                value: client.sendHwid,
                onChanged: (value) => run(context, () => client.setHwid(value)),
              ),
            ),
          ],
          _Section.vpn => [
            const Card(
              child: ListTile(
                title: Text('Режим подключения'),
                subtitle: Text('Системный VPN · TUN'),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.power_settings_new_rounded),
                title: const Text('Кнопка VPN в шторке'),
                subtitle: const Text(
                  'Включать и выключать выбранный профиль из Центра управления.',
                ),
                trailing: const Icon(Icons.add_rounded),
                onTap: () => run(context, client.api.requestVpnTile),
              ),
            ),
          ],
          _Section.about => [
            const Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('Tachyon Client'),
                    subtitle: Text('$clientVersion · Экспериментальная сборка'),
                  ),
                  ListTile(
                    leading: Icon(Icons.lock_outline_rounded),
                    title: Text('Данные на устройстве'),
                    subtitle: Text(
                      'Профили и подписки хранятся с шифрованием Android Keystore.',
                    ),
                  ),
                ],
              ),
            ),
          ],
        },
      ),
    ),
  );
}
