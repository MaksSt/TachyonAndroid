import 'dart:convert';
import 'dart:io';

class HttpPayload {
  const HttpPayload(this.status, this.body, this.headers);
  final int status;
  final String body;
  final Map<String, String> headers;
}

typedef HttpFetch = Future<HttpPayload> Function(
  Uri uri,
  Map<String, String> headers,
);

Future<HttpPayload> fetchHttps(Uri uri, Map<String, String> headers) async {
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Нужна HTTPS-ссылка без логина и пароля в адресе.',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    // Не передаём HWID и секретную ссылку на другой адрес автоматически.
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 20));
    const maximum = 4 * 1024 * 1024;
    if (response.contentLength > maximum) {
      throw const FormatException('Ответ сервера больше 4 MiB.');
    }
    final bytes = <int>[];
    await response
        .forEach((part) {
          if (bytes.length + part.length > maximum) {
            throw const FormatException('Ответ сервера больше 4 MiB.');
          }
          bytes.addAll(part);
        })
        .timeout(const Duration(seconds: 20));
    final values = <String, String>{};
    response.headers.forEach((name, value) {
      values[name.toLowerCase()] = value.join(',');
    });
    return HttpPayload(response.statusCode, utf8.decode(bytes), values);
  } finally {
    client.close(force: true);
  }
}
