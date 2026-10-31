import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'controller.dart';
import 'profiles.dart';
import 'subscription_metadata.dart';
import 'subscription_card.dart';
import 'settings_screen.dart';
import 'private_text.dart';
import 'qr_import_screen.dart';

void main() => runApp(const TachyonApp());

class TachyonApp extends StatefulWidget {
  const TachyonApp({super.key, this.api, this.scanQr});
  final NativeApi? api;
  final Future<String?> Function(BuildContext)? scanQr;
  @override
  State<TachyonApp> createState() => _TachyonAppState();
}

class _TachyonAppState extends State<TachyonApp> {
  late final ClientController client;
  @override
  void initState() {
    super.initState();
    client = ClientController(widget.api ?? NativeApi())..initialize();
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: client,
    builder: (context, _) => MaterialApp(
      title: 'Tachyon Client',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: switch (client.themeChoice) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(client.tone.lightSeed),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(client.tone.darkSeed),
          brightness: Brightness.dark,
        ),
      ),
      home: ClientScreen(client: client, scanQr: widget.scanQr),
    ),
  );
}

class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key, required this.client, this.scanQr});
  final ClientController client;
  final Future<String?> Function(BuildContext)? scanQr;
  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  ClientController get client => widget.client;
  int tab = 0;
  String filter = '';
  String groupFilter = 'all';
  final searchInput = TextEditingController();
  @override
  void dispose() {
    searchInput.dispose();
    super.dispose();
  }

  Future<void> guarded(Future<void> Function() action) async {
    try {
      await action();
    } catch (failure) {
      if (!mounted) return;
      final message = failure is FormatException
          ? failure.message.toString()
          : failure is PlatformException && failure.message != null
          ? failure.message!
          : 'Не удалось выполнить действие. Проверьте подключение и повторите.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> import() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.content_paste_rounded),
                title: const Text('Из буфера обмена'),
                onTap: () => Navigator.pop(sheetContext, 'clipboard'),
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_scanner_rounded),
                title: const Text('Сканировать QR-код'),
                onTap: () => Navigator.pop(sheetContext, 'qr'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('Отмена'),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    await guarded(() async {
      final value = source == 'clipboard'
          ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
          : await (widget.scanQr?.call(context) ??
                Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        QrImportScreen(privateMode: client.privacyMode),
                  ),
                ));
      if (value == null && source == 'qr') return;
      await client.importValue(value ?? '');
    });
  }

  Future<void> pingAll() async {
    await client.pingAll();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: client,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(['Tachyon', 'Профили', 'Журнал', 'Настройки'][tab]),
        actions: [
          if (tab == 2)
            IconButton(
              tooltip: 'Скопировать журнал',
              onPressed: client.logs.isEmpty ? null : () => guarded(copyLogs),
              icon: const Icon(Icons.copy_all_rounded),
            ),
          IconButton(
            tooltip: client.pingingAll
                ? 'URLTest ${client.pingCompleted}/${client.pingTotal}'
                : 'Задержка через Tachyon для всех профилей',
            onPressed: client.profiles.isEmpty || client.pingingAll
                ? null
                : () => guarded(pingAll),
            icon: client.pingingAll
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_ping_rounded),
          ),
          IconButton(
            tooltip: client.privacyMode
                ? 'Показать личные данные'
                : 'Скрыть личные данные',
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              searchInput.clear();
              setState(() {
                filter = '';
              });
              guarded(() => client.setPrivacy(!client.privacyMode));
            },
            icon: Icon(
              client.privacyMode
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
            ),
          ),
        ],
      ),
      body: client.loading
          ? const Center(child: CircularProgressIndicator())
          : switch (tab) {
              0 => home(),
              1 => profiles(),
              2 => logs(),
              _ => settings(),
            },
      floatingActionButton: tab == 1
          ? FloatingActionButton(
              tooltip: 'Добавить',
              onPressed: client.loading || client.addingSubscription
                  ? null
                  : () => import(),
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns_rounded),
            label: 'Профили',
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            selectedIcon: Icon(Icons.article_rounded),
            label: 'Журнал',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Настройки',
          ),
        ],
      ),
    ),
  );

  Future<void> copyLogs() async {
    await Clipboard.setData(
      ClipboardData(
        text: client.privacyMode
            ? 'Личные данные журнала скрыты'
            : client.logs.join('\n'),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Журнал скопирован')));
  }

  Widget home() {
    final running = client.state == 'running';
    final connecting = client.state == 'connecting';
    final colors = Theme.of(context).colorScheme;
    final status = running
        ? 'Подключено'
        : connecting
        ? 'Подключение…'
        : client.state == 'error'
        ? 'Ошибка подключения'
        : 'Отключено';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 28),
            Center(
              child: SizedBox(
                width: 160,
                height: 160,
                child: Tooltip(
                  message: client.selected == null
                      ? 'Добавьте профиль'
                      : running || connecting
                      ? 'Отключить VPN'
                      : 'Подключить VPN',
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      backgroundColor: running
                          ? colors.primaryContainer
                          : colors.surfaceContainerHighest,
                    ),
                    onPressed:
                        client.selected == null ||
                            client.busy ||
                            (!client.coreCompatible && !running && !connecting)
                        ? null
                        : () => guarded(client.toggle),
                    child: client.busy || connecting
                        ? const CircularProgressIndicator()
                        : Icon(
                            Icons.power_settings_new_rounded,
                            size: 68,
                            color: running
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 28),
            if (!client.coreCompatible)
              Card(
                color: colors.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Нужна Android-сборка ядра',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        client.coreInfo['message'] as String? ??
                            'Установленный бинарник не запускается в Android.',
                      ),
                      TextButton(
                        onPressed: () => setState(() => tab = 3),
                        child: const Text('Ядро и обновления'),
                      ),
                    ],
                  ),
                ),
              ),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                leading: const Icon(Icons.public_rounded),
                title: Text(client.selected?.name ?? 'Выберите профиль'),
                subtitle: Text(
                  client.selected?.protocol ?? 'Добавьте сервер или подписку',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => setState(() => tab = 1),
              ),
            ),
            if (running)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 32,
                  runSpacing: 16,
                  children: [
                    traffic(
                      'Загружено',
                      client.runtime['download'] as num? ?? 0,
                      Icons.south_rounded,
                    ),
                    traffic(
                      'Отправлено',
                      client.runtime['upload'] as num? ?? 0,
                      Icons.north_rounded,
                    ),
                  ],
                ),
              ),
            if (client.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  client.error!,
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (client.state == 'error')
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  client.runtime['message'] as String? ??
                      'Подробности — в журнале.',
                  style: TextStyle(color: colors.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget traffic(String label, num bytes, IconData icon) => Column(
    children: [
      Icon(icon),
      const SizedBox(height: 4),
      Text(
        formatBytes(bytes.toInt()),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text(label),
    ],
  );

  Widget profiles() {
    final group =
        groupFilter == 'none' ||
            client.subscriptions.any((item) => item['id'] == groupFilter)
        ? groupFilter
        : 'all';
    final visible = client.orderedProfiles
        .where(
          (profile) =>
              (group == 'all' ||
                  (group == 'none'
                      ? profile.subscriptionId == null
                      : profile.subscriptionId == group)) &&
              '${profile.name} ${profile.address}'.toLowerCase().contains(
                filter.toLowerCase(),
              ),
        )
        .toList();
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IgnorePointer(
                  ignoring: client.privacyMode,
                  child: SearchBar(
                    controller: searchInput,
                    leading: client.addingSubscription
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    trailing: [
                      if (filter.isNotEmpty)
                        IconButton(
                          tooltip: 'Очистить поиск',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            searchInput.clear();
                            setState(() => filter = '');
                          },
                        ),
                    ],
                    hintText: client.privacyMode
                        ? 'Поиск скрыт в приватном режиме'
                        : 'Имя или адрес сервера',
                    onChanged: (value) => setState(() => filter = value),
                  ),
                ),
                if (client.subscriptions.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Подписки',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final subscription in client.orderedSubscriptions)
                    SubscriptionCard(
                      key: ValueKey(subscription['id']),
                      subscription: subscription,
                      privateMode: client.privacyMode,
                      onPin: () =>
                          guarded(() => client.pinSubscription(subscription)),
                      count: client.profiles
                          .where(
                            (profile) =>
                                profile.subscriptionId == subscription['id'],
                          )
                          .length,
                      updating: client.updatingSubscriptions.contains(
                        subscription['id'],
                      ),
                      onRefresh: () => guarded(
                        () => client.updateSubscription(subscription),
                      ),
                      onDelete: () => deleteSubscription(subscription),
                      onOpen: (url) => guarded(() => client.api.openUrl(url)),
                    ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'group-$group-${client.subscriptions.length}',
                    ),
                    initialValue: group,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Показать профили',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text(
                          'Все подписки и профили',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'none',
                        child: Text('Без подписки'),
                      ),
                      for (final subscription in client.subscriptions)
                        DropdownMenuItem(
                          value: subscription['id'] as String,
                          child: PrivateText(
                            subscription['name'] as String,
                            hidden: client.privacyMode,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => groupFilter = value ?? 'all'),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Профили · ${visible.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (client.profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        const Icon(Icons.dns_outlined, size: 48),
                        const SizedBox(height: 16),
                        const Text('Профилей пока нет'),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: import,
                          icon: const Icon(Icons.rss_feed),
                          label: const Text('Добавить подписку'),
                        ),
                      ],
                    ),
                  )
                else if (visible.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('По вашему запросу ничего не найдено'),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 104),
          sliver: SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) => profileTile(visible[index]),
          ),
        ),
      ],
    );
  }

  Widget profileTile(Profile profile) => Card(
    color: profile.id == client.selectedId
        ? Theme.of(context).colorScheme.secondaryContainer
        : null,
    child: ListTile(
      selected: profile.id == client.selectedId,
      leading: Icon(
        profile.pinned
            ? Icons.push_pin_rounded
            : profile.id == client.selectedId
            ? Icons.radio_button_checked
            : Icons.radio_button_off,
      ),
      title: Text(profile.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(profile.protocol),
          PrivateText(
            profile.address,
            hidden: client.privacyMode,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (client.testErrors[profile.id] != null)
            Text(client.testErrors[profile.id]!),
          if (client.tcpErrors[profile.id] case final tcpError?)
            Text(tcpError)
          else if (client.tcpLatency[profile.id] case final tcpDelay?)
            Text('TCP Connect: ${tcpDelay}ms'),
          if (client.accessResults[profile.id] != null)
            Text(
              'HTTPS: ${client.accessResults[profile.id]! ? 'доступен' : 'ошибка подключения'}',
            ),
        ],
      ),
      onTap: () => guarded(() => client.select(profile)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (client.testingProfiles.contains(profile.id))
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (client.latency[profile.id] case final latency?)
            Semantics(
              label: 'Задержка: $latency миллисекунд',
              excludeSemantics: true,
              child: Text(
                '${latency}ms',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Действия с профилем',
            onSelected: (value) => guarded(
              () => switch (value) {
                'test' => client.test(profile),
                'tcp' => client.testTcp(profile),
                'access' => client.checkAccess(profile),
                'pin' => client.pinProfile(profile),
                'rename' => renameProfile(profile),
                _ => client.remove(profile),
              },
            ),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'pin',
                child: Text(profile.pinned ? 'Открепить' : 'Закрепить'),
              ),
              PopupMenuItem(
                value: 'test',
                child: const Text('URLTest через Tachyon'),
              ),
              PopupMenuItem(
                value: 'tcp',
                enabled: profile.supportsTcpPing,
                child: const Text('TCP Connect'),
              ),
              const PopupMenuItem(
                value: 'access',
                child: Text('Проверить доступ через профиль'),
              ),
              const PopupMenuItem(
                value: 'rename',
                child: Text('Переименовать'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Удалить')),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> renameProfile(Profile profile) async {
    final input = TextEditingController(text: profile.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Имя профиля'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(labelText: 'Имя'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null) await client.rename(profile, value);
  }

  Future<void> deleteSubscription(Map<String, dynamic> subscription) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Удалить подписку?'),
        content: Text(
          client.privacyMode
              ? 'Подписка и её профили будут удалены с устройства.'
              : '«${subscription['name']}» и её профили будут удалены с устройства.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await guarded(() => client.removeSubscription(subscription));
    }
  }

  Widget logs() => client.logs.isEmpty
      ? const Center(child: Text('Событий пока нет'))
      : SelectionArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: client.logs.length,
            itemBuilder: (_, index) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PrivateText(
                client.logs[index],
                hidden: client.privacyMode,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        );

  Widget settings() => SettingsMenu(client: client);
}
