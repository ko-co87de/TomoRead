import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../domain/models/sync_models.dart';
import 'sync_settings_controller.dart';

class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(syncSettingsControllerProvider);
    final controller = ref.read(syncSettingsControllerProvider.notifier);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text('تعذر تحميل إعدادات المزامنة: $error'),
      ),
      data: (state) => _SyncSettingsForm(state: state, controller: controller),
    );
  }
}

class _SyncSettingsForm extends StatelessWidget {
  const _SyncSettingsForm({required this.state, required this.controller});

  final SyncSettingsState state;
  final SyncSettingsController controller;

  bool get _fieldsEnabled => !state.running;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('المزامنة عبر WebDAV', style: textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'زامن العلامات المرجعية والتعليقات يدويًا مع خادم WebDAV.'
          ' المزامنة تعمل بشكل صريح عند طلبك، وقابلة للإيقاف والاستئناف،'
          ' وتعرض تقدمها ونتائجها. تُحفظ كلمة المرور في التخزين الآمن للنظام فقط.',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        TextFormField(
          key: const Key('webdav-url'),
          enabled: _fieldsEnabled,
          initialValue: state.url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'عنوان الخادم',
            hintText: 'https://example.com/remote.php/dav/files/user',
            border: OutlineInputBorder(),
          ),
          onChanged: controller.setUrl,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('webdav-username'),
          enabled: _fieldsEnabled,
          initialValue: state.username,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'اسم المستخدم',
            border: OutlineInputBorder(),
          ),
          onChanged: controller.setUsername,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('webdav-password'),
          enabled: _fieldsEnabled,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'كلمة المرور',
            hintText: state.passwordStored
                ? 'كلمة مرور محفوظة — اتركها فارغة للإبقاء عليها'
                : null,
            border: const OutlineInputBorder(),
            suffixIcon: state.passwordStored
                ? IconButton(
                    key: const Key('webdav-delete-password'),
                    tooltip: 'حذف كلمة المرور المحفوظة',
                    onPressed: controller.deleteStoredPassword,
                    icon: const Icon(Icons.delete_outline),
                  )
                : null,
          ),
          onChanged: controller.setPassword,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('webdav-folder'),
          enabled: _fieldsEnabled,
          initialValue: state.folder,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'مجلد المزامنة',
            hintText: 'tomoread-sync',
            border: OutlineInputBorder(),
          ),
          onChanged: controller.setFolder,
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const Key('webdav-save'),
              onPressed: _fieldsEnabled ? controller.save : null,
              icon: const Icon(Icons.save_outlined),
              label: const Text('حفظ'),
            ),
            OutlinedButton.icon(
              key: const Key('webdav-test'),
              onPressed: _fieldsEnabled ? controller.testConnection : null,
              icon: const Icon(Icons.wifi_tethering_outlined),
              label: const Text('اختبار الاتصال'),
            ),
            FilledButton.icon(
              key: const Key('webdav-sync-now'),
              onPressed: _fieldsEnabled ? controller.syncNow : null,
              icon: const Icon(Icons.sync_outlined),
              label: const Text('مزامنة الآن'),
            ),
            if (state.running)
              TextButton.icon(
                key: const Key('webdav-cancel'),
                onPressed: controller.cancel,
                icon: const Icon(Icons.close),
                label: const Text('إلغاء'),
              ),
          ],
        ),
        if (state.running ||
            state.status == SyncSettingsStatus.failed ||
            state.status == SyncSettingsStatus.succeeded ||
            state.status == SyncSettingsStatus.cancelled) ...[
          const SizedBox(height: 20),
          _SyncStatus(state: state, onRetry: controller.syncNow),
        ],
        if (state.lastSuccessAt != null || state.pushed > 0) ...[
          const SizedBox(height: 16),
          _LastRunSummary(state: state),
        ],
        if (state.conflicts.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('تعارضات بانتظار المراجعة', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          if (state.conflictsMessage != null) ...[
            Text(
              state.conflictsMessage!,
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final conflict in state.conflicts)
            _ConflictTile(
              conflict: conflict,
              enabled: _fieldsEnabled,
              onResolve: (keepLocal) => controller.resolveConflictAction(
                conflict,
                keepLocal: keepLocal,
              ),
            ),
        ],
      ],
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus({required this.state, required this.onRetry});

  final SyncSettingsState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = state.status == SyncSettingsStatus.failed;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: failed ? scheme.errorContainer : scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.running) ...[
              state.progress == null
                  ? const LinearProgressIndicator()
                  : LinearProgressIndicator(value: state.progress),
              const SizedBox(height: 12),
            ],
            Text(state.error ?? state.message ?? ''),
            if (failed) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('أعد المحاولة'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LastRunSummary extends StatelessWidget {
  const _LastRunSummary({required this.state});

  final SyncSettingsState state;

  @override
  Widget build(BuildContext context) {
    final lastSuccessText = state.lastSuccessAt
        ?.toLocal()
        .toString()
        .replaceAll('T', ' ')
        .substring(0, 16);
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        if (lastSuccessText != null)
          Text(
            'آخر مزامنة ناجحة: $lastSuccessText',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        Text(
          'رفع ${state.pushed} · جلب ${state.pulled} · تطبيق ${state.applied}'
          ' · تأجيل ${state.skipped}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({
    required this.conflict,
    required this.enabled,
    required this.onResolve,
  });

  final SyncConflict conflict;
  final bool enabled;
  final ValueChanged<bool> onResolve;

  String get _typeLabel => switch (conflict.entityType) {
    SyncEntityType.bookmark => 'علامة مرجعية',
    SyncEntityType.annotation => 'تعليق',
    _ => 'عنصر',
  };

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_typeLabel: ${conflict.entityId}',
              style: textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'الحقول المتضاربة: ${conflict.fieldNames.join('، ')}'
              ' · محلي ${conflict.localRevision} مقابل بُعدي ${conflict.incomingRevision}',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: enabled ? () => onResolve(true) : null,
                  child: const Text('الاحتفاظ بالمحلي'),
                ),
                OutlinedButton(
                  onPressed: enabled ? () => onResolve(false) : null,
                  child: const Text('الاحتفاظ بالبُعدي'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
