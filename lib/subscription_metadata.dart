import 'profiles.dart';

String decodeHeaderText(String? value) {
  if (value == null) return '';
  var text = value.trim();
  if (text.toLowerCase().startsWith('base64:')) {
    try {
      text = decodeBase64(text.substring(7));
    } on FormatException {
      return '';
    }
  }
  return text
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
      .trim();
}

String? safeWebUrl(String? text) {
  final uri = Uri.tryParse(text ?? '');
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri.toString()
      : null;
}

String formatBytes(int value) {
  const units = ['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ'];
  var number = value.toDouble();
  var unit = 0;
  while (number >= 1024 && unit < units.length - 1) {
    number /= 1024;
    unit++;
  }
  return '${number.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatExpiry(int seconds) {
  if (seconds <= 0) return 'Без срока';
  if (seconds > 253402300799) return 'Дата не указана';
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
}

class SubscriptionMetadata {
  const SubscriptionMetadata({
    this.title = '',
    this.announce = '',
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
    this.updateHours,
    this.supportUrl,
    this.webUrl,
    this.hwidActive = false,
    this.trafficKnown = false,
    this.quotaKnown = false,
    this.expiryKnown = false,
  });
  final String title;
  final String announce;
  final int upload, download, total, expire;
  final int? updateHours;
  final String? supportUrl, webUrl;
  final bool hwidActive;
  final bool trafficKnown, quotaKnown, expiryKnown;
  int get used => upload + download;
  double? get fraction => trafficKnown && quotaKnown && total > 0
      ? (used / total).clamp(0, 1)
      : null;

  factory SubscriptionMetadata.fromHeaders(Map<String, String> source) {
    final headers = {
      for (final entry in source.entries) entry.key.toLowerCase(): entry.value,
    };
    bool flag(String name) => headers[name]?.toLowerCase() == 'true';
    if (flag('x-hwid-max-devices-reached') || flag('x-hwid-limit')) {
      throw const FormatException(
        'Достигнут лимит устройств подписки. Освободите устройство у провайдера.',
      );
    }
    if (flag('x-hwid-not-supported')) {
      throw const FormatException(
        'Подписка требует HWID. Включите идентификатор устройства в настройках.',
      );
    }
    final info = <String, int>{};
    for (final pair in (headers['subscription-userinfo'] ?? '').split(';')) {
      final parts = pair.trim().split('=');
      if (parts.length != 2) continue;
      final number = int.tryParse(parts[1].trim());
      if (number != null && number >= 0) {
        info[parts[0].trim().toLowerCase()] = number;
      }
    }
    final hours = int.tryParse(headers['profile-update-interval'] ?? '');
    return SubscriptionMetadata(
      title: decodeHeaderText(headers['profile-title']),
      announce: decodeHeaderText(headers['announce']),
      upload: info['upload'] ?? 0,
      download: info['download'] ?? 0,
      total: info['total'] ?? 0,
      expire: info['expire'] ?? 0,
      updateHours: hours != null && hours > 0 && hours <= 720 ? hours : null,
      supportUrl: safeWebUrl(headers['support-url']),
      webUrl: safeWebUrl(headers['profile-web-page-url']),
      hwidActive: flag('x-hwid-active'),
      trafficKnown: info.containsKey('upload') || info.containsKey('download'),
      quotaKnown: info.containsKey('total'),
      expiryKnown: info.containsKey('expire'),
    );
  }

  factory SubscriptionMetadata.fromJson(Map<String, dynamic> value) =>
      SubscriptionMetadata(
        title: value['title'] as String? ?? '',
        announce: value['announce'] as String? ?? '',
        upload: value['upload'] as int? ?? 0,
        download: value['download'] as int? ?? 0,
        total: value['total'] as int? ?? 0,
        expire: value['expire'] as int? ?? 0,
        updateHours: value['updateHours'] as int?,
        supportUrl: safeWebUrl(value['supportUrl'] as String?),
        webUrl: safeWebUrl(value['webUrl'] as String?),
        hwidActive: value['hwidActive'] == true,
        trafficKnown: value['trafficKnown'] == true,
        quotaKnown: value['quotaKnown'] == true,
        expiryKnown: value['expiryKnown'] == true,
      );

  Map<String, dynamic> toJson() => {
    'title': title,
    'announce': announce,
    'upload': upload,
    'download': download,
    'total': total,
    'expire': expire,
    'updateHours': updateHours,
    'supportUrl': supportUrl,
    'webUrl': webUrl,
    'hwidActive': hwidActive,
    'trafficKnown': trafficKnown,
    'quotaKnown': quotaKnown,
    'expiryKnown': expiryKnown,
  };
}
