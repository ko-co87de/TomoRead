import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../database/app_database.dart';

/// WebDAV endpoint settings. Non-secret values live in `app_settings`;
/// the password is kept exclusively in platform secure storage.
class WebDavConfig {
  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.folder = defaultFolder,
    this.passwordStored = false,
  });

  static const String defaultFolder = 'tomoread-sync';

  final String url;
  final String username;
  final String folder;
  final bool passwordStored;

  bool get isConfigured => url.trim().isNotEmpty;

  Uri? get baseUri {
    final text = url.trim();
    if (text.isEmpty) return null;
    final parsed = Uri.tryParse(text);
    if (parsed == null || !parsed.hasScheme) return null;
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
    if (parsed.host.isEmpty) return null;
    return parsed;
  }

  /// Normalizes the remote folder to `segment/segment` without leading or
  /// trailing slashes. Returns `null` when the input is unsafe.
  static String? normalizeFolder(String raw) {
    final segments =
        raw
            .trim()
            .split('/')
            .map((segment) => segment.trim())
            .where((segment) => segment.isNotEmpty)
            .toList(growable: false);
    if (segments.isEmpty) return defaultFolder;
    for (final segment in segments) {
      if (segment == '.' || segment == '..') return null;
      if (segment.contains('\\')) return null;
    }
    return segments.join('/');
  }
}

class WebDavConfigStore {
  WebDavConfigStore({
    required AppDatabase database,
    FlutterSecureStorage? secureStorage,
  }) : _database = database,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const String passwordSecureKey = 'tomoread.webdav.password';
  static const String _urlKey = 'webdav.url';
  static const String _usernameKey = 'webdav.username';
  static const String _folderKey = 'webdav.folder';

  final AppDatabase _database;
  final FlutterSecureStorage _secureStorage;

  Future<WebDavConfig> load() async {
    final database = await _database.database;
    final rows = await database.query(
      'app_settings',
      columns: ['setting_key', 'setting_value'],
      where: 'setting_key IN (?, ?, ?)',
      whereArgs: [_urlKey, _usernameKey, _folderKey],
    );
    final values = <String, String>{
      for (final row in rows)
        row['setting_key']! as String: row['setting_value']! as String,
    };
    final storedFolder = WebDavConfig.normalizeFolder(
      values[_folderKey] ?? '',
    );
    return WebDavConfig(
      url: values[_urlKey] ?? '',
      username: values[_usernameKey] ?? '',
      folder: storedFolder ?? WebDavConfig.defaultFolder,
      passwordStored: await hasPassword(),
    );
  }

  Future<void> save(WebDavConfig config) async {
    final folder =
        WebDavConfig.normalizeFolder(config.folder) ??
        WebDavConfig.defaultFolder;
    final database = await _database.database;
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final entry in <String, String>{
      _urlKey: config.url.trim(),
      _usernameKey: config.username.trim(),
      _folderKey: folder,
    }.entries) {
      await database.insert(
        'app_settings',
        {
          'setting_key': entry.key,
          'setting_value': entry.value,
          'updated_at': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<String?> readPassword() =>
      _secureStorage.read(key: passwordSecureKey);

  Future<void> writePassword(String value) =>
      _secureStorage.write(key: passwordSecureKey, value: value);

  Future<void> deletePassword() =>
      _secureStorage.delete(key: passwordSecureKey);

  Future<bool> hasPassword() async =>
      await _secureStorage.read(key: passwordSecureKey) != null;
}
