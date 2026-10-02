import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tomoread/data/services/webdav_client.dart';

void main() {
  test('list parses a 207 multistatus and skips the collection itself', () async {
    late http.Request captured;
    final client = WebDavClient(
      baseUrl: Uri.parse('https://dav.test/remote/'),
      username: 'user',
      password: 'secret',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          '<?xml version="1.0" encoding="utf-8"?>'
          '<d:multistatus xmlns:d="DAV:">'
          '<d:response><d:href>/remote/tomoread-sync/</d:href>'
          '<d:propstat><d:prop><d:getetag>"self"</d:getetag></d:prop>'
          '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
          '<d:response><d:href>/remote/tomoread-sync/bookmark_a.json</d:href>'
          '<d:propstat><d:prop><d:getetag>"e1"</d:getetag>'
          '<d:resourcetype/></d:prop>'
          '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
          '<d:response><d:href>/remote/tomoread-sync/sub%20dir/</d:href>'
          '<d:propstat><d:prop><d:getetag>"e2"</d:getetag>'
          '<d:resourcetype><d:collection/></d:resourcetype></d:prop>'
          '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
          '</d:multistatus>',
          207,
        );
      }),
    );

    final entries = await client.list('tomoread-sync');

    expect(captured.method, 'PROPFIND');
    expect(captured.headers['depth'], '1');
    expect(
      captured.headers['authorization'],
      'Basic ${base64Encode(utf8.encode('user:secret'))}',
    );
    expect(captured.url.toString(), 'https://dav.test/remote/tomoread-sync');
    expect(entries, hasLength(2));
    expect(entries.first.name, 'bookmark_a.json');
    expect(entries.first.etag, '"e1"');
    expect(entries.first.isCollection, isFalse);
    expect(entries.last.name, 'sub dir');
    expect(entries.last.etag, '"e2"');
    expect(entries.last.isCollection, isTrue);
  });

  test('put encodes the path, sends the body and returns the server etag',
      () async {
    late http.Request captured;
    final client = WebDavClient(
      baseUrl: Uri.parse('https://dav.test/remote/'),
      username: 'u',
      password: 'p',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('', 201, headers: {'etag': '"v1"'});
      }),
    );

    final etag = await client.put(
      'tomoread-sync/annotation a.json',
      utf8.encode('{}'),
    );

    expect(etag, '"v1"');
    expect(captured.method, 'PUT');
    expect(
      captured.url.toString(),
      'https://dav.test/remote/tomoread-sync/annotation%20a.json',
    );
    expect(
      captured.headers['authorization'],
      'Basic ${base64Encode(utf8.encode('u:p'))}',
    );
    expect(captured.body, '{}');
  });

  test('get returns null when the server reports 404', () async {
    final client = WebDavClient(
      baseUrl: Uri.parse('https://dav.test/remote/'),
      httpClient: MockClient((request) async => http.Response('', 404)),
    );

    expect(await client.get('tomoread-sync/missing.json'), isNull);
  });
}
