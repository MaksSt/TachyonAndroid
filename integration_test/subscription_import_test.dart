import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/http_transport.dart';

import 'native_contract_test.dart' as native_contracts;

class _PrivateApi extends NativeApi {
  @override
  Future<void> save(String value) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Real Android subscription imports, validates in Tachyon and refreshes without losing identity',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Проверка импорта подписки')),
        ),
      );
      final api = _PrivateApi();
      final device = await api.deviceInfo();
      final package = device['packageId'] as String;
      expect(package.endsWith('.checks'), true);
      final input = File(
        '/data/user/0/$package/files/private-subscription-url',
      );
      final source = (await input.readAsString()).trim();
      await input.delete();
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      var expected = 0;
      final statuses = <int>[];
      final client = ClientController(
        api,
        fetch: (uri, headers) async {
          final response = await fetchHttps(uri, headers);
          statuses.add(response.status);
          if (response.status == 200) {
            final json = jsonDecode(response.body);
            if (json is List) {
              expected = json.length;
            }
          }
          return response;
        },
      );
      try {
        try {
          await client.addSubscription(source);
        } catch (failure) {
          fail(
            'Private import failed: ${failure.runtimeType}; HTTP statuses=$statuses',
          );
        }
        final skipped =
            client.subscriptions.single['unsupportedProtocols'] as List;
        debugPrint(
          'PRIVATE_IMPORT profiles=${client.profiles.length}; expected=$expected; skipped=$skipped; HTTP=$statuses',
        );
        expect(expected, greaterThan(1));
        final invalid = <Map<String, dynamic>>[];
        for (var index = 0; index < client.profiles.length; index++) {
          final check = await NativeApi.channel
              .invokeMapMethod<String, dynamic>('outboundConfigCheck', {
                'outbound': client.profiles[index].coreConfigJson,
              });
          if (check?['valid'] != true) {
            invalid.add({
              'index': index,
              'exitCode': check?['exitCode'],
              'unknownFields': check?['unknownFields'],
              'reasons': check?['reasons'],
            });
          }
        }
        debugPrint(
          'PRIVATE_CORE_CHECK configs=${client.profiles.length}; invalid=$invalid; chains=${client.profiles.where((p) => p.extraOutbounds.isNotEmpty).length}',
        );
        expect(invalid, isEmpty);
        expect(skipped, isEmpty);
        expect(client.profiles.length, expected);
        final ids = client.profiles.map((p) => p.id).toSet();
        await client.select(client.profiles.first);
        await client.rename(client.selected!, 'Проверка сохранения имени');
        await client.pinProfile(client.selected!);
        final selected = client.selectedId;
        try {
          await client.updateSubscription(client.subscriptions.single);
        } catch (failure) {
          fail('Private refresh failed: ${failure.runtimeType}');
        }
        expect(client.profiles.map((p) => p.id).toSet(), ids);
        expect(client.selectedId, selected);
        expect(client.selected?.name, 'Проверка сохранения имени');
        expect(client.selected?.pinned, true);
        debugPrint(
          'PRIVATE_REFRESH identity, selection, alias and pin preserved',
        );
        var attempts = 0, connected = false;
        for (final profile in client.profiles.take(4)) {
          attempts++;
          try {
            await api.httpsProbe(profile);
            final delay = await api.urlTest(profile);
            if (delay == null || delay <= 0) {
              throw const FormatException('Invalid core delay');
            }
            connected = true;
            break;
          } catch (_) {
            /* Другой сервер проверяется без вывода адресов и секретов. */
          }
        }
        debugPrint(
          'PRIVATE_HTTPS_AND_URLTEST connected=$connected; attempts=$attempts',
        );
        expect(
          connected,
          true,
          reason: 'At least one imported profile must complete HTTPS through Tachyon.',
        );
      } finally {
        client.dispose();
        HttpOverrides.global = previous;
      }
    },
  );
  // Проверки общего нативного слоя выполняются в той же изолированной установке.
  native_contracts.main();
}
