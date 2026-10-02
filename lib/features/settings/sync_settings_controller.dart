import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app/providers.dart';
import '../../data/services/webdav_client.dart';
import '../../data/services/webdav_config_store.dart';
import '../../data/services/webdav_sync_service.dart';
import '../../domain/models/sync_models.dart';

final syncSettingsControllerProvider =
    AsyncNotifierProvider<SyncSettingsController, SyncSettingsState>(
      SyncSettingsController.new,
    );

enum SyncSettingsStatus { idle, loading, testing, syncing, succeeded, failed, cancelled }

class SyncSettingsState {
  const SyncSettingsState({
    this.status = SyncSettingsStatus.idle,
    this.url = '',
    this.username = '',
    this.folder = WebDavConfig.defaultFolder,
    this.password = '',
    this.passwordStored = false,
    this.message,
    this.error,
    this.progress,
    this.lastSuccessAt,
    this.pushed = 0,
    this.pulled = 0,
    this.applied = 0,
    this.skipped = 0,
    this.conflicts = const [],
    this.conflictsMessage,
  });

  final SyncSettingsStatus status;
  final String url;
  final String username;
  final String folder;
  final String password;
  final bool passwordStored;
  final String? message;
  final String? error;
  final double? progress;
  final DateTime? lastSuccessAt;
  final int pushed;
  final int pulled;
  final int applied;
  final int skipped;
  final List<SyncConflict> conflicts;
  final String? conflictsMessage;

  bool get running =>
      status == SyncSettingsStatus.testing ||
      status == SyncSettingsStatus.syncing;

  SyncSettingsState copyWith({
    SyncSettingsStatus? status,
    String? url,
    String? username,
    String? folder,
    String? password,
    bool? passwordStored,
    String? message,
    String? error,
    double? progress,
    DateTime? lastSuccessAt,
    int? pushed,
    int? pulled,
    int? applied,
    int? skipped,
    List<SyncConflict>? conflicts,
    String? conflictsMessage,
    bool clearMessage = false,
    bool clearError = false,
    bool clearProgress = false,
    bool clearPassword = false,
    bool clearConflictsMessage = false,
  }) {
    return SyncSettingsState(
      status: status ?? this.status,
      url: url ?? this.url,
      username: username ?? this.username,
      folder: folder ?? this.folder,
      password: clearPassword ? '' : password ?? this.password,
      passwordStored: passwordStored ?? this.passwordStored,
      message: clearMessage ? null : message ?? this.message,
      error: clearError ? null : error ?? this.error,
      progress: clearProgress ? null : progress ?? this.progress,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      pushed: pushed ?? this.pushed,
      pulled: pulled ?? this.pulled,
      applied: applied ?? this.applied,
      skipped: skipped ?? this.skipped,
      conflicts: conflicts ?? this.conflicts,
      conflictsMessage: clearConflictsMessage
          ? null
          : conflictsMessage ?? this.conflictsMessage,
    );
  }
}

class SyncSettingsController extends AsyncNotifier<SyncSettingsState> {
  static const String _backendId = 'webdav';

  bool _cancelled = false;

  @override
  Future<SyncSettingsState> build() => _load();

  SyncSettingsState? get _current => switch (state) {
    AsyncData<SyncSettingsState>(:final value) => value,
    _ => null,
  };

  void _update(SyncSettingsState Function(SyncSettingsState) mutate) {
    final current = _current;
    if (current == null) return;
    state = AsyncData(mutate(current));
  }

  void setUrl(String value) => _update((s) => s.copyWith(url: value));

  void setUsername(String value) => _update((s) => s.copyWith(username: value));

  void setFolder(String value) => _update((s) => s.copyWith(folder: value));

  void setPassword(String value) => _update((s) => s.copyWith(password: value));

