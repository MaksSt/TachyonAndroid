import 'dart:convert';
import 'dart:math';

import 'json_subscription.dart';

String newId() =>
    base64UrlEncode(List<int>.generate(16, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.outbound,
    this.subscriptionId,
    this.customName = false,
    this.pinned = false,
    this.extraOutbounds = const [],
  });
  final String id;
  final String name;
  final Map<String, dynamic> outbound;
  final String? subscriptionId;
  final bool customName;
  final bool pinned;
  final List<Map<String, dynamic>> extraOutbounds;
  String get coreConfigJson => jsonEncode(
    extraOutbounds.isEmpty ? outbound : [outbound, ...extraOutbounds],
  );
  String get connectionKey => canonicalOutbound({
    'outbound': outbound,
    'extraOutbounds': extraOutbounds,
  });
  Map<String, dynamic> get tcpEndpoint {
    var current = outbound;
    final visited = <String>{};
    while (current['detour'] is String) {
      final tag = current['detour'] as String;
      if (!visited.add(tag)) return {};
      final next = extraOutbounds
          .where((item) => item['tag'] == tag)
          .firstOrNull;
      if (next == null) return {};
      if (next['type'] == 'direct') return current;
      current = next;
    }
    return current;
  }

  bool get supportsTcpPing =>
      tcpEndpoint['server'] is String &&
      (tcpEndpoint['server'] as String).isNotEmpty &&
      tcpEndpoint['server_port'] is int &&
      !{
        'hysteria2',
        'hysteria',
        'tuic',
        'wireguard',
      }.contains(tcpEndpoint['type']);
  Profile renamed(String value, {bool custom = true}) => Profile(
    id: id,
    name: value,
    outbound: outbound,
    subscriptionId: subscriptionId,
    customName: custom,
    pinned: pinned,
    extraOutbounds: extraOutbounds,
  );
  String get address =>
      '${outbound['server'] ?? 'Локально'}:${outbound['server_port'] ?? '—'}';
  String get protocol => (outbound['type'] as String).toUpperCase();
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'outbound': outbound,
    'subscriptionId': subscriptionId,
    'customName': customName,
    'pinned': pinned,
    if (extraOutbounds.isNotEmpty) 'extraOutbounds': extraOutbounds,
  };
  factory Profile.fromJson(Map<String, dynamic> value) => Profile(
    id: value['id'] as String,
    name: value['name'] as String,
    outbound: Map<String, dynamic>.from(value['outbound'] as Map),
    subscriptionId: value['subscriptionId'] as String?,
    customName: value['customName'] == true,
    pinned: value['pinned'] == true,
    extraOutbounds: (value['extraOutbounds'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(),
  );
  Profile withPin(bool value) => Profile(
    id: id,
    name: name,
    outbound: outbound,
    subscriptionId: subscriptionId,
    customName: customName,
    pinned: value,
    extraOutbounds: extraOutbounds,
  );
}

String decodeBase64(String value) => utf8.decode(
  base64.decode(
    base64.normalize(
      value
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll('-', '+')
          .replaceAll('_', '/'),
    ),
  ),
);

String canonicalOutbound(Map<String, dynamic> value) {
  Object? normalize(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: normalize(item[key])};
    }
    if (item is List) return item.map(normalize).toList();
    return item;
  }

  return jsonEncode(normalize(value));
}

String decodeProfileName(String value, {String fallback = 'Профиль'}) {
  var name = value;
  try {
    name = Uri.decodeComponent(name);
  } on FormatException {
    // Некорректный escape не должен мешать импорту исправного профиля.
  } on ArgumentError {
    // Uri.decodeComponent также использует ArgumentError для повреждённых escapes.
  }
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return name.isEmpty ? fallback : name;
}

