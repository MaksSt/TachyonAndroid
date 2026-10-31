import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/main.dart';
import 'package:tachyon_client/profiles.dart';

class ControlsApi extends NativeApi {
  String? saved;
  int active = 0, maximum = 0;
  @override
  Future<String?> load() async => saved;
  @override
  Future<void> save(String value) async {
    saved = value;
  }

  @override
  Future<Map<String, dynamic>> status() async => {
    'state': 'stopped',
    'logs': ['Private 203.0.113.7 secret-domain.example'],
    'coreVersion': 'test',
  };
  @override
  Future<Map<String, dynamic>> coreInfo() async => {'compatible': true};
  @override
  Future<int?> urlTest(Profile profile) async {
    active++;
    if (active > maximum) maximum = active;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    active--;
    if (profile.name == 'Fail') throw const FormatException('URLTest failed');
    return 25;
  }
}

String fixture() => jsonEncode({
  'schema': 2,
  'selectedId': 'manual',
  'profiles': [
    Profile(
      id: 'manual',
      name: 'PrivateManual',
      outbound: {'type': 'trojan', 'server': '203.0.113.7', 'server_port': 443},
    ).toJson(),
    Profile(
      id: 'sub',
      name: 'PrivateSubProfile',
      outbound: {
        'type': 'trojan',
        'server': 'secret-domain.example',
        'server_port': 443,
      },
      subscriptionId: 'group',
    ).toJson(),
  ],
  'subscriptions': [
    {
      'id': 'group',
      'name': 'PrivateSubscription',
      'url': 'https://example.invalid/private-token',
      'metadata': {},
    },
  ],
});

void main() {
  test('Pins and privacy persist without changing profile identity', () async {
    final api = ControlsApi()..saved = fixture();
    final controller = ClientController(api);
    await controller.initialize();
    await controller.pinProfile(controller.profiles.last);
    await controller.pinSubscription(controller.subscriptions.single);
    await controller.setPrivacy(true);
    expect(controller.orderedProfiles.first.id, 'sub');
    final saved = api.saved;
    controller.dispose();
    final reopened = ClientController(ControlsApi()..saved = saved);
    await reopened.initialize();
    expect(reopened.orderedProfiles.first.pinned, true);
    expect(reopened.orderedSubscriptions.first['pinned'], true);
    expect(reopened.privacyMode, true);
    expect(reopened.selectedId, 'manual');
    reopened.dispose();
  });

  test(
    'Bulk core URLTest uses at most three workers and includes UDP profiles',
    () async {
      final api = ControlsApi();
      final controller = ClientController(api);
      for (var i = 0; i < 7; i++) {
        controller.profiles.add(
          Profile(
            id: '$i',
            name: i == 6 ? 'Fail' : 'Node $i',
            outbound: {
              'type': 'trojan',
              'server': 'example.com',
              'server_port': 443,
            },
          ),
        );
      }
      controller.profiles.add(
        Profile(
          id: 'udp',
          name: 'UDP',
          outbound: {
            'type': 'hysteria2',
            'server': 'example.com',
            'server_port': 443,
          },
        ),
      );
      final result = await controller.pingAll();
      expect(result, (success: 7, failed: 1, skipped: 0));
      expect(api.maximum, 3);
      expect(controller.pingCompleted, 8);
      expect(controller.pingingAll, false);
      controller.dispose();
    },
  );

  testWidgets(
    'Privacy keeps profile names and statistics visible while hiding subscriptions and addresses',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final api = ControlsApi()..saved = fixture();
        await tester.pumpWidget(TachyonApp(api: api));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Скрыть личные данные'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Профили').last);
        await tester.pumpAndSettle();
        for (final text in ['PrivateManual', 'PrivateSubProfile']) {
          expect(find.text(text), findsWidgets);
        }
        for (final text in [
          'PrivateSubscription',
          '203.0.113.7:443',
          'secret-domain.example:443',
        ]) {
          expect(find.text(text), findsNothing);
        }
        expect(find.textContaining('Трафик не указан'), findsOneWidget);
        expect(
          tester
              .getSemantics(find.byType(Scaffold).first)
              .toStringDeep()
              .contains('203.0.113.7'),
          false,
        );
        await tester.tap(find.text('Журнал').last);
        await tester.pumpAndSettle();
        expect(find.textContaining('Private 203.0.113.7'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('Without subscription filter only shows manual profiles', (
    tester,
  ) async {
    final api = ControlsApi()..saved = fixture();
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профили').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.text('Все подписки и профили').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Без подписки').last);
    await tester.pumpAndSettle();
    expect(find.text('PrivateSubProfile'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('PrivateManual'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PrivateManual'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'QR imports through the same path without displaying its contents',
    (tester) async {
      final api = ControlsApi();
      await tester.pumpWidget(
        TachyonApp(
          api: api,
          scanQr: (_) async => 'trojan://sample@example.com:443#QrNode',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Профили').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сканировать QR-код'));
      await tester.pumpAndSettle();
      expect(find.text('QrNode'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget); // Только строка поиска.
      expect((jsonDecode(api.saved!) as Map)['profiles'].length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
