import 'package:flutter_test/flutter_test.dart';
import 'package:tomoread/data/database/app_database.dart';
import 'package:tomoread/data/repositories/book_repository.dart';
import 'package:tomoread/domain/models/epub_manifest.dart';
import 'package:tomoread/domain/models/library_book.dart';
import 'package:tomoread/domain/models/reading_status.dart';

void main() {
  late AppDatabase database;
  late BookRepository repository;

  setUp(() {
    database = AppDatabase.inMemory();
    repository = BookRepository(database);
  });

  tearDown(() => database.close());

  test('reading position promotes new books and finishes at 95%', () async {
    final book = _book();
    await repository.saveImportedPdfBook(book);

    var saved = await repository.findById(book.id);
    expect(saved!.readingStatus, ReadingStatus.newBook);

    await repository.updateReadingPosition(
      bookId: book.id,
      chapterIndex: 1,
      progress: 0.02,
    );
    saved = await repository.findById(book.id);
    expect(saved!.readingStatus, ReadingStatus.reading);

    await repository.updateReadingPosition(
      bookId: book.id,
      chapterIndex: 9,
      progress: 0.96,
    );
    saved = await repository.findById(book.id);
    expect(saved!.readingStatus, ReadingStatus.finished);
    expect(saved.progress, 0.96);

    await repository.resetReadingPosition(book.id);
    saved = await repository.findById(book.id);
    expect(saved!.readingStatus, ReadingStatus.reading);
    expect(saved.progress, 0);
  });

  test('reset does not promote an untouched new book', () async {
    final book = _book();
    await repository.saveImportedPdfBook(book);

    await repository.resetReadingPosition(book.id);

    final saved = await repository.findById(book.id);
    expect(saved!.readingStatus, ReadingStatus.newBook);
  });

  test('manual status updates apply to one book and to a batch', () async {
    final first = _book(id: 'book-a');
    final second = _book(id: 'book-b', hash: 'hash-b');
    await repository.saveImportedPdfBook(first);
    await repository.saveImportedPdfBook(second);

    await repository.setReadingStatus(first.id, ReadingStatus.wantToRead);
    var saved = await repository.findById(first.id);
    expect(saved!.readingStatus, ReadingStatus.wantToRead);

    await repository.setReadingStatusForBooks(
      [first.id, second.id],
      ReadingStatus.finished,
    );
    saved = await repository.findById(first.id);
    expect(saved!.readingStatus, ReadingStatus.finished);
    saved = await repository.findById(second.id);
    expect(saved!.readingStatus, ReadingStatus.finished);
  });

  test('want to read status survives a zero-progress position save', () async {
    final book = _book();
    await repository.saveImportedPdfBook(book);
    await repository.setReadingStatus(book.id, ReadingStatus.wantToRead);

    await repository.updateReadingPosition(
      bookId: book.id,
      chapterIndex: 0,
      progress: 0,
    );

    final saved = await repository.findById(book.id);
    expect(saved!.readingStatus, ReadingStatus.wantToRead);
  });
}

LibraryBook _book({String id = 'book-id', String hash = 'hash'}) => LibraryBook(
  id: id,
  fileHash: hash,
  title: 'Original title',
  author: 'Original author',
  filePath: '/tmp/book.epub',
  progress: 0,
  importedAt: DateTime(2026),
  format: 'epub',
  chapterCount: 10,
  direction: ReadingDirection.ltr,
);
