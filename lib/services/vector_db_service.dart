// lib/services/vector_db_service.dart
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

final _log = Logger('VectorDbService');

// --- FFI Definitions ---
final class _SQLiteDB extends Opaque {}

typedef SQLiteDBPointer = Pointer<_SQLiteDB>;

// sqlite3_open_v2
typedef _Sqlite3OpenV2Native = Int32 Function(Pointer<Utf8> filename,
    Pointer<SQLiteDBPointer> ppDb, Int32 flags, Pointer<Utf8> zVfs);
typedef _Sqlite3OpenV2Dart = int Function(Pointer<Utf8> filename,
    Pointer<SQLiteDBPointer> ppDb, int flags, Pointer<Utf8> zVfs);

// sqlite3_close_v2
typedef _Sqlite3CloseV2Native = Int32 Function(SQLiteDBPointer pDb);
typedef _Sqlite3CloseV2Dart = int Function(SQLiteDBPointer pDb);

// sqlite3_errmsg
typedef _Sqlite3ErrmsgNative = Pointer<Utf8> Function(SQLiteDBPointer pDb);
typedef _Sqlite3ErrmsgDart = Pointer<Utf8> Function(SQLiteDBPointer pDb);

// <<< ADDED: FFI definitions for sqlite3_exec and sqlite3_free >>>
// sqlite3_exec
// SQLITE_API int sqlite3_exec(
//   sqlite3*,                                  /* An open database */
//   const char *sql,                           /* SQL to be evaluated */
//   int (*callback)(void*,int,char**,char**),  /* Callback function */
//   void *,                                    /* 1st argument to callback */
//   char **errmsg                              /* Error msg written here */
// );
typedef _Sqlite3ExecNative = Int32 Function(
    SQLiteDBPointer pDb,
    Pointer<Utf8> sql,
    Pointer<Void> callback,
    Pointer<Void> pArg,
    Pointer<Pointer<Utf8>> pzErrMsg);
typedef _Sqlite3ExecDart = int Function(
    SQLiteDBPointer pDb,
    Pointer<Utf8> sql,
    Pointer<Void> callback,
    Pointer<Void> pArg,
    Pointer<Pointer<Utf8>> pzErrMsg);

// sqlite3_free
// SQLITE_API void sqlite3_free(void*);
typedef _Sqlite3FreeNative = Void Function(Pointer<Void> p);
typedef _Sqlite3FreeDart = void Function(Pointer<Void> p);

// --- SQLite Constants ---
const int SQLITE_OK = 0;
const int SQLITE_OPEN_READWRITE = 0x00000002;
const int SQLITE_OPEN_CREATE = 0x00000004;

class VectorDbService {
  bool _isInitialized = false;
  DynamicLibrary? _nativeLib;
  SQLiteDBPointer _db = nullptr;
  bool _tablesCreated = false; // <<< ADDED: Flag to track table creation

  // Dart representations of the native functions
  late _Sqlite3OpenV2Dart _sqlite3OpenV2;
  late _Sqlite3CloseV2Dart _sqlite3CloseV2;
  late _Sqlite3ErrmsgDart _sqlite3Errmsg;
  late _Sqlite3ExecDart _sqlite3Exec; // <<< ADDED
  late _Sqlite3FreeDart _sqlite3Free; // <<< ADDED

  final Function(String) eventLogger;

  VectorDbService(this.eventLogger) {
    // FFI setup has been moved to the initialize() method.
  }

  Future<void> initialize({String dbName = 'vector_database.db'}) async {
    if (_isInitialized) {
      eventLogger('VectorDB: Already initialized.');
      return;
    }
    eventLogger('VectorDB: Initializing...');

    Pointer<Utf8> dbPathC = nullptr;
    Pointer<SQLiteDBPointer> dbPointerPointer = nullptr;

    try {
      eventLogger('VectorDB: Loading native library...');
      String libraryName;
      if (Platform.isAndroid) {
        libraryName = 'libsqlite_vector_search.so';
      } else if (Platform.isIOS) {
        libraryName = 'sqlite_vector_search.framework/sqlite_vector_search';
      } else {
        throw UnsupportedError(
            'Platform not supported for native library loading');
      }
      _nativeLib = DynamicLibrary.open(libraryName);
      eventLogger('VectorDB: Native library loaded successfully.');

      _sqlite3OpenV2 = _nativeLib!
          .lookupFunction<_Sqlite3OpenV2Native, _Sqlite3OpenV2Dart>(
              'sqlite3_open_v2');
      _sqlite3CloseV2 = _nativeLib!
          .lookupFunction<_Sqlite3CloseV2Native, _Sqlite3CloseV2Dart>(
              'sqlite3_close_v2');
      _sqlite3Errmsg = _nativeLib!
          .lookupFunction<_Sqlite3ErrmsgNative, _Sqlite3ErrmsgDart>(
              'sqlite3_errmsg');

      // <<< ADDED: Look up new functions >>>
      _sqlite3Exec = _nativeLib!
          .lookupFunction<_Sqlite3ExecNative, _Sqlite3ExecDart>('sqlite3_exec');
      _sqlite3Free = _nativeLib!
          .lookupFunction<_Sqlite3FreeNative, _Sqlite3FreeDart>('sqlite3_free');

      eventLogger('VectorDB: SQLite functions looked up.');

      final documentsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(documentsDir.path, dbName);
      eventLogger('VectorDB: DB path is $dbPath');

      dbPathC = dbPath.toNativeUtf8(allocator: calloc);
      dbPointerPointer = calloc<SQLiteDBPointer>();

      eventLogger('VectorDB: Calling sqlite3_open_v2...');
      final openResult = _sqlite3OpenV2(
        dbPathC,
        dbPointerPointer,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nullptr,
      );

      if (openResult != SQLITE_OK) {
        String errorMsg = "VectorDB: Failed to open DB. Code: $openResult";
        if (dbPointerPointer.value != nullptr) {
          final Pointer<Utf8> errMessageC =
              _sqlite3Errmsg(dbPointerPointer.value);
          if (errMessageC != nullptr) {
            errorMsg += ": ${errMessageC.toDartString()}";
          }
          _sqlite3CloseV2(dbPointerPointer.value);
        }
        eventLogger(errorMsg);
        throw Exception(errorMsg);
      }

      _db = dbPointerPointer.value;

      if (_db == nullptr) {
        eventLogger('VectorDB: open returned OK but DB pointer is null.');
        throw Exception(
            'Failed to open SQLite database: received null pointer despite SQLITE_OK.');
      }

      _isInitialized = true;
      eventLogger('VectorDB: Native DB Initialized SUCCESSFULLY.');
    } catch (e) {
      eventLogger('VectorDB: Initialization FAILED: $e');
      _log.severe('VectorDbService: Initialization failed: $e');
      _isInitialized = false;
      rethrow;
    } finally {
      if (dbPathC != nullptr) calloc.free(dbPathC);
      if (dbPointerPointer != nullptr) calloc.free(dbPointerPointer);
    }
  }

