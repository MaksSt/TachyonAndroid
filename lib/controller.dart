import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'profiles.dart';
import 'core_updates.dart';
import 'http_transport.dart';
import 'subscription_metadata.dart';
import 'app_version.dart';
import 'app_tone.dart';
import 'dns_settings.dart';

class NativeApi {
  static const channel = MethodChannel('dev.tachyon.client/control');
  Future<String?> load() => channel.invokeMethod<String>('loadState');
  Future<void> save(String value) =>
      channel.invokeMethod<void>('saveState', {'data': value});
  Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('status') ?? {},
  );
  Future<void> connect(Profile profile) => channel.invokeMethod<void>(
    'connect',
    {'outbound': profile.coreConfigJson, 'profileName': profile.name},
  );
  Future<void> disconnect() => channel.invokeMethod<void>('disconnect');
  Future<void> requestVpnTile() => channel.invokeMethod<void>('requestVpnTile');
  Future<Map<String, dynamic>> deviceInfo() async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('deviceInfo') ?? {},
  );
  Future<Map<String, dynamic>> coreInfo() async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('coreInfo') ?? {},
  );
  Future<void> openUrl(String url) =>
      channel.invokeMethod<void>('openUrl', {'url': url});
  Future<void> startCoreUpdate() =>
      channel.invokeMethod<void>('startCoreUpdate');
  Future<void> setCoreAutoUpdate(bool enabled) =>
      channel.invokeMethod<void>('setCoreAutoUpdate', {'enabled': enabled});
  Future<void> rollbackCore() => channel.invokeMethod<void>('rollbackCore');
  Future<int?> tcpPing(Profile profile) =>
      channel.invokeMethod<int>('tcpPing', {
        'server': profile.tcpEndpoint['server'],
        'port': profile.tcpEndpoint['server_port'],
        'type': profile.tcpEndpoint['type'],
      });
  Future<int?> urlTest(Profile profile) => channel.invokeMethod<int>(
    'urlTest',
    {'outbound': profile.coreConfigJson},
  );
  Future<int?> httpsProbe(Profile profile) => channel.invokeMethod<int>(
    'httpsProbe',
    {'outbound': profile.coreConfigJson},
  );
}

class ClientController extends ChangeNotifier {
  ClientController(this.api, {HttpFetch? fetch}) : fetch = fetch ?? fetchHttps;
  final NativeApi api;
  final HttpFetch fetch;
  final List<Profile> profiles = [];
  final List<Map<String, dynamic>> subscriptions = [];
  final Map<String, int> latency = {};
  final Map<String, int> tcpLatency = {};
  final Map<String, String> tcpErrors = {};
  final Map<String, bool> accessResults = {};
  Map<String, dynamic> runtime = {'state': 'stopped', 'logs': <String>[]};
  String? selectedId;
  String? error;
  bool busy = false;
  bool loading = true;
  String themeChoice = 'system';
  AppTone tone = AppTone.red;
  DnsSettings dns = const DnsSettings();
  bool sendHwid = true;
  bool privacyMode = false;
  bool pingingAll = false;
  int pingCompleted = 0, pingTotal = 0;
  List<Profile> get orderedProfiles => [
    ...profiles.where((p) => p.pinned),
    ...profiles.where((p) => !p.pinned),
  ];
  List<Map<String, dynamic>> get orderedSubscriptions => [
    ...subscriptions.where((s) => s['pinned'] == true),
    ...subscriptions.where((s) => s['pinned'] != true),
  ];
  Map<String, dynamic> coreInfo = {};
  CoreRelease? coreRelease;
  bool checkingCore = false;
  bool addingSubscription = false;
  final Set<String> updatingSubscriptions = {};
  final Set<String> testingProfiles = {};
  final Map<String, String> testErrors = {};
  bool get coreCompatible => coreInfo['compatible'] != false;
  Map<String, dynamic> get coreManager =>
      Map<String, dynamic>.from(runtime['coreManager'] as Map? ?? {});
  Map<String, dynamic> get coreUpdate =>
      Map<String, dynamic>.from(runtime['coreUpdate'] as Map? ?? {});
  bool get updatingCore => coreUpdate['busy'] == true;
  bool _polling = false;
  bool _disposed = false;
  Timer? _timer;
  Future<void> _writes = Future<void>.value();
  Profile? get selected =>
      profiles.where((profile) => profile.id == selectedId).firstOrNull;
  String get state => runtime['state'] as String? ?? 'stopped';
  List<String> get logs => (runtime['logs'] as List? ?? []).cast<String>();