  Future<SyncSettingsState> _load() async {
    final store = ref.read(webDavConfigStoreProvider);
    final config = await store.load();
    final syncRepository = ref.read(syncRepositoryProvider);
    final conflicts = await syncRepository.pendingConflicts();
    DateTime? lastSuccessAt;
    var pushed = 0;
    var pulled = 0;
    var applied = 0;
    var skipped = 0;
    if (config.baseUri != null) {
      final summary = await syncRepository.loadState(
        backendId: _backendId,
        remoteId: WebDavSyncService.remoteIdFor(_clientFor(config, null), config.folder),
      );
      lastSuccessAt = summary?.lastSuccessAt;
      final lastSummary = summary?.lastSummaryJson;
      if (lastSummary != null) {
        try {
          final decoded = jsonDecode(lastSummary);
          if (decoded is Map<String, Object?>) {
            pushed = (decoded['pushed'] as num?)?.toInt() ?? 0;
            pulled = (decoded['pulled'] as num?)?.toInt() ?? 0;
            applied = (decoded['applied'] as num?)?.toInt() ?? 0;
            skipped = (decoded['skipped'] as num?)?.toInt() ?? 0;
          }
        } on Object {
          // Ignore malformed summaries; counters stay at zero.
        }
      }
    }
    return SyncSettingsState(
      status: SyncSettingsStatus.idle,
      url: config.url,
      username: config.username,
      folder: config.folder,
      passwordStored: config.passwordStored,
      lastSuccessAt: lastSuccessAt,
      pushed: pushed,
      pulled: pulled,
      applied: applied,
      skipped: skipped,
      conflicts: conflicts,
    );
  }

  Future<void> _reloadMetadata() async {
    final syncRepository = ref.read(syncRepositoryProvider);
    final conflicts = await syncRepository.pendingConflicts();
    DateTime? lastSuccessAt;
    final current = _current;
    if (current != null) {
      final store = ref.read(webDavConfigStoreProvider);
      final config = await store.load();
      if (config.baseUri != null) {
        final summary = await syncRepository.loadState(
          backendId: _backendId,
          remoteId: WebDavSyncService.remoteIdFor(
            _clientFor(config, null),
            config.folder,
          ),
        );
        lastSuccessAt = summary?.lastSuccessAt;
      }
    }
    _update(
      (s) => s.copyWith(
        conflicts: conflicts,
        lastSuccessAt: lastSuccessAt,
        clearConflictsMessage: conflicts.isEmpty,
      ),
    );
  }

  WebDavClient _clientFor(WebDavConfig config, String? password) {
    final baseUri = config.baseUri;
    if (baseUri == null) {
      throw WebDavException('أدخل رابط WebDAV صالحًا.');
    }
    return WebDavClient(
      baseUrl: baseUri,
      username: config.username.isEmpty ? null : config.username,
      password: password,
    );
  }

  WebDavConfig _formConfig(SyncSettingsState form) => WebDavConfig(
    url: form.url.trim(),
    username: form.username.trim(),
    folder: form.folder,
    passwordStored: form.passwordStored,
  );

