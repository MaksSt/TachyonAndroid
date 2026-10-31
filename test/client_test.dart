import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/main.dart';

class FakeApi extends NativeApi {
  String? saved;
  @override
  Future<String?> load() async => saved;
  @override
  Future<void> save(String value) async {
    saved = value;
  }

  @override
  Future<Map<String, dynamic>> coreInfo() async => {'compatible': true};

  @override
  Future<Map<String, dynamic>> status() async => {
    'state': 'stopped',
    'logs': <String>[],
    'coreVersion': 'test',
  };
}

void main() {
  testWidgets(
    'Import source sheet fits enlarged text with the keyboard visible',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(TachyonApp(api: FakeApi()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Профили').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Theme choice applies immediately and survives reopening', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оформление'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Как в системе'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная').last);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    expect((jsonDecode(api.saved!) as Map)['theme'], 'dark');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Subscription details wrap on a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = FakeApi()
      ..saved = jsonEncode({
        'schema': 2,
        'theme': 'dark',
        'profiles': [],
        'subscriptions': [
          {
            'id': 'group',
            'name': 'Очень длинное название подписки провайдера',
            'url': 'https://example.com/sub',
            'metadata': {
              'upload': 1024,
              'download': 2048,
              'total': 4096,
              'expire': 1798761600,
              'updateHours': 12,
              'announce': 'Объявление провайдера с подробностями обслуживания',
              'hwidActive': true,
            },
          },
        ],
      });
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профили').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Очень длинное название подписки провайдера').first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Sections fit a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(TachyonApp(api: FakeApi()));
    await tester.pumpAndSettle();
    for (final section in ['Профили', 'Журнал', 'Настройки', 'Главная']) {
      await tester.tap(find.text(section).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: section);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Empty client disables VPN and exposes all main sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TachyonApp(api: FakeApi()));
    await tester.pumpAndSettle();
    expect(find.text('Отключено'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNull,
    );
    await tester.tap(find.text('Профили').last);
    await tester.pumpAndSettle();
    expect(find.text('Профилей пока нет'), findsOneWidget);
    await tester.tap(find.text('Журнал').last);
    await tester.pumpAndSettle();
    expect(find.text('Событий пока нет'), findsOneWidget);
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    expect(find.text('Ядро'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Imported profile is selected and persisted', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'trojan://sample@example.com:443#MyServer'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final api = FakeApi();
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профили').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Из буфера обмена'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('MyServer'), findsOneWidget);
    final stored = jsonDecode(api.saved!) as Map<String, dynamic>;
    expect((stored['profiles'] as List).length, 1);
    expect(stored['selectedId'], (stored['profiles'] as List).first['id']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
