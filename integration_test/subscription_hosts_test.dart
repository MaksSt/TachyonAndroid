import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/http_transport.dart';
import 'package:tachyon_client/profiles.dart';

class _MemoryApi extends NativeApi {
  @override
  Future<void> save(String value) async {}
}

String endpointId(Profile profile) => utf8
    .encode(profile.outbound['server'] as String)
    .fold(2166136261, (hash, byte) => ((hash ^ byte) * 16777619) & 0xffffffff)
    .toRadixString(16);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Selected hostname profiles complete URLTest and HTTPS through Tachyon',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Проверка профилей с доменами')),
        ),
      );
      final api = _MemoryApi();
      final package = (await api.deviceInfo())['packageId'] as String;
      expect(package.endsWith('.checks'), true);
      final input = File(
        '/data/user/0/$package/files/private-subscription-url',
      );
      final text = (await input.readAsString()).trim();
      await input.delete();
      final options = text.startsWith('{')
          ? jsonDecode(text) as Map
          : <String, dynamic>{'url': text};
      final source = options['url'] as String;
      final selected = (options['endpointIds'] as List? ?? [])
          .cast<String>()
          .toSet();
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      List<dynamic> originals = [];
      final client = ClientController(
        api,
        fetch: (uri, headers) async {
          final result = await fetchHttps(uri, headers);
          if (result.status == 200) {
            final json = jsonDecode(result.body);
            if (json is List) originals = json;
          }
          return result;
        },
      );
      final failures = <int>[];
      try {
        await client.addSubscription(source);
        final targets = client.profiles.indexed
            .where(
              (item) =>
                  InternetAddress.tryParse(
                        item.$2.outbound['server'] as String? ?? '',
                      ) ==
                      null &&
                  (selected.isEmpty || selected.contains(endpointId(item.$2))),
            )
            .toList();
        expect(targets, isNotEmpty);
        if (selected.isNotEmpty) {
          expect(targets.map((item) => endpointId(item.$2)).toSet(), selected);
        }
        for (final (index, profile) in targets) {
          final out = profile.outbound;
          final tls = out['tls'] as Map? ?? {};
          final transport = out['transport'] as Map? ?? {};
          final root = originals[index] as Map;
          final sourceOut = ((root['outbounds'] as List).first as Map);
          final stream = sourceOut['streamSettings'] as Map? ?? {};
          final dns = root['dns'] as Map? ?? {};
          final row = <String, Object?>{
            'index': index,
            'endpointId': endpointId(profile),
            'transport': transport['type'] ?? 'tcp',
            'sourceNetwork': stream['network'] ?? 'tcp',
            'security': stream['security'] ?? 'none',
            'fragment': tls['fragment'] == true,
            'tls': tls['enabled'] == true,
            'sniIsEndpoint': tls['server_name'] == out['server'],
            'explicitTransportHost':
                (transport['host'] as String? ?? '').isNotEmpty,
            'sourceDnsHostOverride': (dns['hosts'] as Map? ?? {}).containsKey(
              out['server'],
            ),
          };
          Future<bool> probe(Profile item) async {
            try {
              return (await api.urlTest(item) ?? 0) > 0;
            } catch (_) {
              return false;
            }
          }

          row['original'] = await probe(profile);
          try {
            await api.httpsProbe(profile);
            row['https'] = true;
          } catch (_) {
            row['https'] = false;
          }
          if (row['original'] != true || row['https'] != true) {
            failures.add(index);
          }
          try {
            final addresses = await InternetAddress.lookup(
              out['server'] as String,
            ).timeout(const Duration(seconds: 10));
            row['ipv4Count'] = addresses
                .where((a) => a.type == InternetAddressType.IPv4)
                .length;
            row['ipv6Count'] = addresses
                .where((a) => a.type == InternetAddressType.IPv6)
                .length;
            final address =
                addresses
                    .where((a) => a.type == InternetAddressType.IPv4)
                    .firstOrNull ??
                addresses.first;
            final directOut = Map<String, dynamic>.from(
              jsonDecode(jsonEncode(out)) as Map,
            );
            // Сохраняем логическое имя HTTP/TLS при замене только адреса соединения.
            if (transport['type'] == 'xhttp' &&
                row['explicitTransportHost'] == false) {
              (directOut['transport'] as Map)['host'] =
                  tls['server_name'] ?? out['server'];
              row['explicitHost'] = await probe(
                Profile(
                  id: 'host-$index',
                  name: 'Check',
                  outbound: directOut,
                  extraOutbounds: profile.extraOutbounds,
                ),
              );
            }
            directOut['server'] = address.address;
            row['resolvedIp'] = await probe(
              Profile(
                id: 'ip-$index',
                name: 'Check',
                outbound: directOut,
                extraOutbounds: profile.extraOutbounds,
              ),
            );
          } catch (_) {
            row['systemDnsFailed'] = true;
          }
          // Только индексы, публичные перечисления и результаты; никаких URL,
          // доменов, UUID, путей, заголовков и ключей подписки.
          debugPrint('HOST_PROFILE ${jsonEncode(row)}');
        }
        debugPrint('HOST_PROFILE_FAILURES $failures');
        expect(failures, isEmpty);
      } finally {
        client.dispose();
        HttpOverrides.global = previous;
      }
    },
  );
}
