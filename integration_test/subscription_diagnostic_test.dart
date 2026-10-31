import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/http_transport.dart';

class _DiagnosticApi extends NativeApi {
  // Полученные профили остаются только в памяти изолированного теста.
  @override
  Future<void> save(String value) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Private subscription HTTP diagnostics inside Android client', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Диагностика подписки'))),
    );
    final api = _DiagnosticApi();
    final device = await api.deviceInfo();
    final package = device['packageId'] as String;
    expect(package.endsWith('.checks'), true);
    final input = File('/data/user/0/$package/files/private-subscription-url');
    final source = (await input.readAsString()).trim();
    await input.delete();
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      for (final probe in [(hwid: true, compatibility: false, singbox: true)]) {
        final hwid = probe.hwid;
        final record = <String, dynamic>{
          'hwid_enabled': hwid,
          'user_agent_kind': probe.singbox
              ? 'own identity, sing-box format'
              : probe.compatibility
              ? 'INCY format probe'
              : 'TachyonClient',
          'platform': 'Android',
        };
        final client = ClientController(
          api,
          fetch: (uri, headers) async {
            record['request_header_names'] = headers.keys.toList();
            record['hwid_valid'] = RegExp(r'^[a-zA-Z0-9=-]{10,64}$')
                .hasMatch(headers['x-hwid'] ?? '');
            record['os_version_present'] =
                (headers['x-ver-os'] ?? '').isNotEmpty;
            record['device_model_present'] =
                (headers['x-device-model'] ?? '').isNotEmpty;
            final requestHeaders = Map<String, String>.from(headers);
            if (probe.compatibility) {
              requestHeaders['User-Agent'] = 'INCY/3.8.1/android';
            }
            if (probe.singbox) {
              requestHeaders['User-Agent'] =
                  'TachyonClient/31.10.26 (Android; compatible; sing-box)';
            }
            final response = await fetchHttps(uri, requestHeaders);
            record['http_status'] = response.status;
            record['response_bytes'] = utf8.encode(response.body).length;
            record['content_type'] = response.headers['content-type'];
            if (response.status == 200) {
              try {
                final decoded = jsonDecode(response.body);
                record['json_root'] = decoded is List
                    ? 'array'
                    : decoded is Map
                    ? 'object'
                    : 'other';
                if (decoded is List) {
                  record['json_items'] = decoded.length;
                  record['contains_full_configs'] = decoded.any(
                    (value) => value is Map && value['outbounds'] is List,
                  );
                  final protocols = <String, int>{}, networks = <String, int>{};
                  final security = <String, int>{};
                  final chains = <String, int>{},
                      options = <String, Set<String>>{};
                  for (final config in decoded.whereType<Map>()) {
                    final nodes = (config['outbounds'] as List? ?? [])
                        .whereType<Map>()
                        .toList();
                    final tags = {for (final node in nodes) node['tag']: node};
                    if (nodes.isNotEmpty) {
                      final first =
                          nodes.first['protocol'] ?? nodes.first['type'];
                      chains.update(
                        'first_is_vless',
                        (n) => n + (first == 'vless' ? 1 : 0),
                        ifAbsent: () => first == 'vless' ? 1 : 0,
                      );
                    }
                    for (final node in nodes) {
                      final stream = node['streamSettings'] as Map? ?? {};
                      final tag =
                          (node['proxySettings'] as Map? ?? {})['tag'] ??
                          (stream['sockopt'] as Map? ?? {})['dialerProxy'];
                      if (tag != null) {
                        final target = tags[tag] ?? {};
                        final targetKind = target['protocol'] ?? target['type'];
                        final key =
                            {
                              'vless',
                              'freedom',
                              'shadowsocks',
                              'trojan',
                            }.contains(targetKind)
                            ? targetKind as String
                            : 'other';
                        chains.update(key, (n) => n + 1, ifAbsent: () => 1);
                      }
                      for (final key in [
                        'xhttpSettings',
                        'splithttpSettings',
                        'grpcSettings',
                        'wsSettings',
                        'tcpSettings',
                        'rawSettings',
                        'realitySettings',
                        'tlsSettings',
                      ]) {
                        final value = stream[key];
                        if (value is Map) {
                          final known = {
                            'path',
                            'host',
                            'headers',
                            'mode',
                            'extra',
                            'serviceName',
                            'multiMode',
                            'idle_timeout',
                            'header',
                            'acceptProxyProtocol',
                            'serverName',
                            'alpn',
                            'fingerprint',
                            'publicKey',
                            'password',
                            'shortId',
                            'spiderX',
                            'show',
                            'allowInsecure',
                            'minVersion',
                            'maxVersion',
                            'certificates',
                            'pinnedPeerCertSha256',
                            'echConfigList',
                          };
                          options
                              .putIfAbsent(key, () => {})
                              .addAll(
                                value.keys.whereType<String>().where(
                                  known.contains,
                                ),
                              );
                          if (value['extra'] is Map) {
                            final extra = value['extra'] as Map;
                            options
                                .putIfAbsent('xhttp_extra', () => {})
                                .addAll(
                                  extra.keys.whereType<String>().where(
                                    (k) => {
                                      'noGRPCHeader',
                                      'noSSEHeader',
                                      'xPaddingBytes',
                                      'xmux',
                                      'downloadSettings',
                                      'scMaxEachPostBytes',
                                      'scMinPostsIntervalMs',
                                      'scStreamUpServerSecs',
                                      'headers',
                                    }.contains(k),
                                  ),
                                );
                          }
                        }
                      }
                    }
                    for (final out
                        in (config['outbounds'] as List? ?? [])
                            .whereType<Map>()) {
                      final kind = out['protocol'] ?? out['type'];
                      final key =
                          {
                            'vless',
                            'vmess',
                            'trojan',
                            'shadowsocks',
                            'freedom',
                            'blackhole',
                            'direct',
                            'block',
                            'dns',
                            'hysteria2',
                            'tuic',
                            'wireguard',
                          }.contains(kind)
                          ? kind as String
                          : 'other';
                      protocols.update(
                        key,
                        (value) => value + 1,
                        ifAbsent: () => 1,
                      );
                      final stream = out['streamSettings'] as Map? ?? {};
                      if (stream.isNotEmpty) {
                        final network = stream['network'] ?? 'tcp';
                        final transport =
                            {
                              'tcp',
                              'raw',
                              'ws',
                              'grpc',
                              'http',
                              'h2',
                              'httpupgrade',
                              'xhttp',
                              'splithttp',
                              'quic',
                              'kcp',
                            }.contains(network)
                            ? network as String
                            : 'other';
                        networks.update(
                          transport,
                          (value) => value + 1,
                          ifAbsent: () => 1,
                        );
                        final tls =
                            {
                              'none',
                              'tls',
                              'reality',
                            }.contains(stream['security'] ?? 'none')
                            ? (stream['security'] ?? 'none') as String
                            : 'other';
                        security.update(
                          tls,
                          (value) => value + 1,
                          ifAbsent: () => 1,
                        );
                      }
                    }
                  }
                  record['outbound_protocol_counts'] = protocols;
                  record['network_counts'] = networks;
                  record['security_counts'] = security;
                  record['chain_counts'] = chains;
                  record['transport_option_keys'] = {
                    for (final e in options.entries) e.key: e.value.toList(),
                  };
                }
              } on FormatException {
                /* Обычная подписка может содержать ссылки. */
              }
            }
            record['hwid_error_flags'] = response.headers.entries
                .where(
                  (entry) =>
                      entry.key.startsWith('x-hwid') &&
                      entry.value.toLowerCase() == 'true',
                )
                .map((entry) => entry.key)
                .toList();
            return response;
          },
        )..sendHwid = hwid;
        try {
          await client.addSubscription(source);
          record['imported_profiles'] = client.profiles.length;
        } catch (failure) {
          record['error_type'] = failure.runtimeType.toString();
        } finally {
          client.dispose();
        }
        // Ни ссылка, ни HWID, ни тело ответа никогда не попадают в вывод.
        debugPrint('SUBSCRIPTION_DIAGNOSTIC ${jsonEncode(record)}');
      }
    } finally {
      HttpOverrides.global = previous;
    }
  });
}
