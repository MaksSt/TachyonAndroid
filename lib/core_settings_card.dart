import 'package:flutter/material.dart';

import 'controller.dart';

class CoreSettingsCard extends StatelessWidget {
  const CoreSettingsCard({super.key, required this.client, required this.run});
  final ClientController client;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final manager = client.coreManager;
    final update = client.coreUpdate;
    final running = client.runtime['runningCoreVersion'] as String? ?? '';
    final pending =
        running.isNotEmpty &&
        client.runtime['runningCoreId'] != client.runtime['coreSelectionId'];
    final progress = update['progress'] as int? ?? -1;
    final message = update['message'] as String? ?? '';
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.memory_rounded),
            title: const Text('Tachyon Core'),
            subtitle: Text(
              '${client.runtime['coreVersion'] ?? 'Не установлено'} · '
              '${manager['source'] == 'github' ? 'GitHub' : 'Встроенное ядро'}',
            ),
          ),
          if (running.isNotEmpty)
            ListTile(
              title: const Text('Ядро текущего подключения'),
              subtitle: Text(
                '$running${pending ? ' · обновление применится при следующем подключении' : ''}',
              ),
            ),
          if (!client.coreCompatible)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                client.coreInfo['message'] as String? ?? 'Ядро не запускается.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          SwitchListTile(
            title: const Text('Фоновое обновление ядра'),
            subtitle: const Text(
              'Проверять GitHub раз в сутки при наличии сети и достаточном заряде.',
            ),
            value: manager['autoUpdate'] == true,
            onChanged: (value) => run(() => client.setCoreAutoUpdate(value)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: client.updatingCore
                      ? null
                      : () => run(client.updateCore),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    client.updatingCore
                        ? 'Обновление в фоне…'
                        : 'Обновить ядро с GitHub',
                  ),
                ),
                if (client.updatingCore) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: progress < 0 ? null : progress.clamp(0, 100) / 100,
                  ),
                ],
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        '$message${client.updatingCore && progress >= 0 ? ' · $progress%' : ''}',
                        style: TextStyle(
                          color: update['phase'] == 'error'
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                  ),
                if (manager['canRollback'] == true)
                  OutlinedButton.icon(
                    onPressed: client.updatingCore
                        ? null
                        : () => run(client.rollbackCore),
                    icon: const Icon(Icons.undo_rounded),
                    label: Text(
                      manager['previousSource'] == 'bundled'
                          ? 'Вернуться к встроенному ядру'
                          : 'Вернуться к ${manager['previousVersion']}',
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'APK переустанавливать не нужно. Приложение можно свернуть. Текущий VPN-сеанс сохраняется; проверенное ядро применяется при следующем подключении.',
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: client.checkingCore
                      ? null
                      : () => run(client.checkCoreUpdate),
                  icon: const Icon(Icons.manage_search_rounded),
                  label: Text(
                    client.checkingCore
                        ? 'Проверяем GitHub…'
                        : 'Посмотреть последний релиз',
                  ),
                ),
                if (client.coreRelease != null) ...[
                  Text('Последний релиз: ${client.coreRelease!.version}'),
                  if (client.coreRelease!.androidAssets.isEmpty)
                    const Text(
                      'В релизе нет Android-сборок. Установленное ядро сохранится.',
                    ),
                  TextButton.icon(
                    onPressed: () =>
                        run(() => client.api.openUrl(client.coreRelease!.url)),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Релиз на GitHub'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
