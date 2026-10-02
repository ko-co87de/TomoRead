import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/models/sync_models.dart';
import '../database/app_database.dart';
import '../repositories/sync_repository.dart';
import 'sync_payload_codec.dart';
import 'webdav_client.dart';
import 'webdav_config_store.dart';

class SyncCancelledException implements Exception {
  const SyncCancelledException();

  @override
  String toString() => 'تم إلغاء المزامنة.';
}

enum WebDavSyncPhase { preparing, pulling, reconciling, pushing, completed }

class WebDavSyncProgress {
  const WebDavSyncProgress({
    required this.phase,
    required this.message,
    this.completed,
    this.total,
  });

  final WebDavSyncPhase phase;
  final String message;
  final int? completed;
  final int? total;

  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return ((completed ?? 0) / total).clamp(0.0, 1.0);
  }
}

class WebDavSyncResult {
  const WebDavSyncResult({
    required this.pushed,
    required this.pulled,
    required this.applied,
    required this.skipped,
    required this.conflicts,
    required this.message,
  });

  final int pushed;
  final int pulled;
  final int applied;
  final int skipped;
  final int conflicts;
  final String message;
}

/// Manual WebDAV sync built on the existing sync data contract.
///
/// One run performs: pull remote envelopes and merge them into the local
/// sync tables (applying supported entities), reconcile local entity rows
/// into sync records, then push pending changes. Progress is observable
/// through [onProgress], the run stops promptly when [isCancelled] returns
/// `true`, and the cursor is persisted after every stage so an interrupted
/// run resumes where it stopped.
class WebDavSyncService {
  WebDavSyncService({
    required this.syncRepository,
    required this.database,
    required this.client,
    required this.deviceId,
    required this.remoteFolder,
    this.deviceName = 'TomoRead',
    this.backendId = 'webdav',
    this.credentialRef = WebDavConfigStore.passwordSecureKey,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SyncRepository syncRepository;
  final AppDatabase database;
  final WebDavClient client;
  final String deviceId;
  final String remoteFolder;
  final String deviceName;
  final String backendId;
  final String credentialRef;
  final DateTime Function() _clock;

  static const SyncPayloadCodec codec = SyncPayloadCodec();

  /// Deterministic sync-state identity for a remote endpoint.
  static String remoteIdFor(WebDavClient client, String remoteFolder) {
    final identity = '${client.baseUrl}|${client.username ?? ''}|$remoteFolder';
    return sha1.convert(utf8.encode(identity)).toString();
  }

  /// Verify endpoint reachability and credentials.
  Future<void> testConnection() => client.ping();

  /// Apply an envelope to the entity tables (remote merges and locally
  /// resolved conflicts). Returns false when the row cannot be applied.
  static Future<bool> applyToEntity(
    AppDatabase database,
    SyncEnvelope envelope,
  ) async {
    if (!codec.supports(envelope.entityType)) return false;
    final db = await database.database;
    try {
      if (envelope.isDeleted) {
        await db.rawDelete(
          codec.deleteStatement(envelope.entityType),
          [envelope.entityId],
        );
        return true;
      }
      if (envelope.entityType == SyncEntityType.annotation) {
        final bookId = envelope.payload['book_id'];
        if (bookId is! String || bookId.isEmpty) return false;
        final books = await db.query(
          'books',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [bookId],
          limit: 1,
        );
        if (books.isEmpty) return false;
      }
      await db.rawInsert(
        codec.upsertStatement(envelope.entityType),
        codec.upsertArgs(envelope),
      );
      return true;
    } on Object {
      return false;
    }
  }

  String fileNameOf(SyncEnvelope envelope) =>
      '${envelope.entityType.name}_'
      '${Uri.encodeComponent(envelope.entityId)}.json';

  Future<WebDavSyncResult> sync({
    required void Function(WebDavSyncProgress progress) onProgress,
    required bool Function() isCancelled,
  }) async {
    var pushed = 0;
    var pulled = 0;
    var applied = 0;
    var skipped = 0;
    var newConflicts = 0;
    final skippedIds = <SyncEntityType, Set<String>>{};
    final remoteId = _remoteId();
    final cursor = _SyncCursor();
    var loaded = false;
    try {
      _report(
        onProgress,
        WebDavSyncPhase.preparing,
        'جارٍ تحضير المزامنة...',
      );
      _ensureNotCancelled(isCancelled);
      await syncRepository.registerDevice(
        deviceId: deviceId,
        displayName: deviceName,
      );
      await client.ensureCollection(remoteFolder);
      final previous = await syncRepository.loadState(
        backendId: backendId,
        remoteId: remoteId,
      );
      cursor.load(previous?.cursor);
      loaded = true;
      _lastSuccessAt = previous?.lastSuccessAt;
      _lastSummaryJson = previous?.lastSummaryJson;

      // Pull remote changes first so local edits are reconciled on top of
      // the freshest remote state.
      _report(
        onProgress,
        WebDavSyncPhase.pulling,
        'جارٍ فحص التغييرات على الخادم...',
      );
      final entries =
          (await client.list(remoteFolder))
              .where(
                (entry) => !entry.isCollection && entry.name.endsWith('.json'),
              )
              .toList(growable: false);
      var inspected = 0;
      for (final entry in entries) {
        _ensureNotCancelled(isCancelled);
        inspected++;
        _report(
          onProgress,
          WebDavSyncPhase.pulling,
          'فحص الملف $inspected من ${entries.length}...',
          completed: inspected,
          total: entries.length,
        );
        if (cursor.etags[entry.name] == entry.etag) continue;
        final bytes = await client.get('$remoteFolder/${entry.name}');
        if (bytes == null) {
          cursor.etags.remove(entry.name);
          continue;
        }
        if (entry.etag != null) cursor.etags[entry.name] = entry.etag!;
        pulled++;
        final SyncEnvelope envelope;
        try {
          envelope = SyncEnvelope.fromJson(
            jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
          );
        } on Object {
          continue;
        }
        final outcomes = await syncRepository.mergeBatch([envelope]);
        for (final outcome in outcomes) {
          switch (outcome.disposition) {
            case SyncMergeDisposition.applied:
              if (await applyToEntity(database, outcome.envelope)) {
                applied++;
              } else {
                skipped++;
                skippedIds
                    .putIfAbsent(outcome.envelope.entityType, () => <String>{})
                    .add(outcome.envelope.entityId);
              }
            case SyncMergeDisposition.conflict:
              newConflicts++;
            case SyncMergeDisposition.ignored:
              break;
          }
        }
      }
      await _persist(cursor, remoteId: remoteId);

      _report(
        onProgress,
        WebDavSyncPhase.reconciling,
        'تسجيل التعديلات المحلية...',
      );
      await _reconcileLocal(
        isCancelled: isCancelled,
        onProgress: onProgress,
        skippedIds: skippedIds,
      );

      _report(
        onProgress,
        WebDavSyncPhase.pushing,
        'جارٍ رفع التغييرات إلى الخادم...',
      );
      var pushedSequence = cursor.pushedSequence;
      while (true) {
        _ensureNotCancelled(isCancelled);
        final changes = await syncRepository.changesAfter(
          pushedSequence,
          limit: 200,
        );
        if (changes.isEmpty) break;
        for (final change in changes) {
          _ensureNotCancelled(isCancelled);
          final envelope = change.envelope;
          final fileName = fileNameOf(envelope);
          final etag = await client.put(
            '$remoteFolder/$fileName',
            utf8.encode(jsonEncode(envelope.toJson())),
          );
          if (etag != null) {
            cursor.etags[fileName] = etag;
          } else {
            cursor.etags.remove(fileName);
          }
          pushed++;
          pushedSequence = change.sequence;
          cursor.pushedSequence = pushedSequence;
          _report(
            onProgress,
            WebDavSyncPhase.pushing,
            'رفع التغيير $pushed...',
            completed: pushed,
          );
        }
        await _persist(cursor, remoteId: remoteId);
        if (changes.length < 200) break;
      }
      cursor.pushedSequence = pushedSequence;
      await syncRepository.purgeEligibleTombstones(now: _clock().toUtc());
      final pending = await syncRepository.pendingConflicts();
      final summary = jsonEncode({
        'pushed': pushed,
        'pulled': pulled,
        'applied': applied,
        'skipped': skipped,
        'newConflicts': newConflicts,
        'pendingConflicts': pending.length,
        'at': _clock().toUtc().toIso8601String(),
      });
      final message = _resultMessage(
        pushed: pushed,
        pulled: pulled,
        applied: applied,
        skipped: skipped,
        conflicts: pending.length,
      );
      await _persist(
        cursor,
        remoteId: remoteId,
        lastSuccessAt: _clock().toUtc(),
        summaryJson: summary,
      );
      _report(onProgress, WebDavSyncPhase.completed, message);
      return WebDavSyncResult(
        pushed: pushed,
        pulled: pulled,
        applied: applied,
        skipped: skipped,
        conflicts: pending.length,
        message: message,
      );
    } on SyncCancelledException {
      if (loaded) {
        await _persistSafe(
          cursor,
          remoteId: remoteId,
          errorCode: 'cancelled',
        );
      }
      rethrow;
    } on Object catch (error) {
      if (loaded) {
        await _persistSafe(
          cursor,
          remoteId: remoteId,
          errorCode: error.toString(),
        );
      }
      rethrow;
    }
  }

  DateTime? _lastSuccessAt;
  String? _lastSummaryJson;

  String _remoteId() => remoteIdFor(client, remoteFolder);

  void _report(
    void Function(WebDavSyncProgress progress) onProgress,
    WebDavSyncPhase phase,
    String message, {
    int? completed,
    int? total,
  }) => onProgress(
    WebDavSyncProgress(
      phase: phase,
      message: message,
      completed: completed,
      total: total,
    ),
  );

  void _ensureNotCancelled(bool Function() isCancelled) {
    if (isCancelled()) throw const SyncCancelledException();
  }

  Future<void> _reconcileLocal({
    required bool Function() isCancelled,
    required void Function(WebDavSyncProgress progress) onProgress,
    required Map<SyncEntityType, Set<String>> skippedIds,
  }) async {
    final database = await this.database.database;
    for (final type in SyncPayloadCodec.supportedTypes) {
      _ensureNotCancelled(isCancelled);
      _report(
        onProgress,
        WebDavSyncPhase.reconciling,
        'مزامنة ${_typeLabel(type)}...',
      );
      final rows = await database.query(codec.tableOf(type));
      final presentIds = <String>{};
      for (final row in rows) {
        _ensureNotCancelled(isCancelled);
        final id = row['id']! as String;
        presentIds.add(id);
        final payload = codec.payloadOf(type, row);
        final hash = syncRepository.mergeService.payloadHash(payload);
        final existing = await syncRepository.find(type, id);
        if (existing != null &&
            existing.operation == SyncOperation.upsert &&
            existing.payloadHash == hash) {
          continue;
        }
        await syncRepository.putLocal(
          entityType: type,
          entityId: id,
          payload: payload,
          deviceId: deviceId,
          updatedAt: codec.timestampOf(payload),
        );
      }
      final records = await syncRepository.recordsOfType(type);
      final skippedForType =
          skippedIds[type] ?? const <String>{}; // entity not applicable yet
      for (final record in records) {
        if (record.operation != SyncOperation.upsert) continue;
        if (presentIds.contains(record.entityId)) continue;
        if (skippedForType.contains(record.entityId)) continue;
        _ensureNotCancelled(isCancelled);
        await syncRepository.deleteLocal(
          entityType: type,
          entityId: record.entityId,
          deviceId: deviceId,
          deletedAt: _clock().toUtc(),
        );
      }
    }
  }

  Future<void> _persist(
    _SyncCursor cursor, {
    required String remoteId,
    DateTime? lastSuccessAt,
    String? summaryJson,
    String? errorCode,
  }) async {
    if (lastSuccessAt != null) _lastSuccessAt = lastSuccessAt;
    if (summaryJson != null) _lastSummaryJson = summaryJson;
    await syncRepository.saveState(
      SyncStateSummary(
        backendId: backendId,
        remoteId: remoteId,
        cursor: cursor.encode(),
        lastSuccessAt: _lastSuccessAt,
        lastSummaryJson: _lastSummaryJson,
        errorCode: errorCode,
        credentialRef: credentialRef,
        updatedAt: _clock().toUtc(),
      ),
    );
  }

  /// Persist during error handling; a secondary failure must not mask the
  /// original error.
  Future<void> _persistSafe(
    _SyncCursor cursor, {
    required String remoteId,
    required String errorCode,
  }) async {
    try {
      await _persist(cursor, remoteId: remoteId, errorCode: errorCode);
    } on Object {
      // Keep the original failure as the reported error.
    }
  }

  String _typeLabel(SyncEntityType type) => switch (type) {
    SyncEntityType.bookmark => 'العلامات المرجعية',
    SyncEntityType.annotation => 'التعليقات',
    _ => type.name,
  };

  String _resultMessage({
    required int pushed,
    required int pulled,
    required int applied,
    required int skipped,
    required int conflicts,
  }) {
    final parts = <String>['تم رفع $pushed وجلب $pulled'];
    if (applied > 0) parts.add('تطبيق $applied');
    if (skipped > 0) {
      parts.add('تأجيل $skipped (الكتاب غير موجود بعد)');
    }
    if (conflicts > 0) parts.add('$conflicts تعارض بانتظار المراجعة');
    return parts.join('، ');
  }
}

class _SyncCursor {
  int pushedSequence = 0;
  final Map<String, String> etags = {};

  void load(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final sequence = decoded['pushedSequence'];
      if (sequence is int && sequence > 0) pushedSequence = sequence;
      final remoteEtags = decoded['etags'];
      if (remoteEtags is Map) {
        for (final entry in remoteEtags.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is String && value is String) etags[key] = value;
        }
      }
    } on Object {
      // Corrupted cursor: fall back to a full (idempotent) pass.
    }
  }

  String encode() => jsonEncode({
    'version': 1,
    'pushedSequence': pushedSequence,
    'etags': etags,
  });
}
