import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class WebDavException implements Exception {
  WebDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

class WebDavEntry {
  const WebDavEntry({
    required this.name,
    required this.etag,
    required this.isCollection,
  });

  /// Literal file name as stored on the server (already URL-decoded once).
  final String name;
  final String? etag;
  final bool isCollection;
}

/// Minimal WebDAV client covering the operations TomoRead sync needs:
/// `PROPFIND` listing, `GET`, `PUT`, `MKCOL` and a depth-0 probe.
class WebDavClient {
  WebDavClient({
    required Uri baseUrl,
    this.username,
    this.password,
    http.Client? httpClient,
  }) : baseUrl = _normalize(baseUrl),
       _httpClient = httpClient ?? http.Client();

  final Uri baseUrl;
  final String? username;
  final String? password;
  final http.Client _httpClient;

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:getetag/><d:getlastmodified/><d:getcontentlength/>'
      '<d:resourcetype/>'
      '</d:prop></d:propfind>';

  static Uri _normalize(Uri url) {
    final text = url.toString();
    return text.endsWith('/') ? url : Uri.parse('$text/');
  }

  Map<String, String> get _authHeaders {
    final user = username;
    final pass = password;
    if (user == null && pass == null) return const {};
    final token = base64Encode(utf8.encode('${user ?? ''}:${pass ?? ''}'));
    return {'authorization': 'Basic $token'};
  }

  Uri _resolve(String relativePath) {
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return baseUrl.resolve(segments);
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    request.headers.addAll(_authHeaders);
    final streamed = await _httpClient.send(request);
    return http.Response.fromStream(streamed);
  }

  void _ensureStatus(http.Response response, Set<int> expected) {
    if (expected.contains(response.statusCode)) return;
    final message = switch (response.statusCode) {
      401 =>
        'رفض الخادم بيانات الاعتماد. تحقق من اسم المستخدم وكلمة المرور.',
      403 => 'ممنوع. تحقق من صلاحيات الحساب على الخادم.',
      404 => 'المسار غير موجود على الخادم.',
      _ => 'فشل طلب WebDAV.',
    };
    throw WebDavException(message, statusCode: response.statusCode);
  }

  /// Verify the endpoint is reachable and credentials are accepted.
  Future<void> ping() async {
    final request =
        http.Request('PROPFIND', baseUrl)
          ..headers['depth'] = '0'
          ..headers['content-type'] = 'application/xml; charset=utf-8'
          ..body = _propfindBody;
    final response = await _send(request);
    _ensureStatus(response, const {200, 207});
  }

  /// Create `relativePath` and every missing parent collection.
  Future<void> ensureCollection(String relativePath) async {
    var current = '';
    for (final segment
        in relativePath.split('/').where((value) => value.isNotEmpty)) {
      current = current.isEmpty ? segment : '$current/$segment';
      await _mkcol(current);
    }
  }

  Future<void> _mkcol(String relativePath) async {
    final response = await _send(http.Request('MKCOL', _resolve(relativePath)));
    final status = response.statusCode;
    if (status == 201 || status == 200 || status == 405 || status == 301) {
      return;
    }
    _ensureStatus(response, const {201});
  }

  /// List the direct children of `relativePath`.
  Future<List<WebDavEntry>> list(String relativePath) async {
    final request =
        http.Request('PROPFIND', _resolve(relativePath))
          ..headers['depth'] = '1'
          ..headers['content-type'] = 'application/xml; charset=utf-8'
          ..body = _propfindBody;
    final response = await _send(request);
    _ensureStatus(response, const {207, 200});
    final directoryPath = Uri.decodeComponent(_resolve(relativePath).path);
    final document = XmlDocument.parse(response.body);
    final entries = <WebDavEntry>[];
    for (final node in document.findAllElements(
      'response',
      namespace: '*',
    )) {
      final href = node.getElement('href', namespace: '*')?.innerText;
      if (href == null || href.isEmpty) continue;
      final path = Uri.tryParse(href)?.path;
      if (path == null || path.isEmpty) continue;
      final decodedPath = Uri.decodeComponent(path);
      if (decodedPath == directoryPath || decodedPath == '$directoryPath/') {
        continue;
      }
      final trimmed = decodedPath.endsWith('/')
          ? decodedPath.substring(0, decodedPath.length - 1)
          : decodedPath;
      final name = trimmed.substring(trimmed.lastIndexOf('/') + 1);
      if (name.isEmpty) continue;
      final isCollection = node
          .findAllElements('resourcetype', namespace: '*')
          .any(
            (type) => type.getElement('collection', namespace: '*') != null,
          );
      final etag = node
          .findAllElements('getetag', namespace: '*')
          .map((element) => element.innerText.trim())
          .firstWhere((value) => value.isNotEmpty, orElse: () => '');
      entries.add(
        WebDavEntry(
          name: name,
          etag: etag.isEmpty ? null : etag,
          isCollection: isCollection,
        ),
      );
    }
    return entries;
  }

  /// Fetch a resource. Returns `null` when the server reports 404.
  Future<List<int>?> get(String relativePath) async {
    final response = await _send(http.Request('GET', _resolve(relativePath)));
    if (response.statusCode == 404) return null;
    _ensureStatus(response, const {200});
    return response.bodyBytes;
  }

  /// Upload a resource. Returns the server ETag when one is provided.
  Future<String?> put(String relativePath, List<int> body) async {
    final request =
        http.Request('PUT', _resolve(relativePath))
          ..headers['content-type'] = 'application/json; charset=utf-8'
          ..bodyBytes = body;
    final response = await _send(request);
    if (response.statusCode == 409) {
      throw WebDavException(
        'المجلد الأب غير موجود على الخادم.',
        statusCode: 409,
      );
    }
    _ensureStatus(response, const {200, 201, 204});
    final etag = response.headers['etag'];
    return (etag == null || etag.isEmpty) ? null : etag;
  }

  /// Remove a resource. Missing files are treated as already removed.
  Future<void> delete(String relativePath) async {
    final response = await _send(
      http.Request('DELETE', _resolve(relativePath)),
    );
    _ensureStatus(response, const {200, 204, 404});
  }
}
