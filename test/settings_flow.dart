import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/main.dart';

class SettingsApi extends NativeApi {
  String? saved;
  bool busy = false, failSave = false;
  int tileRequests = 0;
  @override
  Future<String?> load() async => saved;
  @override
  Future<void> save(String value) async {
    if (failSave) throw StateError('storage unavailable');
    saved = value;
  }

  @override
  Future<Map<String, dynamic>> coreInfo() async => {'compatible': true};
  @override
  Future<Map<String, dynamic>> status() async => {
    'state': 'stopped',
    'logs': <String>[],
    'coreVersion': 'v0.2.7',
    'coreUpdate': {
      'busy': busy,
      'progress': 35,
      'phase': busy ? 'downloading' : 'idle',
      'message': busy ? 'Загрузка Android-ядра' : '',
    },
  };
  @override
  Future<void> startCoreUpdate() async {
    busy = true;
  }

  @override
  Future<void> requestVpnTile() async {
    tileRequests++;
  }
}

Future<void> checkSettingsNavigation(WidgetTester tester) async {
  final api = SettingsApi();
  await tester.pumpWidget(TachyonApp(api: api));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Настройки').last);
  await tester.pumpAndSettle();
  expect(find.text('Обновить ядро с GitHub'), findsNothing);
  for (final section in [
    'Ядро',
    'Оформление',
    'Подписки',
    'DNS',
    'Управление VPN',
    'О приложении',
  ]) {
    await tester.ensureVisible(find.text(section));
    await tester.pumpAndSettle();
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
    switch (section) {
      case 'Ядро':
        await tester.ensureVisible(find.text('Обновить ядро с GitHub'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Обновить ядро с GitHub'));
        await tester.pumpAndSettle();
        expect(find.text('Загрузка Android-ядра · 35%'), findsOneWidget);
      case 'Оформление':
        expect(find.text('Цветовой тон'), findsOneWidget);
        expect(find.text('Тема'), findsOneWidget);
      case 'Подписки':
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect((jsonDecode(api.saved!) as Map)['sendHwid'], false);
      case 'DNS':
        expect(find.text('DNS подключения'), findsOneWidget);
        expect(find.text('Режим DNS'), findsOneWidget);
      case 'Управление VPN':
        await tester.tap(find.text('Кнопка VPN в шторке'));
        await tester.pumpAndSettle();
        expect(api.tileRequests, 1);
      case 'О приложении':
        expect(find.text('Данные на устройстве'), findsOneWidget);
    }
    expect(tester.takeException(), isNull, reason: section);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }
  expect(find.text('Настройки'), findsWidgets);
  await tester.pumpWidget(const SizedBox.shrink());
}