Profile parseProfile(String input, {String? subscriptionId}) {
  final text = input.trim();
  if (text.startsWith('{')) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> || value['type'] is! String) {
      throw const FormatException(
        'Нужен JSON одного outbound Tachyon с полем type.',
      );
    }
    final outbound = Map<String, dynamic>.from(value)..['tag'] = 'proxy';
    return Profile(
      id: newId(),
      name: value['tag'] as String? ?? 'Конфигурация',
      outbound: outbound,
      subscriptionId: subscriptionId,
    );
  }
  final uri = Uri.parse(text);
  if (!{'vless', 'trojan', 'hysteria2', 'hy2'}.contains(uri.scheme)) {
    throw const FormatException(
      'Поддерживаются ссылки VLESS, Trojan, Hysteria2 и JSON outbound.',
    );
  }
  if (uri.host.isEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isEmpty) {
    throw const FormatException(
      'В ссылке отсутствуют сервер, порт или учётные данные.',
    );
  }
  final query = uri.queryParameters;
  final type = uri.scheme == 'hy2' ? 'hysteria2' : uri.scheme;
  final outbound = <String, dynamic>{
    'type': type,
    'tag': 'proxy',
    'server': uri.host,
    'server_port': uri.port,
  };
  final credentials = Uri.decodeComponent(uri.userInfo);
  if (type == 'vless') {
    if (!RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
        .hasMatch(credentials)) {
      throw const FormatException('Некорректный UUID VLESS.');
    }
    outbound['uuid'] = credentials;
    if (query['flow']?.isNotEmpty == true) outbound['flow'] = query['flow'];
    outbound['packet_encoding'] = 'xudp';
  } else {
    outbound['password'] = credentials;
  }
  final security = query['security'] ?? (type == 'vless' ? 'none' : 'tls');
  if (security != 'none') {
    if (!{'tls', 'reality'}.contains(security)) {
      throw const FormatException('Неподдерживаемый режим TLS.');
    }
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': query['sni'] ?? query['peer'] ?? uri.host,
    };
    if (query['alpn']?.isNotEmpty == true) {
      tls['alpn'] = query['alpn']!.split(',');
    }
    if (query['fp']?.isNotEmpty == true) {
      tls['utls'] = {'enabled': true, 'fingerprint': query['fp']};
    }
    if (query['allowInsecure'] == '1' || query['insecure'] == '1') {
      tls['insecure'] = true;
    }
    if (security == 'reality') {
      if (query['pbk']?.isNotEmpty != true) {
        throw const FormatException('Не указан публичный ключ REALITY.');
      }
      tls['reality'] = {
        'enabled': true,
        'public_key': query['pbk'],
        'short_id': query['sid'] ?? '',
      };
      tls.putIfAbsent('utls', () => {'enabled': true, 'fingerprint': 'chrome'});
    }
    outbound['tls'] = tls;
  }
  final transport = query['type'] ?? 'tcp';
  if (!{
    'tcp',
    'raw',
    'ws',
    'grpc',
    'httpupgrade',
    'xhttp',
  }.contains(transport)) {
    throw const FormatException('Неподдерживаемый транспорт.');
  }
  if (transport != 'tcp' && transport != 'raw') {
    final options = <String, dynamic>{'type': transport};
    if (transport == 'grpc') {
      options['service_name'] = query['serviceName'] ?? '';
    } else {
      options['path'] = query['path'] ?? '/';
      if (query['host']?.isNotEmpty == true) {
        if (transport == 'ws') {
          options['headers'] = {'Host': query['host']};
        } else {
          options['host'] = query['host'];
        }
      }
      if (transport == 'xhttp') options['mode'] = query['mode'] ?? 'auto';
    }
    outbound['transport'] = options;
  }
  if (type == 'hysteria2' && query['obfs'] == 'salamander') {
    outbound['obfs'] = {
      'type': 'salamander',
      'password': query['obfs-password'] ?? '',
    };
  }
  return Profile(
    id: newId(),
    name: decodeProfileName(uri.fragment, fallback: uri.host),
    outbound: outbound,
    subscriptionId: subscriptionId,
  );
}

List<Profile> parseSubscription(
  String value, {
  String? subscriptionId,
  List<String>? unsupportedSchemes,
  List<String>? conversionWarnings,
}) {
  var text = value.trim();
  if (!text.contains('://') && !text.startsWith('{') && !text.startsWith('[')) {
    try {
      text = decodeBase64(text);
    } on FormatException {
      throw const FormatException(
        'Подписка не содержит поддерживаемых ссылок.',
      );
    }
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    Object? document;
    try {
      document = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Некорректный JSON подписки.');
    }
    return importJsonSubscription(
          document,
          unsupported: unsupportedSchemes,
          warnings: conversionWarnings,
        )
        .map(
          (item) => Profile(
            id: newId(),
            name: _jsonName(item.name),
            outbound: item.outbounds.first,
            extraOutbounds: item.outbounds.skip(1).toList(),
            subscriptionId: subscriptionId,
          ),
        )
        .toList();
  }
  final lines = text.startsWith('{')
      ? [text]
      : const LineSplitter()
            .convert(text)
            .where(
              (line) => line.trim().isNotEmpty && !line.trim().startsWith('#'),
            )
            .toList();
  if (lines.isEmpty) throw const FormatException('Подписка пуста.');
  final profiles = <Profile>[];
  for (final line in lines) {
    final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://')
        .firstMatch(line.trim())
        ?.group(1)
        ?.toLowerCase();
    if (unsupportedSchemes != null &&
        scheme != null &&
        !{'vless', 'trojan', 'hysteria2', 'hy2'}.contains(scheme)) {
      unsupportedSchemes.add(scheme);
      continue;
    }
    profiles.add(parseProfile(line, subscriptionId: subscriptionId));
  }
  if (profiles.isEmpty) {
    throw const FormatException(
      'Подписка не содержит поддерживаемых профилей.',
    );
  }
  return profiles;
}

String _jsonName(String value) {
  final name = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return name.isEmpty ? 'Конфигурация' : name;
}
