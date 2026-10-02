enum ReadingStatus {
  newBook('new', 'جديد'),
  wantToRead('want_to_read', 'أريد قراءته'),
  reading('reading', 'يقرأ'),
  finished('finished', 'مكتمل');

  const ReadingStatus(this.dbValue, this.label);

  final String dbValue;
  final String label;

  static const double finishedThreshold = 0.95;

  static ReadingStatus fromDb(Object? value) =>
      values.firstWhere((status) => status.dbValue == value, orElse: () => newBook);
}
