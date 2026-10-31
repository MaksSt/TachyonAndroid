import 'dart:convert';

import 'http_transport.dart';
import 'app_version.dart';

class CoreRelease {
  const CoreRelease(this.version, this.url, this.notes, this.androidAssets);
  final String version, url, notes;
  final List<String> androidAssets;

  static Future<CoreRelease> latest(HttpFetch fetch) async {
    final response = await fetch(
      Uri.parse(
        'https://api.github.com/repos/Dushnilin/tachyon-core/releases/latest',
      ),
      {
        'User-Agent': 'TachyonClient/$clientVersion',
        'Accept': 'application/vnd.github+json',
      },
    );
    if (response.status == 403 || response.status == 429) {
      throw const FormatException(
        'GitHub временно ограничил запросы. Повторите позже.',
      );
    }
    if (response.status != 200) {
      throw const FormatException('Не удалось проверить релиз на GitHub.');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final version = data['tag_name'] as String;
    final uri = Uri.parse(data['html_url'] as String);
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/Dushnilin/tachyon-core/releases/tag/')) {
      throw const FormatException('GitHub вернул неожиданный адрес релиза.');
    }
    final assets = (data['assets'] as List? ?? [])
        .map((item) => (item as Map)['name'] as String)
        .where((name) => name.toLowerCase().contains('android'))
        .toList();
    return CoreRelease(
      version,
      uri.toString(),
      data['body'] as String? ?? '',
      assets,
    );
  }
}