  Future<void> initialize() async {
    try {
      final text = await api.load();
      if (text != null && text.isNotEmpty) {
        final data = jsonDecode(text) as Map<String, dynamic>;
        profiles.addAll(
          (data['profiles'] as List? ?? []).map(
            (item) => Profile.fromJson(Map<String, dynamic>.from(item as Map)),
          ),
        );
        subscriptions.addAll(
          (data['subscriptions'] as List? ?? []).map(
            (item) => Map<String, dynamic>.from(item as Map),
          ),
        );
        selectedId = data['selectedId'] as String?;
        themeChoice = {'system', 'light', 'dark'}.contains(data['theme'])
            ? data['theme'] as String
            : 'system';
        sendHwid = data['sendHwid'] != false;
        tone = AppTone.parse(data['tone']);
        dns = DnsSettings.fromJson(data['dns']);
        privacyMode = data['privacyMode'] == true;
        if ((data['schema'] as int? ?? 1) < 2) {
          for (var i = 0; i < profiles.length; i++) {
            profiles[i] = profiles[i].renamed(
              decodeProfileName(profiles[i].name),
              custom: false,
            );
          }
        }
      }
      try {
        coreInfo = await api.coreInfo();
      } catch (_) {
        /* Нет платформенного адаптера в unit-тестах. */
      }
      await refreshStatus();
    } catch (_) {
      error = 'Не удалось загрузить данные приложения.';
    } finally {
      loading = false;
      _notify();
    }
    if (!_disposed) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => refreshStatus(),
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> persist() => api.save(
    jsonEncode({
      'schema': 2,
      'theme': themeChoice,
      'tone': tone.name,
      'dns': dns.toJson(),
      'sendHwid': sendHwid,
      'privacyMode': privacyMode,
      'profiles': profiles.map((p) => p.toJson()).toList(),
      'subscriptions': subscriptions,
      'selectedId': selectedId,
    }),
  );
  Future<void> _change(void Function() change) {
    final operation = _writes.then((_) async {
      final oldProfiles = List<Profile>.of(profiles);
      final oldSubscriptions = subscriptions
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      final oldSelected = selectedId;
      final oldTheme = themeChoice;
      final oldTone = tone;
      final oldDns = dns;
      final oldHwid = sendHwid;
      final oldPrivacy = privacyMode;
      try {
        change();
        await persist();
      } catch (_) {
        profiles
          ..clear()
          ..addAll(oldProfiles);
        subscriptions
          ..clear()
          ..addAll(oldSubscriptions);
        selectedId = oldSelected;
        themeChoice = oldTheme;
        tone = oldTone;
        dns = oldDns;
        sendHwid = oldHwid;
        privacyMode = oldPrivacy;
        _notify();
        rethrow;
      }
      _notify();
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> refreshStatus() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      runtime = await api.status();
      final selection = runtime['coreSelectionId'];
      if (selection != null && selection != coreInfo['selectionId']) {
        coreInfo = await api.coreInfo();
      }
      _notify();
    } catch (_) {
      /* Повторим при следующем опросе. */
    } finally {
      _polling = false;
    }
  }

  Future<void> select(Profile profile) async {
    if (profile.id != selectedId && {'running', 'connecting'}.contains(state)) {
      await api.disconnect();
      await refreshStatus();
    }
    await _change(() {
      selectedId = profile.id;
    });
  }

  Future<void> remove(Profile profile) async {
    if (profile.id == selectedId && {'running', 'connecting'}.contains(state)) {
      await api.disconnect();
    }
    await _change(() {
      profiles.removeWhere((p) => p.id == profile.id);
      if (selectedId == profile.id) selectedId = profiles.firstOrNull?.id;
    });
  }

  Future<void> importText(String value) async {
    final incoming = parseSubscription(value);
    await _change(() {
      profiles.addAll(incoming);
      selectedId ??= incoming.first.id;
    });
  }

  Future<void> importValue(String value) async {
    final text = value.trim();
    if (text.isEmpty) {
      throw const FormatException('Буфер обмена или QR-код пуст.');
    }
    if (text.length > 4 * 1024 * 1024) {
      throw const FormatException('Слишком большой объём данных для импорта.');
    }
    if (!text.contains('\n') && Uri.tryParse(text)?.scheme == 'https') {
      await addSubscription(text);
    } else {
      await importText(text);
    }
  }

  Future<void> setPrivacy(bool value) => _change(() {
    privacyMode = value;
    _notify();
  });

  Future<void> pinProfile(Profile profile) => _change(() {
    final index = profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      profiles[index] = profiles[index].withPin(!profiles[index].pinned);
    }
  });

  Future<void> pinSubscription(Map<String, dynamic> subscription) =>
      _change(() {
        final index = subscriptions.indexWhere(
          (s) => s['id'] == subscription['id'],
        );
        if (index >= 0) {
          subscriptions[index] = {
            ...subscriptions[index],
            'pinned': subscriptions[index]['pinned'] != true,
          };
        }
      });

  Future<({int success, int failed, int skipped})> pingAll() async {
    if (pingingAll) return (success: 0, failed: 0, skipped: 0);
    final targets = profiles
        .where((p) => !testingProfiles.contains(p.id))
        .toList();
    final skipped = profiles.length - targets.length;
    pingingAll = true;
    pingCompleted = 0;
    pingTotal = targets.length;
    _notify();
    var next = 0, success = 0, failed = 0;
    Future<void> worker() async {
      while (!_disposed && next < targets.length) {
        final profile = targets[next++];
        try {
          await test(profile);
          success++;
        } catch (_) {
          failed++;
        }
        pingCompleted++;
        _notify();
      }
    }

    try {
      await Future.wait(
        List.generate(targets.length.clamp(0, 3), (_) => worker()),
      );
    } finally {
      pingingAll = false;
      _notify();
    }
    return (success: success, failed: failed, skipped: skipped);
  }

  Future<void> setTheme(String value) async {
    if (!{'system', 'light', 'dark'}.contains(value)) return;
    await _change(() {
      themeChoice = value;
    });
  }

  Future<void> setTone(AppTone value) => _change(() {
    tone = value;
  });

  Future<void> setDns(DnsSettings value) async {
    final settings = value.validated();
    if (testingProfiles.isNotEmpty || busy) {
      throw const FormatException(
        'Дождитесь завершения подключения и проверок профилей.',
      );
    }
    await _change(() {
      dns = settings;
    });
    latency.clear();
    testErrors.clear();
    accessResults.clear();
    _notify();
  }

  Future<void> setHwid(bool value) => _change(() {
    sendHwid = value;
  });

  Future<void> updateCore() async {
    if (updatingCore) return;
    await api.startCoreUpdate();
    await refreshStatus();
  }

  Future<void> setCoreAutoUpdate(bool enabled) async {
    await api.setCoreAutoUpdate(enabled);
    await refreshStatus();
  }

  Future<void> rollbackCore() async {
    await api.rollbackCore();
    await refreshStatus();
  }

  Future<void> rename(Profile profile, String name) async {
    final value = name.trim();
    if (value.isEmpty || value.length > 200) {
      throw const FormatException('Введите имя от 1 до 200 символов.');
    }
    await _change(() {
      final index = profiles.indexWhere((item) => item.id == profile.id);
      if (index >= 0) profiles[index] = profiles[index].renamed(value);
    });
  }

  Future<void> removeSubscription(Map<String, dynamic> subscription) async {
    if (selected?.subscriptionId == subscription['id'] &&
        {'running', 'connecting'}.contains(state)) {
      await api.disconnect();
    }
    await _change(() {
      profiles.removeWhere(
        (profile) => profile.subscriptionId == subscription['id'],
      );
      subscriptions.removeWhere((item) => item['id'] == subscription['id']);
      if (!profiles.any((profile) => profile.id == selectedId)) {
        selectedId = profiles.firstOrNull?.id;
      }
    });
  }

  Future<void> checkCoreUpdate() async {
    if (checkingCore) return;
    checkingCore = true;
    _notify();
    try {
      coreRelease = await CoreRelease.latest(fetch);
    } finally {
      checkingCore = false;
      _notify();
    }
  }

  Future<void> addSubscription(String value) async {
    if (addingSubscription) {
      throw const FormatException('Дождитесь загрузки текущей подписки.');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Укажите HTTPS-ссылку на подписку.');
    }
    if (subscriptions.any((item) => item['url'] == uri.toString())) {
      throw const FormatException(
        'Эта подписка уже добавлена. Обновите её в списке подписок.',
      );
    }
    final id = newId();
    addingSubscription = true;
    _notify();
    try {
      final incoming = await _download(uri, id);
      await _change(() {
        subscriptions.add({
          'id': id,
          'url': uri.toString(),
          'name': incoming.metadata.title.isEmpty
              ? uri.host
              : incoming.metadata.title,
          'metadata': incoming.metadata.toJson(),
          'unsupportedProtocols': incoming.unsupportedSchemes,
          'conversionWarnings': incoming.warnings,
          'updated': DateTime.now().toIso8601String(),
        });
        profiles.addAll(incoming.profiles);
        selectedId ??= incoming.profiles.first.id;
      });
    } finally {
      addingSubscription = false;
      _notify();
    }
  }

  Future<void> updateSubscription(Map<String, dynamic> subscription) async {
    final id = subscription['id'] as String;
    if (!updatingSubscriptions.add(id)) return;
    _notify();
    try {
      final incoming = await _download(
        Uri.parse(subscription['url'] as String),
        id,
      );
      final oldSelected = selected;
      final previous = profiles
          .where((profile) => profile.subscriptionId == id)
          .toList();
      final replacements = incoming.profiles.map((profile) {
        final old = previous
            .where((old) => old.connectionKey == profile.connectionKey)
            .firstOrNull;
        if (old != null) previous.remove(old);
        return old == null
            ? profile
            : Profile(
                id: old.id,
                name: old.customName ? old.name : profile.name,
                outbound: profile.outbound,
                subscriptionId: id,
                customName: old.customName,
                pinned: old.pinned,
                extraOutbounds: profile.extraOutbounds,
              );
      }).toList();
      if (oldSelected?.subscriptionId == id &&
          !replacements.any((profile) => profile.id == oldSelected?.id) &&
          {'running', 'connecting'}.contains(state)) {
        await api.disconnect();
        await refreshStatus();
      }
      await _change(() {
        final index = subscriptions.indexWhere((item) => item['id'] == id);
        if (index < 0) return;
        profiles.removeWhere((profile) => profile.subscriptionId == id);
        profiles.addAll(replacements);
        if (oldSelected?.subscriptionId == id &&
            !replacements.any((profile) => profile.id == selectedId)) {
          selectedId = replacements.first.id;
        }
        subscriptions[index] = {
          ...subscriptions[index],
          if (incoming.metadata.title.isNotEmpty)
            'name': incoming.metadata.title,
          'metadata': incoming.metadata.toJson(),
          'unsupportedProtocols': incoming.unsupportedSchemes,
          'conversionWarnings': incoming.warnings,
          'updated': DateTime.now().toIso8601String(),
        };
      });
    } finally {
      updatingSubscriptions.remove(id);
      _notify();
    }
  }

  Future<
    ({
      List<Profile> profiles,
      SubscriptionMetadata metadata,
      List<String> unsupportedSchemes,
      List<String> warnings,
    })
  >
  _download(Uri uri, String subscriptionId) async {
    final headers = <String, String>{
      'User-Agent': 'TachyonClient/$clientVersion (Android)',
      'Accept': 'text/plain, application/json',
    };
    if (sendHwid) {
      final device = await api.deviceInfo();
      final hwid = device['hwid'] as String? ?? '';
      if (!RegExp(r'^[a-zA-Z0-9=-]{10,64}$').hasMatch(hwid)) {
        throw const FormatException(
          'Не удалось получить постоянный HWID устройства.',
        );
      }
      headers.addAll({
        'x-hwid': hwid,
        'x-device-os': 'Android',
        'x-ver-os': device['osVersion'] as String? ?? '',
        'x-device-model': device['model'] as String? ?? '',
        'x-app-version': clientVersion,
      });
    }
    var response = await fetch(uri, headers);
    // Некоторые панели возвращают 404 для неизвестного клиента вместо выдачи
    // совместимого JSON. Повтор ограничен тем же URL и сохраняет наш User-Agent.
    SubscriptionMetadata.fromHeaders(response.headers);
    if (response.status == 404) {
      response = await fetch(uri, {
        ...headers,
        'User-Agent':
            'TachyonClient/$clientVersion (Android; compatible; sing-box)',
      });
    }
    final metadata = SubscriptionMetadata.fromHeaders(response.headers);
    if (response.status >= 300 && response.status < 400) {
      throw const FormatException(
        'Ссылка перенаправляет запрос. Укажите конечную HTTPS-ссылку подписки.',
      );
    }
    if (response.status != 200) {
      throw FormatException(
        'Сервер подписки вернул HTTP ${response.status}. Проверьте ссылку и лимит устройств.',
      );
    }
    final skipped = <String>[];
    final warnings = <String>[];
    return (
      profiles: parseSubscription(
        response.body,
        subscriptionId: subscriptionId,
        unsupportedSchemes: skipped,
        conversionWarnings: warnings,
      ),
      metadata: metadata,
      unsupportedSchemes: skipped,
      warnings: warnings,
    );
  }

  Future<void> toggle() async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      if ({'running', 'connecting'}.contains(state)) {
        await api.disconnect();
      } else if (!coreCompatible) {
        error =
            coreInfo['message'] as String? ??
            'Установленное ядро несовместимо с Android.';
      } else if (selected != null) {
        await api.connect(selected!);
      }
      await refreshStatus();
    } on PlatformException catch (failure) {
      error = failure.message ?? 'Не удалось подключиться.';
    } catch (_) {
      error = 'Не удалось подключиться.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> test(Profile profile) async {
    if (!testingProfiles.add(profile.id)) return;
    testErrors.remove(profile.id);
    _notify();
    try {
      if (!coreCompatible) {
        throw const FormatException('Установленное ядро не запускается.');
      }
      final result = await api.urlTest(profile);
      if (result == null || result <= 0) {
        throw const FormatException('Ядро не вернуло задержку URLTest.');
      }
      latency[profile.id] = result;
    } catch (_) {
      latency.remove(profile.id);
      testErrors[profile.id] = 'URLTest: нет ответа через профиль';
      rethrow;
    } finally {
      testingProfiles.remove(profile.id);
      _notify();
    }
  }

  Future<void> testTcp(Profile profile) async {
    if (!testingProfiles.add(profile.id)) return;
    tcpErrors.remove(profile.id);
    _notify();
    try {
      if (!profile.supportsTcpPing) {
        throw const FormatException('TCP Connect неприменим к UDP-профилю.');
      }
      final result = await api.tcpPing(profile);
      if (result == null || result <= 0) {
        throw const FormatException('Не получен результат TCP Connect.');
      }
      tcpLatency[profile.id] = result;
    } catch (_) {
      tcpLatency.remove(profile.id);
      tcpErrors[profile.id] = 'TCP Connect: нет соединения';
      rethrow;
    } finally {
      testingProfiles.remove(profile.id);
      _notify();
    }
  }

  Future<void> checkAccess(Profile profile) async {
    if (!testingProfiles.add(profile.id)) return;
    accessResults.remove(profile.id);
    _notify();
    try {
      if (!coreCompatible) {
        throw const FormatException('Установленное ядро не запускается.');
      }
      await api.httpsProbe(profile);
      accessResults[profile.id] = true;
    } catch (_) {
      accessResults[profile.id] = false;
      rethrow;
    } finally {
      testingProfiles.remove(profile.id);
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
