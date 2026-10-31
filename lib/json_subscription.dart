typedef JsonProfileData = ({String name, List<Map<String, dynamic>> outbounds});

class _Unsupported implements Exception {
  const _Unsupported(this.reason);
  final String reason;
}

Never _invalid() =>
    throw const FormatException('Некорректная конфигурация JSON подписки.');
Map<String, dynamic> _map(Object? value) => value == null
    ? {}
    : value is Map<String, dynamic>
    ? value
    : _invalid();
String _string(Object? value, [String fallback = '']) => value == null
    ? fallback
    : value is String
    ? value
    : _invalid();
List<dynamic> _list(Object? value) => value == null
    ? []
    : value is List
    ? value
    : _invalid();
bool _notEmpty(Object? value) =>
    value != null &&
    value != '' &&
    value != false &&
    (value is! List || value.isNotEmpty) &&
    (value is! Map || value.isNotEmpty);

/// Из полного конфига берётся основной прокси и только достижимая цепочка detour.
/// Серверные inbounds, DNS и правила маршрутизации заменяются политикой клиента.
List<JsonProfileData> importJsonSubscription(
  Object? document, {
  List<String>? unsupported,
  List<String>? warnings,
}) {
  final entries = document is List ? document : [document];
  final result = <JsonProfileData>[];
  for (final value in entries) {
    final root = _map(value);
    if (root.isEmpty) _invalid();
    final full = root.containsKey('outbounds');
    final nodes = full ? _list(root['outbounds']).map(_map).toList() : [root];
    const helpers = {
      'freedom',
      'blackhole',
      'dns',
      'direct',
      'block',
      'reject',
      'selector',
      'urltest',
    };
    final main = full
        ? nodes.indexWhere(
            (node) => !helpers.contains(node['protocol'] ?? node['type']),
          )
        : 0;
    if (main < 0) continue;
    try {
      final notices = <String>[];
      final originalTags = <String, int>{};
      for (var i = 0; i < nodes.length; i++) {
        final tag = _string(nodes[i]['tag']);
        if (tag.isNotEmpty && originalTags.containsKey(tag)) _invalid();
        if (tag.isNotEmpty) originalTags[tag] = i;
      }
      final converted = <int, Map<String, dynamic>>{};
      final visiting = <int>{};
      String visit(int index) {
        if (visiting.contains(index)) _invalid();
        if (converted.containsKey(index)) {
          return converted[index]!['tag'] as String;
        }
        if (converted.length >= 32) {
          throw const _Unsupported('JSON: слишком длинная цепочка');
        }
        final node = nodes[index];
        final outbound = node['type'] is String
            ? Map<String, dynamic>.from(node)
            : _xray(node, notices);
        final tag = converted.isEmpty ? 'proxy' : 'chain-${converted.length}';
        outbound['tag'] = tag;
        converted[index] = outbound;
        visiting.add(index);
        final stream = _map(node['streamSettings']);
        final legacy = _string(_map(node['proxySettings'])['tag']);
        final dialer = _string(_map(stream['sockopt'])['dialerProxy']);
        final native = _string(node['detour']);
        final refs = {legacy, dialer, native}..remove('');
        if (refs.length > 1) {
          throw const _Unsupported('JSON: конфликт цепочек прокси');
        }
        if (refs.isNotEmpty) {
          final target = originalTags[refs.single];
          if (target == null) _invalid();
          outbound['detour'] = visit(target);
        }
        visiting.remove(index);
        return tag;
      }

      visit(main);
      result.add((
        name: _string(root['remarks'] ?? root['tag'], 'Конфигурация'),
        outbounds: converted.values.toList(),
      ));
      for (final notice in notices.toSet()) {
        if (warnings != null && !warnings.contains(notice)) {
          warnings.add(notice);
        }
      }
    } on _Unsupported catch (failure) {
      if (unsupported == null) throw FormatException(failure.reason);
      unsupported.add(failure.reason);
    }
  }
  if (result.isEmpty) {
    throw const FormatException(
      'JSON подписки не содержит поддерживаемых профилей.',
    );
  }
  return result;
}

