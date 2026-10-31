import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/profiles.dart';

class PingApi extends NativeApi {
  int tcpRequests = 0, httpsRequests = 0, urlRequests = 0;
  int? delay = 37;
  bool failUrl = false;
  @override
  Future<int?> urlTest(Profile profile) async {
    urlRequests++;
    if (failUrl) throw const FormatException('Failed');
    return delay;
  }

  @override
  Future<int?> tcpPing(Profile profile) async {
    tcpRequests++;
    return 17;
  }

  @override
  Future<int?> httpsProbe(Profile profile) async {
    httpsRequests++;
    return 450;
  }
}

void main() {
  final tcp = Profile(
    id: 'tcp',
    name: 'TCP',
    outbound: {'type': 'vless', 'server': 'example.com', 'server_port': 443},
  );
  final udp = Profile(
    id: 'udp',
    name: 'UDP',
    outbound: {
      'type': 'hysteria2',
      'server': 'example.com',
      'server_port': 443,
    },
  );
  test(
    'TCPPing runs without a compatible core and never invokes the HTTPS probe',
    () async {
      final api = PingApi();
      final client = ClientController(api)..coreInfo = {'compatible': false};
      await client.testTcp(tcp);
      expect(client.tcpLatency[tcp.id], 17);
      expect(client.latency[tcp.id], isNull);
      expect(api.urlRequests, 0);
      expect(api.tcpRequests, 1);
      expect(api.httpsRequests, 0);
      client.dispose();
    },
  );
  test(
    'UDP profiles use core URLTest but reject the separate TCP Connect',
    () async {
      final api = PingApi();
      final client = ClientController(api)..coreInfo = {'compatible': true};
      expect(udp.supportsTcpPing, false);
      await expectLater(client.testTcp(udp), throwsFormatException);
      expect(api.tcpRequests, 0);
      await client.test(udp);
      expect(client.latency[udp.id], 37);
      expect(api.urlRequests, 1);
      await client.checkAccess(udp);
      expect(api.httpsRequests, 1);
      expect(client.accessResults[udp.id], true);
      expect(client.latency[udp.id], 37);
      client.dispose();
    },
  );
  test(
    'Main latency comes from the core and is independent from TCP Connect',
    () async {
      final api = PingApi();
      final client = ClientController(api);
      await client.test(tcp);
      expect(client.latency[tcp.id], 37);
      expect(api.urlRequests, 1);
      expect(api.tcpRequests, 0);
      expect(api.httpsRequests, 0);
      await client.testTcp(tcp);
      expect(client.latency[tcp.id], 37);
      expect(client.tcpLatency[tcp.id], 17);
      client.dispose();
    },
  );
  test(
    'Failed core URLTest clears stale latency and never falls back to TCP',
    () async {
      final api = PingApi();
      final client = ClientController(api);
      await client.test(tcp);
      api.failUrl = true;
      await expectLater(client.test(tcp), throwsFormatException);
      expect(client.latency[tcp.id], isNull);
      expect(client.testErrors[tcp.id], contains('URLTest'));
      expect(api.tcpRequests, 0);
      client.dispose();
    },
  );
  test(
    'Missing or nonpositive core delay is a failure, not a successful ping',
    () async {
      final api = PingApi();
      final client = ClientController(api);
      for (final invalid in [null, 0, -1]) {
        api.delay = invalid;
        await expectLater(client.test(tcp), throwsFormatException);
        expect(client.latency[tcp.id], isNull);
      }
      client.coreInfo = {'compatible': false};
      final count = api.urlRequests;
      await expectLater(client.test(tcp), throwsFormatException);
      expect(api.urlRequests, count);
      client.dispose();
    },
  );
}
