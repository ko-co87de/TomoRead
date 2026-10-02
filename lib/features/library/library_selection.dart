import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../domain/models/reading_status.dart';

class LibrarySelectionToolbar extends StatelessWidget {
  const LibrarySelectionToolbar({
    super.key,
    required this.selectedCount,
    required this.isWorking,
    required this.allSelectedAreFavorite,
    required this.onCancel,
    required this.onToggleFavorite,
    required this.onChangeCategory,
    required this.onChangeStatus,
    required this.onDelete,
  });

  final int selectedCount;
  final bool isWorking;
  final bool allSelectedAreFavorite;
  final VoidCallback onCancel;
  final VoidCallback onToggleFavorite;
  final VoidCallback onChangeCategory;
  final VoidCallback onChangeStatus;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('library-selection-toolbar'),
    color: Theme.of(context).colorScheme.secondaryContainer,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: 'الخروج من التحديد المتعدد',
            onPressed: isWorking ? null : onCancel,
            icon: const Icon(Icons.close),
          ),
          Expanded(child: Text('$selectedCount كتب محددة')),
          IconButton(
            tooltip: allSelectedAreFavorite ? 'إلغاء المفضلة' : 'الكتب المفضلة',
            onPressed: isWorking || selectedCount == 0
                ? null
                : onToggleFavorite,
            icon: Icon(
              allSelectedAreFavorite ? Icons.favorite : Icons.favorite_border,
            ),
          ),
          IconButton(
            tooltip: 'تعيين الفئات',
            onPressed: isWorking || selectedCount == 0
                ? null
                : onChangeCategory,
            icon: const Icon(Icons.folder_outlined),
          ),
          IconButton(
            tooltip: 'تعيين حالة القراءة',
            onPressed: isWorking || selectedCount == 0
                ? null
                : onChangeStatus,
            icon: const Icon(Icons.bookmark_border),
          ),
          IconButton(
            tooltip: 'حذف الكتاب',
            onPressed: isWorking || selectedCount == 0 ? null : onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    ),
  );
}

class CategoryUpdate {
  const CategoryUpdate(this.category);

  final String? category;
}

class CategoryDialog extends HookWidget {
  const CategoryDialog({super.key, required this.categories});

  final List<String> categories;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController();
    return AlertDialog(
      title: const Text('تعيين الفئات'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'اسم الفئة',
                border: OutlineInputBorder(),
              ),
            ),
            if (categories.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final category in categories)
                    ActionChip(
                      label: Text(category),
                      onPressed: () => controller.text = category,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, const CategoryUpdate(null)),
          child: const Text('مسح الفئة'),
        ),
        FilledButton(
          onPressed: () {
            final category = controller.text.trim();
            if (category.isEmpty) return;
            Navigator.pop(context, CategoryUpdate(category));
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

class ReadingStatusDialog extends StatelessWidget {
  const ReadingStatusDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('تعيين حالة القراءة'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final status in ReadingStatus.values)
            ListTile(
              leading: Icon(status == ReadingStatus.reading
                  ? Icons.auto_stories_outlined
                  : status == ReadingStatus.finished
                      ? Icons.check_circle_outline
                      : status == ReadingStatus.wantToRead
                          ? Icons.bookmark_add_outlined
                          : Icons.menu_book_outlined),
              title: Text(status.label),
              onTap: () => Navigator.pop(context, status),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
    ],
  );
}
