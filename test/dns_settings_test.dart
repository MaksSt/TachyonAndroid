import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/dns_settings.dart';
import 'package:tachyon_client/dns_settings_card.dart';

import 'settings_flow.dart';

void main() {
  test('DNS validates supported protocols without accepting insecure or ambiguous endpoints', () {
    expect(DnsSettings.fromJson(null).mode, DnsMode.system);
    for (final settings in [
      const DnsSettings(mode: DnsMode.udp, address: '1.1.1.1:53'),
      const DnsSettings(
        mode: DnsMode.tcp,
        address: '[2606:4700:4700::1111]:53',
      ),
      const DnsSettings(
        mode: DnsMode.doh,
        address: 'https://dns.example/custom/dns-query',
      ),
      const DnsSettings(mode: DnsMode.dot, address: 'dns.example:853'),
    ]) {
      expect(DnsSettings.fromJson(settings.toJson()).address, settings.address);
    }
    for (final value in [
      'http://dns.example/query',
      'https://user:pass@dns.example/query',
      'https://dns.example/query?key=example',
      'https://dns.example/query#part',
      'https://dns.example/bad path',
      'https://dns.example/%',
    ]) {
      expect(
        () => DnsSettings(mode: DnsMode.doh, address: value).validated(),
        throwsFormatException,
      );
    }
    for (final value in [
      '1.1.1.1:99999',
      '999.999.999.999',
      'dns.example/path',
      'bad..example',
      '-bad.example',
    ]) {
      expect(
        () => DnsSettings(mode: DnsMode.tcp, address: value).validated(),
        throwsFormatException,
      );
    }
  });
  test(
    'DNS persists with the profiles and rolls back on a failed save',
    () async {
      final api = SettingsApi()
        ..saved = jsonEncode({
          'schema': 2,
          'profiles': [],
          'subscriptions': [],
        });
      final client = ClientController(api);
      await client.initialize();
      expect(client.dns.mode, DnsMode.system);
      const custom = DnsSettings(
        mode: DnsMode.doh,
        address: 'https://dns.example/private/dns-query',
      );
      await client.setDns(custom);
      expect((jsonDecode(api.saved!) as Map)['dns'], custom.toJson());
      final reopened = ClientController(SettingsApi()..saved = api.saved);
      await reopened.initialize();
      expect(reopened.dns.toJson(), custom.toJson());
      reopened.dispose();
      api.failSave = true;
      await expectLater(client.setDns(const DnsSettings()), throwsStateError);
      expect(client.dns.toJson(), custom.toJson());
      api.failSave = false;
      client.testingProfiles.add('busy');
      await expectLater(
        client.setDns(const DnsSettings()),
        throwsFormatException,
      );
      expect(client.dns.toJson(), custom.toJson());
      client.dispose();
    },
  );
  testWidgets(
    'DNS form validates, saves and restores system mode on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = SettingsApi();
      final client = ClientController(api);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
              child: SingleChildScrollView(
                child: DnsSettingsCard(client: client),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<DnsMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DoH · HTTPS').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'http://dns.example/query',
      );
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Для DoH нужна HTTPS-ссылка.'), findsOneWidget);
      expect(api.saved, isNull);
      await tester.enterText(
        find.byType(TextFormField),
        'https://dns.example/dns-query',
      );
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(client.dns.mode, DnsMode.doh);
      await tester.ensureVisible(find.text('Вернуть системный DNS'));
      await tester.tap(find.text('Вернуть системный DNS'));
      await tester.pumpAndSettle();
      expect(client.dns.mode, DnsMode.system);
      expect(client.dns.address, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      client.dispose();
    },
  );
}