  /// Persists the current form. Returns true when the config is valid.
  Future<bool> save({String? successMessage}) async {
    final form = _current;
    if (form == null) return false;
    final candidate = _formConfig(form);
    if (candidate.baseUri == null) {
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.failed,
          error: 'أدخل رابط WebDAV صالحًا يبدأ بـ http أو https.',
          clearMessage: true,
        ),
      );
      return false;
    }
    final folder = WebDavConfig.normalizeFolder(candidate.folder);
    if (folder == null) {
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.failed,
          error: 'اسم مجلد غير صالح.',
          clearMessage: true,
        ),
      );
      return false;
    }
    final store = ref.read(webDavConfigStoreProvider);
    final normalized = WebDavConfig(
      url: candidate.url,
      username: candidate.username,
      folder: folder,
      passwordStored: candidate.passwordStored,
    );
    var passwordStored = normalized.passwordStored;
    final newPassword = form.password;
    if (newPassword.isNotEmpty) {
      await store.writePassword(newPassword);
      passwordStored = true;
    }
    await store.save(
      WebDavConfig(
        url: normalized.url,
        username: normalized.username,
        folder: normalized.folder,
        passwordStored: passwordStored,
      ),
    );
    _update(
      (s) => s.copyWith(
        folder: folder,
        passwordStored: passwordStored,
        status: SyncSettingsStatus.succeeded,
        message: successMessage ?? 'تم حفظ إعدادات المزامنة.',
        error: null,
        clearError: true,
        clearPassword: true,
        clearProgress: true,
      ),
    );
    return true;
  }

  Future<void> deleteStoredPassword() async {
    final form = _current;
    if (form == null || !form.passwordStored) return;
    await ref.read(webDavConfigStoreProvider).deletePassword();
    _update(
      (s) => s.copyWith(
        passwordStored: false,
        clearPassword: true,
        clearError: true,
        message: 'تم حذف كلمة المرور المحفوظة.',
      ),
    );
  }

  Future<void> testConnection() async {
    final form = _current;
    if (form == null || form.running) return;
    _update(
      (s) => s.copyWith(
        status: SyncSettingsStatus.testing,
        clearError: true,
        clearMessage: true,
        clearProgress: true,
        message: 'جارٍ اختبار الاتصال…',
      ),
    );
    try {
      final store = ref.read(webDavConfigStoreProvider);
      final config = _formConfig(form);
      if (config.baseUri == null) {
        throw WebDavException(
          'أدخل رابط WebDAV صالحًا يبدأ بـ http أو https.',
        );
      }
      final password = form.password.isNotEmpty
          ? form.password
          : await store.readPassword();
      final client = _clientFor(config, password);
      await client.ping();
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.succeeded,
          message: 'تم الاتصال بالخادم بنجاح.',
          clearError: true,
          clearProgress: true,
        ),
      );
    } on Object catch (error) {
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.failed,
          error: error.toString(),
          clearMessage: true,
          clearProgress: true,
        ),
      );
    }
  }

  Future<void> syncNow() async {
    final form = _current;
    if (form == null || form.running) return;
    _cancelled = false;
    if (!await save(successMessage: null)) return;
    final store = ref.read(webDavConfigStoreProvider);
    final config = await store.load();
    _update(
      (s) => s.copyWith(
        status: SyncSettingsStatus.syncing,
        message: 'جارٍ تحضير المزامنة…',
        clearError: true,
        clearProgress: true,
        pushed: 0,
        pulled: 0,
        applied: 0,
        skipped: 0,
        clearConflictsMessage: true,
      ),
    );
    try {
      final password = form.password.isNotEmpty
          ? form.password
          : await store.readPassword();
      final deviceId = await ref.read(installationIdProvider.future);
      final service = WebDavSyncService(
        syncRepository: ref.read(syncRepositoryProvider),
        database: ref.read(appDatabaseProvider),
        client: _clientFor(config, password),
        deviceId: deviceId,
        remoteFolder: config.folder,
        backendId: _backendId,
      );
      final result = await service.sync(
        onProgress: (progress) {
          _update(
            (s) => s.copyWith(
              status: SyncSettingsStatus.syncing,
              message: progress.message,
              progress: progress.fraction,
            ),
          );
        },
        isCancelled: () => _cancelled,
      );
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.succeeded,
          message: result.message,
          pushed: result.pushed,
          pulled: result.pulled,
          applied: result.applied,
          skipped: result.skipped,
          progress: 1.0,
          clearError: true,
          clearConflictsMessage: true,
        ),
      );
      await _reloadMetadata();
    } on SyncCancelledException {
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.cancelled,
          message: 'تم إلغاء المزامنة.',
          clearProgress: true,
          clearError: true,
        ),
      );
      await _reloadMetadata();
    } on Object catch (error) {
      _update(
        (s) => s.copyWith(
          status: SyncSettingsStatus.failed,
          error: error.toString(),
          clearMessage: true,
          clearProgress: true,
        ),
      );
      await _reloadMetadata();
    }
  }

  void cancel() {
    if (!(_current?.running ?? false)) return;
    _cancelled = true;
    _update((s) => s.copyWith(message: 'جارٍ إيقاف المزامنة…'));
  }

  Future<void> resolveConflictAction(
    SyncConflict conflict, {
    required bool keepLocal,
  }) async {
    if (_current?.running ?? false) return;
    try {
      final deviceId = await ref.read(installationIdProvider.future);
      final syncRepository = ref.read(syncRepositoryProvider);
      final envelope = await syncRepository.resolveConflict(
        conflictId: conflict.id,
        resolutionPayload: keepLocal
            ? conflict.localPayload
            : conflict.incomingPayload,
        deviceId: deviceId,
      );
      final applied = await WebDavSyncService.applyToEntity(
        ref.read(appDatabaseProvider),
        envelope,
      );
      await _reloadMetadata();
      _update(
        (s) => s.copyWith(
          conflictsMessage: applied
              ? 'تم حل التعارض وتطبيق اختيارك.'
              : 'تم حفظ الحل، لكن لم يتم تطبيقه على الكتاب محليًا بعد.',
        ),
      );
    } on Object catch (error) {
      _update((s) => s.copyWith(conflictsMessage: error.toString()));
    }
  }
}