  // <<< MODIFIED: addEmbedding now handles table creation >>>
  Future<void> addEmbedding({
    required String id,
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    if (!_isInitialized || _db == nullptr) {
      _log.warning(
          'VectorDbService: Not initialized or database not open. Call initialize() first.');
      return;
    }

    // Check and create tables if they don't exist yet
    await _createTables();

    _log.info(
        'VectorDbService: addEmbedding called for id: $id (Insertion FFI not yet implemented)...');
    // TODO: Implement FFI calls to insert vector and metadata.
  }

  // <<< ADDED: New private method to create tables >>>
  Future<void> _createTables() async {
    if (_tablesCreated) return; // Only run once per session

    eventLogger('VectorDB: Checking/Creating tables...');

    // NOTE: You must decide on the dimensions for your vectors.
    // This example uses 384, a common size for sentence-transformer models.
    const sqlCreateEmbeddingsTable =
        'CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING sqlitevec(embedding FLOAT[384]);';

    const sqlCreateMetadataTable = '''
      CREATE TABLE IF NOT EXISTS metadata (
        embedding_id INTEGER PRIMARY KEY,
        source_type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        content TEXT,
        extra_data TEXT,
        FOREIGN KEY (embedding_id) REFERENCES embeddings(rowid)
      );
    ''';

    // Execute both CREATE TABLE statements
    await _executeSql(sqlCreateEmbeddingsTable, 'embeddings');
    await _executeSql(sqlCreateMetadataTable, 'metadata');

    _tablesCreated = true;
    eventLogger('VectorDB: Table check/creation complete.');
  }

  // <<< ADDED: New private helper method to execute SQL >>>
  Future<void> _executeSql(String sql, String tableNameForLogging) async {
    Pointer<Utf8> sqlC = nullptr;
    Pointer<Pointer<Utf8>> errMsgPointer = nullptr;

    try {
      sqlC = sql.toNativeUtf8(allocator: calloc);
      errMsgPointer = calloc<Pointer<Utf8>>();

      eventLogger(
          'VectorDB: Executing CREATE for $tableNameForLogging table...');
      final execResult =
          _sqlite3Exec(_db, sqlC, nullptr, nullptr, errMsgPointer);

      if (execResult != SQLITE_OK) {
        final errorMessage = errMsgPointer.value.toDartString();
        eventLogger(
            'VectorDB: FAILED to create $tableNameForLogging table. Code: $execResult, Error: $errorMessage');
        _sqlite3Free(errMsgPointer.value.cast<Void>());
        throw Exception(
            'Failed to create $tableNameForLogging table: $errorMessage');
      }
      eventLogger('VectorDB: $tableNameForLogging table created successfully.');
    } finally {
      if (sqlC != nullptr) calloc.free(sqlC);
      if (errMsgPointer != nullptr) calloc.free(errMsgPointer);
    }
  }

  Future<List<Map<String, dynamic>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
  }) async {
    if (!_isInitialized || _db == nullptr) {
      _log.warning(
          'VectorDbService: Not initialized or database not open. Call initialize() first.');
      return [];
    }
    _log.info(
        'VectorDbService: querySimilarEmbeddings called (FFI not yet fully implemented)...');
    // TODO: Implement FFI calls for vector search
    return [];
  }

  Future<void> dispose() async {
    if (!_isInitialized || _db == nullptr) {
      eventLogger('VectorDB: Dispose called on uninitialized/closed DB.');
      return;
    }
    eventLogger('VectorDB: Disposing native database...');
    final closeResult = _sqlite3CloseV2(_db);

    if (closeResult != SQLITE_OK) {
      eventLogger('VectorDB: Error closing DB. Code: $closeResult');
      _log.warning(
          'VectorDbService: Error closing database. SQLite error code: $closeResult');
    } else {
      eventLogger('VectorDB: Native DB disposed successfully.');
      _log.info(
          'VectorDbService: Native SQLite database disposed successfully.');
    }

    _isInitialized = false;
    _db = nullptr;
  }
}
