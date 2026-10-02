import '../../domain/models/sync_models.dart';

/// Maps entity rows to sync payloads and back for the entity types the
/// current sync transport understands.
///
/// Payloads contain only plain JSON values (strings, ints, nulls) so they can
/// round-trip through `SyncEnvelope` hashing without corruption. Row columns
/// that carry sync bookkeeping (`sync_revision`) are intentionally excluded.
class SyncPayloadCodec {
  const SyncPayloadCodec();

  static const List<SyncEntityType> supportedTypes = [
    SyncEntityType.bookmark,
    SyncEntityType.annotation,
  ];

  static const Map<SyncEntityType, String> _tables = {
    SyncEntityType.bookmark: 'bookmarks',
    SyncEntityType.annotation: 'reading_annotations',
  };

  static const Map<SyncEntityType, List<String>> _columns = {
    SyncEntityType.bookmark: [
      'id',
      'book_id',
      'locator',
      'chapter_title',
      'label',
      'created_at',
      'updated_at',
    ],
    SyncEntityType.annotation: [
      'id',
      'book_id',
      'href',
      'locator',
      'selected_text',
      'note',
      'color',
      'render_style',
      'created_at',
      'updated_at',
      'chapter_index',
      'chapter_title',
    ],
  };

  bool supports(SyncEntityType type) => _columns.containsKey(type);

  String tableOf(SyncEntityType type) {
    final table = _tables[type];
    if (table == null) {
      throw ArgumentError.value(type, 'type', 'unsupported sync entity type');
    }
    return table;
  }

  List<String> columnsOf(SyncEntityType type) {
    final columns = _columns[type];
    if (columns == null) {
      throw ArgumentError.value(type, 'type', 'unsupported sync entity type');
    }
    return columns;
  }

  Map<String, Object?> payloadOf(
    SyncEntityType type,
    Map<String, Object?> row,
  ) => {
    for (final column in columnsOf(type)) column: row[column],
  };

  /// Best-effort change timestamp for a payload: `updated_at` when the row
  /// records one, otherwise `created_at`.
  DateTime timestampOf(Map<String, Object?> payload) {
    final updatedAt = payload['updated_at'];
    final createdAt = payload['created_at'];
    final millis =
        (updatedAt is int && updatedAt > 0)
            ? updatedAt
            : (createdAt is int ? createdAt : 0);
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  /// `INSERT OR REPLACE` keeps the row in sync with an incoming envelope.
  /// Conflicting duplicates (same book/locator, different id) collapse into
  /// the winning row, which matches the table's unique constraints.
  String upsertStatement(SyncEntityType type) {
    final columns = columnsOf(type);
    return 'INSERT OR REPLACE INTO ${tableOf(type)} '
        '(${[...columns, 'sync_revision'].join(', ')}) '
        'VALUES (${List.filled(columns.length + 1, '?').join(', ')})';
  }

  List<Object?> upsertArgs(SyncEnvelope envelope) => [
    ...columnsOf(envelope.entityType).map(
      (column) => envelope.payload[column],
    ),
    envelope.revision,
  ];

  String deleteStatement(SyncEntityType type) =>
      'DELETE FROM ${tableOf(type)} WHERE id = ?';
}
