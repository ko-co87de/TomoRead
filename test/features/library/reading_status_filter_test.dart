import 'package:flutter_test/flutter_test.dart';
import 'package:tomoread/domain/models/epub_manifest.dart';
import 'package:tomoread/domain/models/library_book.dart';
import 'package:tomoread/domain/models/library_workspace_state.dart';
import 'package:tomoread/domain/models/reading_status.dart';
import 'package:tomoread/features/library/library_controls.dart';

void main() {
  List<LibraryBook> books() => [
    _book(
      'a',
      status: ReadingStatus.wantToRead,
      isFavorite: true,
    ),
    _book('b', status: ReadingStatus.reading),
    _book('c', status: ReadingStatus.finished),
    _book('d', status: ReadingStatus.newBook),
  ];

  List<LibraryBook> filter({
    bool favoritesOnly = false,
    ReadingStatus? readingStatus,
  }) => filterAndSortBooks(
    books(),
    query: '',
    formatFilter: LibraryFormatFilter.all,
    sort: LibrarySort.recent,
    category: allCategoriesFilter,
    tag: null,
    favoritesOnly: favoritesOnly,
    readingStatus: readingStatus,
  );

  test('returns every book when no status filter is selected', () {
    expect(filter(), hasLength(4));
  });

  test('keeps only books with the selected reading status', () {
    final result = filter(readingStatus: ReadingStatus.wantToRead);
    expect(result.single.id, 'a');
    expect(result.single.readingStatus, ReadingStatus.wantToRead);
  });

  test('combines the favorites filter with the status filter', () {
    expect(filter(favoritesOnly: true), hasLength(1));

    final combined = filter(
      favoritesOnly: true,
      readingStatus: ReadingStatus.reading,
    );
    expect(combined, isEmpty);
  });
}

LibraryBook _book(
  String id, {
  required ReadingStatus status,
  bool isFavorite = false,
}) => LibraryBook(
  id: id,
  fileHash: 'hash-$id',
  title: 'Book $id',
  author: 'Author',
  filePath: '/tmp/$id.epub',
  progress: 0,
  importedAt: DateTime(2026),
  format: 'epub',
  chapterCount: 1,
  direction: ReadingDirection.ltr,
  isFavorite: isFavorite,
  readingStatus: status,
);
