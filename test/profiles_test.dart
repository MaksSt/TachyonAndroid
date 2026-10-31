import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/profiles.dart';

const vless =
    'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=reality&sni=example.net&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab&flow=xtls-rprx-vision#Reality';

void main() {
  test('Link names decode Cyrillic, spaces, flags and literal escapes exactly once', () {
    const name = '🇫🇮 Финляндия 1';
    final profile = parseProfile(
      'trojan://sample@example.com:443#${Uri.encodeComponent(name)}',
    );
    expect(profile.name, name);
    expect(
      parseProfile('trojan://sample@example.com:443#Literal%2520name').name,
      'Literal%20name',
    );
    expect(decodeProfileName('Invalid%ZZ'), 'Invalid%ZZ');
    expect(decodeProfileName(''), 'Профиль');
  });
  test('REALITY import preserves routing and TLS parameters', () {
    final p = parseProfile(vless);
    expect(p.name, 'Reality');
    expect(p.outbound['server'], 'example.com');
    expect(p.outbound['server_port'], 443);
    expect(p.outbound['flow'], 'xtls-rprx-vision');
    final tls = p.outbound['tls'] as Map;
    expect(tls['server_name'], 'example.net');
    expect((tls['reality'] as Map)['short_id'], 'ab');
    expect((tls['utls'] as Map)['fingerprint'], 'chrome');
    expect(tls['insecure'], isNull);
  });
  test('WebSocket host and escaped path survive import', () {
    final p = parseProfile(
      'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fwebsocket#WS',
    );
    final transport = p.outbound['transport'] as Map;
    expect(transport['path'], '/websocket');
    expect(transport['headers'], {'Host': 'cdn.example.com'});
  });
  test('Trojan uses TLS and decodes credentials', () {
    final p = parseProfile('trojan://test%3Apassword@example.com:443#Trojan');
    expect(p.outbound['password'], 'test:password');
    expect((p.outbound['tls'] as Map)['enabled'], true);
  });
  test('Hysteria2 maps the salamander obfuscator', () {
    final p = parseProfile(
      'hy2://test@example.com:443?obfs=salamander&obfs-password=sample#HY2',
    );
    expect(p.outbound['type'], 'hysteria2');
    expect(p.outbound['obfs'], {'type': 'salamander', 'password': 'sample'});
  });
  test('Malformed and unsupported links fail explicitly', () {
    for (final input in [
      'https://example.com',
      'vless://bad@example.com:443',
      'trojan://test@example.com',
      'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=reality',
    ]) {
      expect(() => parseProfile(input), throwsFormatException);
    }
  });
  test('Base64 subscription imports all profiles without duplicate IDs', () {
    final encoded = base64Encode(
      utf8.encode('$vless\ntrojan://sample@example.net:443#Second'),
    );
    final profiles = parseSubscription(encoded, subscriptionId: 'group');
    expect(profiles.length, 2);
    expect(profiles.map((p) => p.subscriptionId), everyElement('group'));
    expect(profiles[0].id, isNot(profiles[1].id));
    expect(
      () => parseSubscription('$vless\nunsupported://sample'),
      throwsFormatException,
    );
  });
  test('Profile persistence retains the selected outbound data', () {
    final original = parseProfile(vless);
    final restored = Profile.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), original.toJson());
  });
  test('Mixed provider subscriptions report unsupported schemes without losing valid nodes', () {
    final skipped = <String>[];
    final profiles = parseSubscription(
      '$vless\nvpn://provider-format\nhysteria2://sample@example.net:443#HY2',
      unsupportedSchemes: skipped,
    );
    expect(profiles.length, 2);
    expect(skipped, ['vpn']);
    expect(
      () => parseSubscription('vpn://provider-format', unsupportedSchemes: []),
      throwsFormatException,
    );
    expect(
      () => parseSubscription(
        '$vless\nvless://bad@example.net:443',
        unsupportedSchemes: [],
      ),
      throwsFormatException,
    );
  });
}
