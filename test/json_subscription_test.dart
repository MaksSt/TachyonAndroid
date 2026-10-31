import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/json_subscription.dart';
import 'package:tachyon_client/profiles.dart';

import 'dart:convert';

Map<String, dynamic> proxy({
  String tag = 'entry',
  String host = 'example.com',
}) => {
  'tag': tag,
  'protocol': 'vless',
  'settings': {
    'vnext': [
      {
        'address': host,
        'port': 443,
        'users': [
          {
            'id': '00000000-0000-4000-8000-000000000001',
            'encryption': 'none',
            'flow': 'xtls-rprx-vision',
          },
        ],
      },
    ],
  },
  'streamSettings': {
    'network': 'tcp',
    'security': 'reality',
    'realitySettings': {
      'serverName': 'example.net',
      'fingerprint': 'chrome',
      'publicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'shortId': 'ab',
    },
  },
};

void main() {
  test('A direct detour retains the physical proxy endpoint for TCPPing', () {
    final profile = Profile(
      id: 'direct-relay',
      name: 'Example',
      outbound: {
        'type': 'vless',
        'tag': 'proxy',
        'server': 'example.com',
        'server_port': 443,
        'detour': 'chain-1',
      },
      extraOutbounds: [
        {'type': 'direct', 'tag': 'chain-1'},
      ],
    );
    expect(profile.tcpEndpoint['server'], 'example.com');
    expect(profile.supportsTcpPing, true);
  });
  test('TLS hello fragmentation is enabled and its parameter adaptation is explicit', () {
    final node = proxy();
    (node['streamSettings'] as Map)['finalmask'] = {
      'tcp': [
        {
          'type': 'fragment',
          'settings': {
            'packets': 'tlshello',
            'length': '10-20',
            'interval': '10-20',
          },
        },
      ],
    };
    final warnings = <String>[];
    final item = importJsonSubscription(node, warnings: warnings).single;
    expect((item.outbounds.single['tls'] as Map)['fragment'], true);
    expect((item.outbounds.single['tls'] as Map)['insecure'], isNull);
    expect(warnings.single, contains('размер фрагментов и задержку'));
    expect(
      ((item.outbounds.single['tls'] as Map)['reality'] as Map)['public_key'],
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
  });

  test('Current XHTTP keys win over legacy aliases and a disabled old lifetime is harmless', () {
    final node = proxy()
      ..['streamSettings'] = {
        'network': 'xhttp',
        'xhttpSettings': {
          'headers': {'Outer': 'ignored'},
          'extra': {
            'sessionKey': 'legacy',
            'sessionIDKey': 'current',
            'sessionIDPlacement': 'header',
            'sessionIDTable': '',
            'sessionIDLength': '16-32',
            'headers': {'Inner': 'kept'},
            'xmux': {'cMaxLifetimeMs': 0, 'maxConcurrency': '8-32'},
          },
        },
      };
    final transport =
        importJsonSubscription(node).single.outbounds.single['transport']
            as Map;
    expect(transport['session_key'], 'current');
    expect(transport['session_placement'], 'header');
    expect(transport['session_id_table'], '');
    expect(transport['session_id_length'], '16-32');
    expect(transport.containsKey('session_length'), false);
    expect(transport['headers'], {'Inner': 'kept'});
    expect(transport['xmux'], {'max_concurrency': '8-32'});
  });
  test(
    'Profile storage, pin, rename and TCP endpoint retain the full chain',
    () {
      final primary = proxy()..['proxySettings'] = {'tag': 'relay'};
      final profile = parseSubscription(
        jsonEncode([
          {
            'remarks': 'Literal%20name',
            'outbounds': [primary, proxy(tag: 'relay', host: 'relay.example')],
          },
        ]),
      ).single;
      expect(profile.name, 'Literal%20name');
      final restored = Profile.fromJson(
        jsonDecode(jsonEncode(profile.withPin(true).renamed('Alias').toJson()))
            as Map<String, dynamic>,
      );
      expect(restored.extraOutbounds.length, 1);
      expect(restored.tcpEndpoint['server'], 'relay.example');
      expect(restored.supportsTcpPing, true);
      expect(restored.connectionKey, profile.connectionKey);
      expect((jsonDecode(restored.coreConfigJson) as List).length, 2);
      expect(restored.pinned, true);
      expect(restored.name, 'Alias');
    },
  );

  test(
    'XHTTP ranges and XMUX camel case are converted without losing values',
    () {
      final node = proxy()
        ..['streamSettings'] = {
          'network': 'xhttp',
          'security': 'none',
          'xhttpSettings': {
            'host': 'cdn.example',
            'path': '/',
            'extra': {
              'xPaddingBytes': '100-1000',
              'scMaxEachPostBytes': 1000000,
              'xmux': {'maxConcurrency': '16-32', 'hKeepAlivePeriod': 0},
            },
          },
        };
      final transport =
          importJsonSubscription(node).single.outbounds.single['transport']
              as Map;
      expect(transport['x_padding_bytes'], '100-1000');
      expect(transport['sc_max_each_post_bytes'], 1000000);
      expect(transport['xmux'], {
        'max_concurrency': '16-32',
        'h_keep_alive_period': 0,
      });
    },
  );
  test(
    'Xray JSON keeps REALITY and credentials and excludes service outbounds',
    () {
      final item = importJsonSubscription({
        'remarks': 'Сервер',
        'outbounds': [
          proxy(),
          {'protocol': 'freedom'},
          {'protocol': 'blackhole'},
        ],
      }).single;
      expect(item.name, 'Сервер');
      expect(item.outbounds.length, 1);
      final out = item.outbounds.single;
      expect(out['uuid'], '00000000-0000-4000-8000-000000000001');
      expect(out['flow'], 'xtls-rprx-vision');
      expect(out['packet_encoding'], 'xudp');
      expect((out['tls'] as Map)['server_name'], 'example.net');
      expect(((out['tls'] as Map)['reality'] as Map)['short_id'], 'ab');
      expect(out.containsKey('routing'), false);
    },
  );

  test(
    'Proxy chains stay in one profile and unused proxies are not imported',
    () {
      final main = proxy()..['proxySettings'] = {'tag': 'relay'};
      final root = {
        'remarks': 'Цепочка',
        'outbounds': [
          main,
          proxy(tag: 'relay', host: 'relay.example'),
          proxy(tag: 'unused'),
        ],
      };
      final item = importJsonSubscription([root]).single;
      expect(item.outbounds.length, 2);
      expect(item.outbounds.first['tag'], 'proxy');
      expect(item.outbounds.first['detour'], 'chain-1');
      expect(item.outbounds.last['server'], 'relay.example');
      expect(item.outbounds.last['tag'], 'chain-1');
    },
  );

  test(
    'Dangling and cyclic detours are rejected even during mixed imports',
    () {
      final first = proxy()..['proxySettings'] = {'tag': 'relay'};
      final relay = proxy(tag: 'relay')..['proxySettings'] = {'tag': 'entry'};
      expect(
        () => importJsonSubscription({
          'outbounds': [first, relay],
        }, unsupported: []),
        throwsFormatException,
      );
      expect(
        () => importJsonSubscription({
          'outbounds': [first],
        }, unsupported: []),
        throwsFormatException,
      );
    },
  );

  test('WS, gRPC, HTTPUpgrade and XHTTP map transport fields', () {
    for (final network in ['ws', 'grpc', 'httpupgrade', 'xhttp']) {
      final node = proxy();
      node['streamSettings'] = {
        'network': network,
        'security': 'tls',
        'tlsSettings': {
          'serverName': 'example.net',
          'alpn': ['h2'],
        },
        '${network}Settings': {
          'path': '/path',
          if (network != 'grpc') 'host': 'cdn.example',
          if (network == 'grpc') 'serviceName': 'grpc-service',
          if (network == 'xhttp') 'mode': 'stream-up',
        },
      };
      final out = importJsonSubscription(node).single.outbounds.single;
      expect((out['transport'] as Map)['type'], network);
      expect((out['tls'] as Map)['alpn'], ['h2']);
      if (network == 'grpc') {
        expect((out['transport'] as Map)['service_name'], 'grpc-service');
      } else {
        expect((out['transport'] as Map)['path'], '/path');
      }
      if (network == 'ws') {
        expect((out['transport'] as Map)['headers'], {'Host': 'cdn.example'});
      }
    }
  });

  test('Unsupported transport is reported while malformed known configuration fails the whole import', () {
    final badTransport = proxy()..['streamSettings'] = {'network': 'kcp'};
    final skipped = <String>[];
    final result = importJsonSubscription([
      badTransport,
      proxy(),
    ], unsupported: skipped);
    expect(result.length, 1);
    expect(skipped, ['Xray: неподдерживаемый транспорт']);
    expect(() => importJsonSubscription(badTransport), throwsFormatException);
    final malformed = proxy();
    ((malformed['settings'] as Map)['vnext'] as List).first['port'] = 0;
    expect(
      () => importJsonSubscription([proxy(), malformed], unsupported: []),
      throwsFormatException,
    );
  });

  test('Explicit TLS trust constraints are not silently discarded', () {
    final node = proxy()
      ..['streamSettings'] = {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {
          'pinnedPeerCertSha256': ['example-pin'],
        },
      };
    expect(() => importJsonSubscription(node), throwsFormatException);
  });

  test('Native Tachyon arrays retain opaque options and names', () {
    final result = importJsonSubscription([
      {
        'type': 'trojan',
        'tag': 'Custom',
        'server': 'example.com',
        'server_port': 443,
        'password': 'sample',
        'tls': {'enabled': true},
      },
    ]);
    expect(result.single.name, 'Custom');
    expect(result.single.outbounds.single['password'], 'sample');
    expect(result.single.outbounds.single['tag'], 'proxy');
  });
}
