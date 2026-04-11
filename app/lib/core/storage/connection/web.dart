// ignore: deprecated_member_use
// WebDatabase uses IndexedDB, which is fine for this app.
// The replacement (drift/wasm.dart) requires serving additional .wasm/.js
// files — unnecessary complexity for a primarily native app.
import 'package:drift/drift.dart';
// ignore: deprecated_member_use
import 'package:drift/web.dart';

QueryExecutor openDatabaseConnection() {
  return WebDatabase('emajtee');
}
