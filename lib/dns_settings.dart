import 'dart:io';

enum DnsMode {
  system('Системный DNS'),
  udp('DNS · UDP'),
  tcp('DNS · TCP'),
  doh('DoH · HTTPS'),
  dot('DoT · TLS');

  const DnsMode(this.label);
  final String label;
}

class DnsSettings {
  const DnsSettings({this.mode = DnsMode.system, this.address = ''});
  final DnsMode mode;
  final String address;

  DnsSettings validated() {
    if (mode == DnsMode.system) return const DnsSettings();
    final value = address.trim();
    if (value.isEmpty ||
        RegExp(r'[\s\x00-\x1f\x7f]|%(?![0-9a-fA-F]{2})').hasMatch(value)) {
      throw const FormatException('Укажите адрес DNS без пробелов.');
    }
    Uri uri;
    try {
      uri = Uri.parse(mode == DnsMode.doh ? value : 'dns://$value');
    } on FormatException {
      throw const FormatException('Некорректный адрес DNS.');
    }
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException(
        'Нужен DNS-адрес без логина, query-параметров и фрагмента.',
      );
    }
    if (mode == DnsMode.doh) {
      if (uri.scheme != 'https') {
        throw const FormatException('Для DoH нужна HTTPS-ссылка.');
      }
    } else if (uri.path.isNotEmpty) {
      throw const FormatException(
        'Укажите IP или имя DNS-сервера, при необходимости с портом.',
      );
    }
    if (!RegExp(r'^[a-zA-Z0-9.:-]+$').hasMatch(uri.host)) {
      throw const FormatException('Укажите IP или DNS-имя в ASCII-формате.');
    }
    if (InternetAddress.tryParse(uri.host) == null) {
      final host = uri.host.endsWith('.')
          ? uri.host.substring(0, uri.host.length - 1)
          : uri.host;
      if (host.length > 253 ||
          host.contains(':') ||
          RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host) ||
          host
              .split('.')
              .any(
                (part) =>
                    !RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$')
                        .hasMatch(part),
              )) {
        throw const FormatException('Некорректное IP или DNS-имя сервера.');
      }
    }
    return DnsSettings(mode: mode, address: value);
  }

  Map<String, dynamic> toJson() => {'mode': mode.name, 'address': address};

  factory DnsSettings.fromJson(Object? value) {
    if (value == null) return const DnsSettings();
    if (value is! Map) {
      throw const FormatException('Некорректные настройки DNS.');
    }
    final mode = DnsMode.values
        .where((item) => item.name == value['mode'])
        .firstOrNull;
    if (mode == null ||
        (value['address'] != null && value['address'] is! String)) {
      throw const FormatException('Некорректные настройки DNS.');
    }
    return DnsSettings(
      mode: mode,
      address: value['address'] as String? ?? '',
    ).validated();
  }
}
