import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tomoread/data/database/app_database.dart';
import 'package:tomoread/data/repositories/sync_repository.dart';
import 'package:tomoread/data/services/webdav_client.dart';
import 'package:tomoread/data/services/webdav_sync_service.dart';

/// Minimal in-memory WebDAV server: MAP of full paths to bodies with etags.
class _FakeWebDavServer {
  final Map<String, String> files = <String, String>{};
  final Map<String, String> etags = <String, String>{};
  var _revision = 0;

  late final MockClient mockClient = MockClient(_handle);

  String _item(String href, {String? etag, bool collection = false}) {
    final etagXml = etag == null ? '' : '<d:getetag>$etag</d:getetag>';
    final typeXml = collection
        ? '<d:resourcetype><d:collection/></d:resourcetype>'
        : '<d:resourcetype/>';
    return '<d:response><d:href>$href</d:href>'
        '<d:propstat><d:prop>$etagXml$typeXml</d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  }

  http.Response _multistatus(String body) => http.Response(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">$body</d:multistatus>',
    207,
    headers: {'content-type': 'application/xml; charset=utf-8'},
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    switch (request.method) {
      case 'PROPFIND':
        final depth = request.headers['depth'];
        if (depth == '0') {
          return _multistatus(_item('$path/', collection: true));
        }
        final dir = path.endsWith('/')
            ? path.substring(0, path.length - 1)
            : path;
        final items = <String>[_item('$dir/', collection: true)];
        for (final entry in files.entries) {
          final parent = entry.key.substring(0, entry.key.lastIndexOf('/'));
          if (parent == dir) {
            items.add(_item(entry.key, etag: etags[entry.key]));
          }
        }
        return _multistatus(items.join());
      case 'GET':
        final body = files[path];
        if (body == null) return http.Response('', 404);
        return http.Response(
          utf8.encode(body),
          200,
          headers: {'etag': etags[path] ?? ''},
        );
      case 'PUT':
        final etag = '"${++_revision}"';
        files[path] = request.body;
        etags[path] = etag;
        return http.Response('', 201, headers: {'etag': etag});
      case 'DELETE':
        if (files.remove(path) == null) return http.Response('', 404);
        etags.remove(path);
        return http.Response('', 204);
      case 'MKCOL':
        return http.Response('', 201);
      default:
        return http.Response('', 405);
    }
  }
}

void main() {
  late AppDatabase databaseA;
  late AppDatabase databaseB;
  late SyncRepository repositoryA;
  late SyncRepository repositoryB;
  late _FakeWebDavServer server;
  late WebDavSyncService serviceA;
  late WebDavSyncService serviceB;

  Future<WebDavSyncResult> runSync(WebDavSyncService service) => service.sync(
    onProgress: (progress) {},
    isCancelled: () => false,
  );

  setUp(() {
    server = _FakeWebDavServer();
    databaseA = AppDatabase.inMemory();
    databaseB = AppDatabase.inMemory();
    repositoryA = SyncRepository(databaseA);
    repositoryB = SyncRepository(databaseB);
    WebDavClient makeClient() => WebDavClient(
      baseUrl: Uri.parse('https://dav.test/remote/'),
      username: 'user',
      password: 'secret',
      httpClient: server.mockClient,
    );
    serviceA = WebDavSyncService(
      syncRepository: repositoryA,
      database: databaseA,
      client: makeClient(),
      deviceId: 'device-a',
      remoteFolder: 'tomoread-sync',
    );
    serviceB = WebDavSyncService(
      syncRepository: repositoryB,
      database: databaseB,
      client: makeClient(),
      deviceId: 'device-b',
      remoteFolder: 'tomoread-sync',
    );
  });

  tearDown(() async {
    await databaseA.close();
    await databaseB.close();
  });

  test('bookmarks travel from device A to device B and deletes propagate',
      () async {
    final now = DateTime.utc(2026, 9, 1, 12).millisecondsSinceEpoch;
    final rawA = await databaseA.database;
    await rawA.insert('books', {
      'id': 'book-1',
      'title': 'كتاب الاختبار',
      'created_at': now,
      'updated_at': now,
    });
    await rawA.insert('bookmarks', {
      'id': 'bm-1',
      'book_id': 'book-1',
      'locator': 'loc-1',
      'chapter_title': 'الفصل الأول',
      'label': 'مفضلة',
      'created_at': now,
      'updated_at': now,
    });

    final first = await runSync(serviceA);
    expect(first.pushed, 1);
    expect(
      server.files.keys,
      contains('/remote/tomoread-sync/bookmark_bm-1.json'),
    );

    final second = await runSync(serviceA);
    expect(second.pulled, 0, reason: 'etag cursor skips unchanged files');
    expect(second.pushed, 0, reason: 'no local changes since the last push');

    final fromB = await runSync(serviceB);
    expect(fromB.pulled, 1);
    expect(fromB.applied, 1);
    final rawB = await databaseB.database;
    final rowsB = await rawB.query('bookmarks');
    expect(rowsB, hasLength(1));
    expect(rowsB.single['id'], 'bm-1');
    expect(rowsB.single['label'], 'مفضلة');

    await rawA.delete('bookmarks', where: 'id = ?', whereArgs: ['bm-1']);
    final afterDelete = await runSync(serviceA);
    expect(afterDelete.pushed, 1);
    final remote = jsonDecode(
      server.files['/remote/tomoread-sync/bookmark_bm-1.json']!,
    ) as Map<String, Object?>;
    expect(remote['operation'], 'delete');

    final pullDelete = await runSync(serviceB);
    expect(pullDelete.pulled, 1);
    expect(await rawB.query('bookmarks'), isEmpty);
  });
}
