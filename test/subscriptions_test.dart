import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/core_updates.dart';
import 'package:tachyon_client/http_transport.dart';
import 'package:tachyon_client/subscription_metadata.dart';

class SubscriptionApi extends NativeApi {
  String? data;
  bool rejectSave = false;
  @override
  Future<String?> load() async => data;
  @override
  Future<void> save(String value) async {
    if (rejectSave) throw StateError('storage unavailable');
    data = value;
  }

  @override
  Future<Map<String, dynamic>> status() async => {'state': 'stopped'};
  @override
  Future<Map<String, dynamic>> coreInfo() async => {'compatible': true};
  @override
  Future<Map<String, dynamic>> deviceInfo() async => {
    'hwid': 'and-0123456789abcdef0123456789abcdef',
    'osVersion': '16',
    'model': 'Test Device',
  };
}

void main() {
  test(
    '404 format negotiation keeps client identity, device headers and URL',
    () async {
      final requests = <Map<String, String>>[];
      final addresses = <String>[];
      final client = ClientController(
        SubscriptionApi(),
        fetch: (uri, headers) async {
          requests.add(Map.from(headers));
          addresses.add(uri.toString());
          return headers['User-Agent']!.contains('compatible; sing-box')
              ? const HttpPayload(
                  200,
                  'trojan://sample@example.com:443#Server',
                  {'profile-title': 'Compatible'},
                )
              : const HttpPayload(404, 'Not Found', {});
        },
      );
      addTearDown(client.dispose);
      await client.addSubscription('https://example.com/private-path');
      expect(requests.length, 2);
      expect(addresses.toSet(), {'https://example.com/private-path'});
      expect(requests.last['User-Agent'], startsWith('TachyonClient/'));
      for (final key in requests.first.keys.where(
        (key) => key != 'User-Agent',
      )) {
        expect(requests.last[key], requests.first[key]);
      }
      expect(client.profiles.single.name, 'Server');
      expect(client.subscriptions.single['name'], 'Compatible');
    },
  );

  test('Authentication failures and explicit HWID errors do not trigger format retry', () async {
    for (final status in [401, 403, 429, 500, 404]) {
      var requests = 0;
      final client = ClientController(
        SubscriptionApi(),
        fetch: (_, _) async {
          requests++;
          return HttpPayload(
            status,
            '',
            status == 404 ? {'x-hwid-max-devices-reached': 'true'} : {},
          );
        },
      );
      await expectLater(
        client.addSubscription('https://example.com/sub'),
        throwsFormatException,
      );
      expect(requests, 1);
      expect(client.profiles, isEmpty);
      client.dispose();
    }
  });
  test('Subscription metadata decodes UTF-8 headers and ignores malformed quota values', () {
    final metadata = SubscriptionMetadata.fromHeaders({
      'Profile-Title': 'base64:${base64Encode(utf8.encode('Моя подписка'))}',
      'announce': 'base64:${base64Encode(utf8.encode('Новости провайдера'))}',
      'Subscription-Userinfo': 'upload=1024; download=2048; total=4096; expire=1798761600; invalid=text',
      'profile-update-interval': '12',
      'support-url': 'https://example.com/help',
      'profile-web-page-url': 'javascript:alert(1)',
      'x-hwid-active': 'true',
    });
    expect(metadata.title, 'Моя подписка');
    expect(metadata.announce, 'Новости провайдера');
    expect(metadata.used, 3072);
    expect(metadata.fraction, 0.75);
    expect(metadata.updateHours, 12);
    expect(metadata.hwidActive, true);
    expect(metadata.webUrl, isNull);
    expect(
      SubscriptionMetadata.fromJson(metadata.toJson()).toJson(),
      metadata.toJson(),
    );
    final malformed = SubscriptionMetadata.fromHeaders({
      'subscription-userinfo': 'upload=-5; download=no; total=0',
    });
    expect(malformed.used, 0);
    expect(malformed.fraction, isNull);
  });
  test(
    'HWID response flags produce specific errors before parsing an empty body',
    () {
      for (final header in [
        'x-hwid-not-supported',
        'x-hwid-max-devices-reached',
        'x-hwid-limit',
      ]) {
        expect(
          () => SubscriptionMetadata.fromHeaders({header: 'true'}),
          throwsFormatException,
        );
      }
    },
  );
  test('HWID headers are sent consistently and disabled explicitly', () async {
    final requests = <Map<String, String>>[];
    final api = SubscriptionApi();
    final client = ClientController(
      api,
      fetch: (uri, headers) async {
        requests.add(headers);
        return const HttpPayload(
          200,
          'trojan://sample@example.com:443#Server',
          {'profile-title': 'Provider'},
        );
      },
    );
    addTearDown(client.dispose);
    await client.initialize();
    await client.addSubscription('https://example.com/sub');
    await client.updateSubscription(client.subscriptions.single);
    expect(requests[0]['x-hwid'], requests[1]['x-hwid']);
    expect(requests[0]['x-device-os'], 'Android');
    expect(requests[0]['x-device-model'], 'Test Device');
    expect(client.subscriptions.single['name'], 'Provider');
    await client.setHwid(false);
    await client.updateSubscription(client.subscriptions.single);
    expect(requests.last.keys, isNot(contains('x-hwid')));
    expect(requests.last.keys, isNot(contains('x-device-model')));
  });
  test('Refresh preserves selection and custom names, failed responses preserve prior data', () async {
    var reject = false;
    final client = ClientController(
      SubscriptionApi(),
      fetch: (_, _) async => reject
          ? const HttpPayload(200, '', {'x-hwid-max-devices-reached': 'true'})
          : const HttpPayload(200, 'trojan://sample@example.com:443#Server', {
              'profile-title': 'Provider',
            }),
    );
    addTearDown(client.dispose);
    await client.initialize();
    await client.addSubscription('https://example.com/sub');
    final selected = client.selectedId;
    await client.rename(client.selected!, 'Мой сервер');
    await client.updateSubscription(client.subscriptions.single);
    expect(client.selectedId, selected);
    expect(client.selected!.name, 'Мой сервер');
    reject = true;
    await expectLater(
      client.updateSubscription(client.subscriptions.single),
      throwsFormatException,
    );
    expect(client.selectedId, selected);
    expect(client.profiles.length, 1);
    expect(client.updatingSubscriptions, isEmpty);
  });
  test(
    'Settings persist and roll back when encrypted storage rejects a write',
    () async {
      final api = SubscriptionApi();
      final client = ClientController(api);
      addTearDown(client.dispose);
      await client.initialize();
      await client.setTheme('dark');
      await client.setHwid(false);
      final restored = ClientController(api);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.themeChoice, 'dark');
      expect(restored.sendHwid, false);
      api.rejectSave = true;
      await expectLater(client.setTheme('light'), throwsStateError);
      expect(client.themeChoice, 'dark');
    },
  );
  test('Duplicate server configurations retain distinct IDs on subscription refresh', () async {
    final client = ClientController(
      SubscriptionApi(),
      fetch: (_, _) async => const HttpPayload(
        200,
        'trojan://sample@example.com:443#First\ntrojan://sample@example.com:443#Second',
        {},
      ),
    );
    addTearDown(client.dispose);
    await client.initialize();
    await client.addSubscription('https://example.com/sub');
    final ids = client.profiles.map((profile) => profile.id).toSet();
    await client.updateSubscription(client.subscriptions.single);
    expect(client.profiles.map((profile) => profile.id).toSet(), ids);
    expect(ids.length, 2);
    await expectLater(
      client.addSubscription('https://example.com/sub'),
      throwsFormatException,
    );
  });
  test(
    'Absent subscription metadata is distinguished from an unlimited plan',
    () {
      final absent = SubscriptionMetadata.fromHeaders({});
      expect(absent.quotaKnown, false);
      expect(absent.expiryKnown, false);
      final unlimited = SubscriptionMetadata.fromHeaders({
        'subscription-userinfo': 'total=0; expire=0',
      });
      expect(unlimited.quotaKnown, true);
      expect(unlimited.expiryKnown, true);
      expect(unlimited.total, 0);
    },
  );
  test('Latest core release uses the official repository and reports absence of Android builds', () async {
    final release = await CoreRelease.latest((uri, headers) async {
      expect(uri.path, '/repos/Dushnilin/tachyon-core/releases/latest');
      return HttpPayload(
        200,
        jsonEncode({
          'tag_name': 'v9.9.9',
          'html_url':
              'https://github.com/Dushnilin/tachyon-core/releases/tag/v9.9.9',
          'assets': [
            {'name': 'tachyon-core-x86_64.tar.gz'},
          ],
        }),
        {},
      );
    });
    expect(release.version, 'v9.9.9');
    expect(release.androidAssets, isEmpty);
    await expectLater(
      CoreRelease.latest((_, _) async => const HttpPayload(429, '', {})),
      throwsFormatException,
    );
  });
}