Map<String, dynamic> _xray(Map<String, dynamic> node, List<String> notices) {
  final protocol = _string(node['protocol']);
  if (protocol.isEmpty) _invalid();
  final settings = _map(node['settings']);
  if (protocol == 'freedom') {
    if ([
      'fragment',
      'noises',
      'redirect',
    ].any((key) => _notEmpty(settings[key]))) {
      throw const _Unsupported('Xray: специальные параметры Freedom');
    }
    return {'type': 'direct'};
  }
  if (!{'vless', 'vmess', 'trojan', 'shadowsocks'}.contains(protocol)) {
    throw const _Unsupported('Xray: неподдерживаемый протокол');
  }
  final servers = _list(
    settings[{'vless', 'vmess'}.contains(protocol) ? 'vnext' : 'servers'],
  );
  if (servers.length != 1) {
    throw const _Unsupported('Xray: несколько серверов в одном outbound');
  }
  final server = _map(servers.single);
  final host = _string(server['address']).trim();
  final port = server['port'];
  if (host.isEmpty ||
      host.length > 253 ||
      port is! int ||
      port < 1 ||
      port > 65535) {
    _invalid();
  }
  final result = <String, dynamic>{
    'type': protocol,
    'server': host,
    'server_port': port,
  };
  if ({'vless', 'vmess'}.contains(protocol)) {
    final users = _list(server['users']);
    if (users.length != 1) {
      throw const _Unsupported(
        'Xray: несколько пользователей в одном outbound',
      );
    }
    final user = _map(users.single);
    final id = _string(user['id']);
    if (!RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
        .hasMatch(id)) {
      _invalid();
    }
    result['uuid'] = id;
    result['packet_encoding'] = 'xudp';
    if (protocol == 'vless') {
      if (_notEmpty(user['flow'])) result['flow'] = _string(user['flow']);
      if (_notEmpty(user['encryption']) && user['encryption'] != 'none') {
        result['encryption'] = _string(user['encryption']);
      }
    } else {
      if ((user['alterId'] ?? 0) != 0) {
        throw const _Unsupported('Xray: устаревший VMess alterId');
      }
      result['security'] = _string(user['security'], 'auto');
    }
  } else {
    final password = _string(server['password']);
    if (password.isEmpty) _invalid();
    result['password'] = password;
    if (protocol == 'shadowsocks') {
      final method = _string(server['method']);
      if (method.isEmpty) _invalid();
      result['method'] = method;
    }
  }
  final stream = _map(node['streamSettings']);
  final mask = _map(stream['finalmask']);
  final tcpMasks = _list(mask['tcp']);
  final fragment = tcpMasks.isNotEmpty;
  if (_notEmpty(mask['udp']) ||
      _notEmpty(mask['quicParams']) ||
      tcpMasks.any(
        (value) =>
            _map(value)['type'] != 'fragment' ||
            _map(_map(value)['settings'])['packets'] != 'tlshello',
      )) {
    throw const _Unsupported('Xray: маскирование транспорта');
  }
  final security = _string(stream['security'], 'none');
  if (security != 'none' && security != '') {
    if (!{'tls', 'reality'}.contains(security)) {
      throw const _Unsupported('Xray: неподдерживаемый TLS');
    }
    final tls = _map(
      stream[security == 'reality' ? 'realitySettings' : 'tlsSettings'],
    );
    if ([
      'certificates',
      'pinnedPeerCertSha256',
      'echConfigList',
    ].any((key) => _notEmpty(tls[key]))) {
      throw const _Unsupported('Xray: нестандартные сертификаты или ECH');
    }
    final options = <String, dynamic>{
      'enabled': true,
      'server_name': _string(tls['serverName'], host),
    };
    if (fragment) {
      options['fragment'] = true;
      notices.add(
        'Фрагментация TLS адаптирована к Tachyon: размер фрагментов и задержку задаёт ядро.',
      );
    }
    if (tls['allowInsecure'] == true) options['insecure'] = true;
    if (_notEmpty(tls['alpn'])) {
      options['alpn'] = _list(tls['alpn']).map((v) => _string(v)).toList();
    }
    for (final pair in [
      ('minVersion', 'min_version'),
      ('maxVersion', 'max_version'),
    ]) {
      if (_notEmpty(tls[pair.$1])) options[pair.$2] = _string(tls[pair.$1]);
    }
    final fingerprint = _string(
      tls['fingerprint'],
      security == 'reality' ? 'chrome' : '',
    );
    if (fingerprint.isNotEmpty) {
      options['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (security == 'reality') {
      final publicKey = _string(tls['publicKey'] ?? tls['password']);
      if (publicKey.isEmpty) _invalid();
      options['reality'] = {
        'enabled': true,
        'public_key': publicKey,
        'short_id': _string(tls['shortId']),
      };
    }
    result['tls'] = options;
  }
  if (fragment && result['tls'] == null) {
    throw const _Unsupported('Xray: фрагментация без TLS');
  }
  final transport = _transport(stream);
  if (transport != null) result['transport'] = transport;
  return result;
}

Map<String, dynamic>? _transport(Map<String, dynamic> stream) {
  final network = _string(stream['network'] ?? stream['method'], 'tcp');
  if ({'tcp', 'raw', ''}.contains(network)) {
    final options = _map(stream['rawSettings'] ?? stream['tcpSettings']);
    if (!{'', 'none'}.contains(_string(_map(options['header'])['type']))) {
      throw const _Unsupported('Xray: TCP HTTP-заголовки');
    }
    return null;
  }
  final kind = switch (network) {
    'websocket' => 'ws',
    'splithttp' => 'xhttp',
    'h2' => 'http',
    _ => network,
  };
  if (!{'ws', 'grpc', 'httpupgrade', 'http', 'xhttp'}.contains(kind)) {
    throw const _Unsupported('Xray: неподдерживаемый транспорт');
  }
  final options = _map(
    stream['${network}Settings'] ?? stream['${kind}Settings'],
  );
  final result = <String, dynamic>{'type': kind};
  if (kind == 'grpc') {
    if (options['multiMode'] == true) {
      throw const _Unsupported('Xray: gRPC multiMode');
    }
    result['service_name'] = _string(options['serviceName']);
    return result;
  }
  if (kind == 'xhttp') return _xhttp(options);
  result['path'] = _string(options['path'], '/');
  final host = options['host'];
  if (kind == 'http' && _notEmpty(host)) {
    result['host'] = host is String
        ? [host]
        : _list(host).map((v) => _string(v)).toList();
  } else if (kind != 'ws' && _notEmpty(host)) {
    result['host'] = _string(host);
  }
  final headers = Map<String, dynamic>.from(_map(options['headers']));
  if (kind == 'ws' && _notEmpty(host)) headers['Host'] = _string(host);
  if (headers.isNotEmpty) result['headers'] = headers;

  return result;
}

Map<String, dynamic> _xhttp(Map<String, dynamic> options) {
  final extra = options['extra'] == null ? options : _map(options['extra']);
  final source = {for (final e in extra.entries) e.key.toLowerCase(): e.value};
  if (_notEmpty(source['downloadsettings'])) {
    throw const _Unsupported('Xray: раздельный канал загрузки XHTTP');
  }
  final result = <String, dynamic>{
    'type': 'xhttp',
    'path': _string(options['path'], '/'),
    'mode': _string(options['mode'], 'auto'),
  };
  if (_notEmpty(options['host'])) result['host'] = _string(options['host']);
  final headers = _map(source['headers']);
  if (headers.isNotEmpty) {
    result['headers'] = Map<String, dynamic>.from(headers);
  }
  const fields = {
    'xPaddingBytes': 'x_padding_bytes',
    'xPaddingObfsMode': 'x_padding_obfs_mode',
    'xPaddingKey': 'x_padding_key',
    'xPaddingHeader': 'x_padding_header',
    'xPaddingPlacement': 'x_padding_placement',
    'xPaddingMethod': 'x_padding_method',
    'noGRPCHeader': 'no_grpc_header',
    'noSSEHeader': 'no_sse_header',
    'scMaxEachPostBytes': 'sc_max_each_post_bytes',
    'scMinPostsIntervalMs': 'sc_min_posts_interval_ms',
    'scStreamUpServerSecs': 'sc_stream_up_server_secs',
    'scMaxBufferedPosts': 'sc_max_buffered_posts',
    'serverMaxHeaderBytes': 'server_max_header_bytes',
    'uplinkHTTPMethod': 'uplink_http_method',
    'sessionIDPlacement': 'session_placement',
    'sessionIDKey': 'session_key',
    // Эти совместимые имена сохраняют семантику Xray: без таблицы
    // sessionIDLength не включает пользовательский генератор идентификаторов.
    'sessionIDTable': 'session_id_table',
    'sessionIDLength': 'session_id_length',
    'seqPlacement': 'seq_placement',
    'seqKey': 'seq_key',
    'uplinkDataPlacement': 'uplink_data_placement',
    'uplinkDataKey': 'uplink_data_key',
    'uplinkChunkSize': 'uplink_chunk_size',
  };
  for (final field in fields.entries) {
    final value = source[field.key.toLowerCase()];
    if (value != null) result[field.value] = value;
  }
  // Старые имена используются, только если нет актуального sessionID*.
  for (final pair in [
    ('sessionPlacement', 'session_placement'),
    ('sessionKey', 'session_key'),
  ]) {
    final value = source[pair.$1.toLowerCase()];
    if (value != null) result.putIfAbsent(pair.$2, () => value);
  }
  if (source['xmux'] != null) {
    const fields = {
      'maxconcurrency': 'max_concurrency',
      'maxconnections': 'max_connections',
      'cmaxreusetimes': 'c_max_reuse_times',
      'hmaxrequesttimes': 'h_max_request_times',
      'hmaxreusablesecs': 'h_max_reusable_secs',
      'hkeepaliveperiod': 'h_keep_alive_period',
    };
    final xmux = <String, dynamic>{};
    for (final option in _map(source['xmux']).entries) {
      final name = fields[option.key.toLowerCase()];
      // Отключённый устаревший лимит не влияет на соединение.
      if (option.key.toLowerCase() == 'cmaxlifetimems' && option.value == 0) {
        continue;
      }
      if (name == null) {
        throw const _Unsupported('Xray: неизвестный параметр XMUX');
      }
      if (option.value != null) xmux[name] = option.value;
    }
    result['xmux'] = xmux;
  }
  final known = {
    ...fields.keys.map((key) => key.toLowerCase()),
    'host',
    'path',
    'mode',
    'headers',
    'xmux',
    'sessionkey',
    'sessionplacement',
    'extra',
    'downloadsettings',
  };
  if (source.entries.any(
    (entry) => !known.contains(entry.key) && _notEmpty(entry.value),
  )) {
    throw const _Unsupported('Xray: расширенные параметры XHTTP');
  }
  return result;
}
