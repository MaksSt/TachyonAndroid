import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/profiles.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'DNS settings are accepted by the official core and preserve TLS verification',
    (tester) async {
      final checks = await NativeApi.channel.invokeMapMethod<String, dynamic>(
        'dnsSettingsCheck',
      );
      for (final name in [
        'allModesAcceptedByCore',
        'verifiedTls',
        'localBootstrap',
        'invalidRejected',
      ]) {
        expect(checks?[name], true, reason: name);
      }
    },
  );
  testWidgets('Proxy hostnames use system DNS before connecting to the proxy', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Проверка bootstrap DNS'))),
    );
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final methods = <String>[];
    final listener = proxy.listen((socket) {
      var buffer = '', stage = 0;
      socket.listen((bytes) async {
        buffer += ascii.decode(bytes);
        while (buffer.contains('\r\n\r\n') && stage < 2) {
          final end = buffer.indexOf('\r\n\r\n') + 4;
          final request = buffer.substring(0, end);
          buffer = buffer.substring(end);
          methods.add(request.split(' ').first);
          if (stage++ == 0) {
            socket.write(
              'HTTP/1.1 200 Connection Established\r\nContent-Length: 0\r\n\r\n',
            );
            await socket.flush();
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            socket.write(
              'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
            );
            await socket.flush();
            await socket.close();
          }
        }
      });
    });
    try {
      final delay = await NativeApi.channel.invokeMethod<int>(
        'urlTestFixture',
        {
          'outbound': jsonEncode({
            'type': 'http',
            'tag': 'proxy',
            'server': 'localhost',
            'server_port': proxy.port,
          }),
          'port': proxy.port,
        },
      );
      expect(delay, greaterThan(0));
      expect(methods, ['CONNECT', 'HEAD']);
      final api = NativeApi();
      expect(
        ((await api.deviceInfo())['packageId'] as String).endsWith('.checks'),
        true,
      );
      final oldState = await api.load();
      final dns = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var questions = 0;
      final dnsListener = dns.listen((socket) {
        final buffer = <int>[];
        var answered = false;
        socket.listen((bytes) async {
          if (answered) return;
          buffer.addAll(bytes);
          if (buffer.length < 2) return;
          final length = (buffer[0] << 8) | buffer[1];
          if (buffer.length < length + 2) return;
          answered = true;
          questions++;
          final query = buffer.sublist(2, length + 2);
          var end = 12;
          while (query[end] != 0) {
            end += query[end] + 1;
          }
          end++;
          final type = (query[end] << 8) | query[end + 1];
          final response = <int>[
            query[0],
            query[1],
            0x81,
            0x80,
            0,
            1,
            0,
            type == 1 ? 1 : 0,
            0,
            0,
            0,
            0,
            ...query.sublist(12, end + 4),
            if (type == 1) ...[
              0xc0,
              0x0c,
              0,
              1,
              0,
              1,
              0,
              0,
              0,
              60,
              0,
              4,
              127,
              0,
              0,
              1,
            ],
          ];
          socket.add([
            response.length >> 8,
            response.length & 255,
            ...response,
          ]);
          await socket.flush();
          await socket.close();
        });
      });
      try {
        await api.save(
          jsonEncode({
            'schema': 2,
            'dns': {'mode': 'tcp', 'address': '127.0.0.1:${dns.port}'},
          }),
        );
        final customDelay = await NativeApi.channel.invokeMethod<int>(
          'urlTestFixture',
          {
            'outbound': jsonEncode({
              'type': 'http',
              'tag': 'proxy',
              'server': 'bootstrap-test.invalid',
              'server_port': proxy.port,
            }),
            'port': proxy.port,
          },
        );
        expect(customDelay, greaterThan(0));
        expect(questions, greaterThan(0));
        expect(methods, ['CONNECT', 'HEAD', 'CONNECT', 'HEAD']);
      } finally {
        await api.save(oldState ?? '{}');
        await dnsListener.cancel();
        await dns.close();
      }
      debugPrint(
        'BOOTSTRAP_DNS system and saved custom TCP resolver completed proxy requests',
      );
    } finally {
      await listener.cancel();
      await proxy.close();
    }
  });
  testWidgets(
    'Core URLTest performs HEAD through its outbound and rejects a blocked profile',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Проверка URLTest ядра'))),
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final listener = server.listen((socket) {
        final request = StringBuffer();
        var answered = false;
        socket.listen((bytes) async {
          if (answered) return;
          request.write(ascii.decode(bytes));
          if (!request.toString().contains('\r\n\r\n')) return;
          answered = true;
          requests.add(request.toString().split('\r\n').first);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          socket.write(
            'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
          );
          await socket.flush();
          await socket.close();
        });
      });
      try {
        final delay = await NativeApi.channel.invokeMethod<int>(
          'urlTestFixture',
          {
            'outbound': jsonEncode({'type': 'direct', 'tag': 'proxy'}),
            'port': server.port,
          },
        );
        expect(delay, greaterThanOrEqualTo(150));
        expect(requests, ['HEAD /check HTTP/1.1']);
        await expectLater(
          NativeApi.channel.invokeMethod<int>('urlTestFixture', {
            'outbound': jsonEncode({'type': 'block', 'tag': 'proxy'}),
            'port': server.port,
          }),
          throwsA(isA<Exception>()),
        );
        expect(requests.length, 1);
        final emptyServer = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final emptyListener = emptyServer.listen((socket) => socket.destroy());
        try {
          await expectLater(
            NativeApi.channel.invokeMethod<int>('urlTestFixture', {
              'outbound': jsonEncode({'type': 'direct', 'tag': 'proxy'}),
              'port': emptyServer.port,
            }),
            throwsA(isA<Exception>()),
          );
        } finally {
          await emptyListener.cancel();
          await emptyServer.close();
        }
        debugPrint(
          'URLTEST_CORE HEAD confirmed, delayed HTTP response measured, blocked outbound rejected',
        );
      } finally {
        await listener.cancel();
        await server.close();
      }
    },
  );
  testWidgets('Official core returns real HTTPS URLTest delay on Android', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Проверка URLTest HTTPS'))),
    );
    final delay = await NativeApi().urlTest(
      Profile(
        id: 'direct-url-test',
        name: 'Direct',
        outbound: {'type': 'direct', 'tag': 'proxy'},
      ),
    );
    expect(delay, greaterThan(0));
    debugPrint('URLTEST_CORE_HTTPS passed; delay=${delay}ms');
  });
  testWidgets(
    'VPN notification shows the connected profile and cumulative session traffic',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Проверка уведомления VPN')),
        ),
      );
      final checks = await NativeApi.channel.invokeMapMethod<String, dynamic>(
        'notificationCheck',
      );
      for (final name in [
        'serverTitle',
        'sessionTrafficText',
        'quietUpdates',
        'stableTimestamp',
        'disconnectAction',
      ]) {
        expect(checks?[name], true, reason: name);
      }
    },
  );
  testWidgets(
    'Quick Settings uses the encrypted selection and protected native components',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Проверка плитки VPN'))),
      );
      final checks = await NativeApi.channel.invokeMapMethod<String, dynamic>(
        'quickSettingsCheck',
      );
      for (final name in [
        'selectedEncryptedProfile',
        'noFallbackProfile',
        'protectedTileAndPermissionActivity',
        'stateMapping',
        'vpnStartIntent',
        'liveStateUpdates',
        'proxyChains',
      ]) {
        expect(checks?[name], true, reason: name);
      }
    },
  );
  testWidgets(
    'TCPPing connects to the endpoint without sending HTTP or TLS data',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Проверка TCPPing'))),
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final accepted = server.first;
        final millis = await NativeApi().tcpPing(
          Profile(
            id: 'local',
            name: 'local',
            outbound: {
              'type': 'vless',
              'server': '127.0.0.1',
              'server_port': server.port,
            },
          ),
        );
        final socket = await accepted.timeout(const Duration(seconds: 5));
        final received = await socket
            .fold<int>(0, (count, bytes) => count + bytes.length)
            .timeout(const Duration(seconds: 5));
        socket.destroy();
        expect(millis, greaterThanOrEqualTo(1));
        expect(received, 0);
        debugPrint('TCPPing: TCP endpoint reached; no TLS/HTTP payload sent');
      } finally {
        await server.close();
      }
    },
  );
  testWidgets(
    'Managed core install is verified, preserves active processes and supports rollback',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Проверка обновляемого ядра')),
        ),
      );
      final result = await NativeApi.channel.invokeMapMethod<String, dynamic>(
        'managedCoreStoreCheck',
      );
      expect(result, isNotNull);
      for (final name in [
        'archiveUnchanged',
        'missingAndroidRejected',
        'cancelled',
        'badDigestRejected',
        'preservedOnError',
        'activePreserved',
        'selectedManaged',
        'rollback',
      ]) {
        expect(result![name], true, reason: name);
      }
      debugPrint(
        'Managed core: integrity, cancellation, active process and rollback passed',
      );
    },
  );
  testWidgets(
    'Android identity is stable and core self-test reports compatibility',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Проверка Android API'))),
      );
      final api = NativeApi();
      final first = await api.deviceInfo();
      expect(
        (first['packageId'] as String).endsWith('.checks'),
        true,
        reason: 'Native checks must never run against the user application package.',
      );
      final second = await api.deviceInfo();
      // Не выводим сам идентификатор в журнал даже при падении проверки.
      expect(
        RegExp(r'^[a-zA-Z0-9=-]{10,64}$').hasMatch(first['hwid'] as String),
        true,
      );
      expect(first['hwid'] == second['hwid'], true);
      expect((first['model'] as String).isNotEmpty, true);
      final core = await api.coreInfo();
      debugPrint(
        'Core self-test: compatible=${core['compatible']}, exitCode=${core['exitCode']}',
      );
      expect(
        core['compatible'],
        true,
        reason: 'The official Android core must run inside the app sandbox.',
      );
      expect(core['exitCode'], 0);
    },
  );
  testWidgets('Core SOCKS startup and shutdown do not abort on a closed pipe', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Проверка жизненного цикла ядра')),
      ),
    );
    final info = await NativeApi.channel.invokeMapMethod<String, dynamic>(
      'coreLifecycleCheck',
    );
    expect(info?['alive'], false);
    expect([0, 143], contains(info?['exitCode']));
    debugPrint(
      'Core lifecycle: alive=${info?['alive']}, exitCode=${info?['exitCode']}',
    );
  });
}
