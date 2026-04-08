import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

part 'app_database.g.dart';

// Tables will be added here as features are built out.
// See specs for planned schema: courses, sections, blocks, video metadata, sync state.

@DriftDatabase(tables: [])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    if (kIsWeb) {
      // Web support via drift's web implementation — wired up separately.
      throw UnsupportedError('Web database not yet configured');
    }

    await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();

    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'emajtee.db'));
    return NativeDatabase.createInBackground(file);
  });
}
