import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tachyon_client/controller.dart';

// Запускается отдельно, когда VPN основного приложения уже включён через UI.
// UID пакета .checks входит в VPN, в отличие от UID самого ядра.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> requireVpn(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Проверка трафика через TUN')),
      ),
    );
    final device = await NativeApi().deviceInfo();
    expect((device['packageId'] as String).endsWith('.checks'), true);
    expect(
      await NativeApi.channel.invokeMethod<bool>('vpnNetworkCheck'),
      true,
      reason: 'Enable the main application VPN before running traffic checks.',
    );
  }

  testWidgets('A separate Android UID completes HTTPS through the active VPN', (
    tester,
  ) async {
    await requireVpn(tester);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(
        Uri.parse('https://www.gstatic.com/generate_204'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      await response.drain<void>();
      expect(response.statusCode, 204);
      debugPrint('VPN traffic check: independent UID, HTTPS 204 passed');
    } finally {
      client.close(force: true);
    }
  });

  testWidgets(
    'A separate Android UID receives UDP DNS through the active VPN',
    (tester) async {
      await requireVpn(tester);
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final answer = Completer<Datagram>();
      final id = DateTime.now().microsecondsSinceEpoch & 0xffff;
      final question = <int>[
        id >> 8,
        id & 0xff,
        1,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        for (final label in 'example.com'.split('.')) ...[
          label.length,
          ...ascii.encode(label),
        ],
        0,
        0,
        1,
        0,
        1,
      ];
      final listener = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket.receive();
        if (packet == null ||
            packet.address.address != '1.1.1.1' ||
            packet.port != 53 ||
            packet.data.length < 12) {
          return;
        }
        final bytes = packet.data;
        if ((bytes[0] << 8 | bytes[1]) == id && !answer.isCompleted) {
          answer.complete(packet);
        }
      });
      try {
        expect(
          socket.send(question, InternetAddress('1.1.1.1'), 53),
          question.length,
        );
        final response = (await answer.future.timeout(
          const Duration(seconds: 15),
        )).data;
        expect(response[2] & 0x80, 0x80);
        expect(response[3] & 15, 0);
        expect(response[6] << 8 | response[7], greaterThan(0));
        debugPrint('VPN traffic check: independent UID, UDP DNS passed');
      } finally {
        await listener.cancel();
        socket.close();
      }
    },
  );
}
