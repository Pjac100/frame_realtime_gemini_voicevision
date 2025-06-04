// lib/services/vector_db_service.dart
import 'dart:ffi'; // For FFI
import 'dart:io' show Platform; // For checking platform
import 'package:ffi/ffi.dart'; // For Utf8, calloc, etc.
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart'; // To get documents directory
import 'package:path/path.dart' as p; // For joining paths

final _log = Logger('VectorDbService');

// --- FFI Definitions ---

// Opaque struct representing the C sqlite3 object.
// We don't need to define its members, just use it as a Pointer.
final class _SQLiteDB extends Opaque {}
typedef SQLiteDBPointer = Pointer<_SQLiteDB>;

// Signature of the C function sqlite3_open_v2
// SQLITE_API int sqlite3_open_v2(
//   const char *filename,   /* Database filename (UTF-8) */
//   sqlite3 **ppDb,         /* OUT: SQLite db handle */
//   int flags,              /* Flags */
//   const char *zVfs        /* Name of VFS module to use */
// );
typedef _Sqlite3OpenV2Native = Int32 Function(
    Pointer<Utf8> filename, Pointer<SQLiteDBPointer> ppDb, Int32 flags, Pointer<Utf8> zVfs);
typedef _Sqlite3OpenV2Dart = int Function(
    Pointer<Utf8> filename, Pointer<SQLiteDBPointer> ppDb, int flags, Pointer<Utf8> zVfs);

// Signature of the C function sqlite3_close_v2
// SQLITE_API int sqlite3_close_v2(sqlite3*);
typedef _Sqlite3CloseV2Native = Int32 Function(SQLiteDBPointer pDb);
typedef _Sqlite3CloseV2Dart = int Function(SQLiteDBPointer pDb);

// Signature of the C function sqlite3_errmsg
// SQLITE_API const char *sqlite3_errmsg(sqlite3*);
typedef _Sqlite3ErrmsgNative = Pointer<Utf8> Function(SQLiteDBPointer pDb);
typedef _Sqlite3ErrmsgDart = Pointer<Utf8> Function(SQLiteDBPointer pDb);

// --- SQLite Constants (from sqlite3.h) ---
const int SQLITE_OK = 0;
// Flags for sqlite3_open_v2 (you can combine them)
const int SQLITE_OPEN_READWRITE = 0x00000002; // Open for reading and writing.
const int SQLITE_OPEN_CREATE = 0x00000004;    // Create the file if it does not exist.
// Add other flags as needed, e.g., SQLITE_OPEN_FULLMUTEX, etc.

class VectorDbService {
  bool _isInitialized = false;
  late final DynamicLibrary _nativeLib; // Mark as late final
  SQLiteDBPointer _db = nullptr; // Initialize with nullptr, will be set in initialize()

  // Dart representations of the native functions
  late final _Sqlite3OpenV2Dart _sqlite3OpenV2; // Mark as late final
  late final _Sqlite3CloseV2Dart _sqlite3CloseV2; // Mark as late final
  late final _Sqlite3ErrmsgDart _sqlite3Errmsg; // Mark as late final

  VectorDbService() {
    // Determine library name based on platform
    String libraryName;
    if (Platform.isAndroid) {
      libraryName = 'libsqlite_vector_search.so';
    } else if (Platform.isIOS) {
      // For iOS, the library is typically linked statically or part of a framework.
      // DynamicLibrary.process() or DynamicLibrary.executable() might be used,
      // or a specific path if it's a framework.
      // This will need adjustment for iOS. For now, placeholder:
      libraryName = 'sqlite_vector_search.framework/sqlite_vector_search'; // Example
    } else if (Platform.isWindows) {
      libraryName = 'sqlite_vector_search.dll'; // Example for Windows if you build for it
    } else {
      // Handle other platforms or throw an error
      throw UnsupportedError('Platform not supported for native library loading');
    }
    _nativeLib = DynamicLibrary.open(libraryName);

    // Look up the functions
    _sqlite3OpenV2 = _nativeLib
        .lookupFunction<_Sqlite3OpenV2Native, _Sqlite3OpenV2Dart>('sqlite3_open_v2');
    _sqlite3CloseV2 = _nativeLib
        .lookupFunction<_Sqlite3CloseV2Native, _Sqlite3CloseV2Dart>('sqlite3_close_v2');
    _sqlite3Errmsg = _nativeLib
        .lookupFunction<_Sqlite3ErrmsgNative, _Sqlite3ErrmsgDart>('sqlite3_errmsg');

    _log.info('VectorDbService: Native library loaded and SQLite functions looked up.');
    // Note: We are not explicitly looking up an sqlite_vec_init function here.
    // sqlite-vec documentation suggests that if sqlite-vec.c is compiled directly
    // into SQLite (as our CMakeLists.txt does), its virtual table 'sqlitevec'
    // should be automatically registered and available. We will test this later.
  }

  Future<void> initialize({String dbName = 'vector_database.db'}) async {
    if (_isInitialized) {
      _log.info('VectorDbService: Already initialized.');
      return;
    }
    _log.info('VectorDbService: Initializing native database...');

    Pointer<Utf8> dbPathC = nullptr;
    Pointer<SQLiteDBPointer> dbPointerPointer = nullptr;

    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(documentsDir.path, dbName);
      _log.info('VectorDbService: Database path: $dbPath');

      dbPathC = dbPath.toNativeUtf8(allocator: calloc);
      dbPointerPointer = calloc<SQLiteDBPointer>();

      final openResult = _sqlite3OpenV2(
        dbPathC,
        dbPointerPointer,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nullptr, // Use default VFS
      );

      if (openResult != SQLITE_OK) {
        String errorMsg = "Failed to open SQLite database. SQLite error code: $openResult";
        // Attempt to get a more detailed error message from SQLite if the db handle was populated
        if (dbPointerPointer.value != nullptr) {
          final Pointer<Utf8> errMessageC = _sqlite3Errmsg(dbPointerPointer.value);
          if (errMessageC != nullptr) {
            errorMsg += ": ${errMessageC.toDartString()}";
          }
          // Note: sqlite3_open_v2 should set ppDb to NULL on failure to allocate the sqlite3 struct.
          // If it's not NULL here, it implies some other failure after allocation, so closing it is safer.
          _sqlite3CloseV2(dbPointerPointer.value);
        }
        throw Exception(errorMsg);
      }

      _db = dbPointerPointer.value;

      if (_db == nullptr) {
        throw Exception('Failed to open SQLite database: received null pointer despite SQLITE_OK.');
      }

      _isInitialized = true;
      _log.info('VectorDbService: Native SQLite database initialized successfully.');

    } catch (e) {
      _log.severe('VectorDbService: Initialization failed: $e');
      _isInitialized = false;
      rethrow;
    } finally {
      // Free allocated C string and pointer memory
      if (dbPathC != nullptr) calloc.free(dbPathC);
      if (dbPointerPointer != nullptr) calloc.free(dbPointerPointer);
    }
  }

  Future<void> addEmbedding({
    required String id,
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    if (!_isInitialized || _db == nullptr) {
      _log.warning('VectorDbService: Not initialized or database not open. Call initialize() first.');
      return;
    }
    _log.info('VectorDbService: addEmbedding called for id: $id (FFI not yet fully implemented)...');
    // TODO: Implement FFI calls to create table (if not exists) and insert vector data
    // This will involve:
    // 1. Defining C function signatures for sqlite3_exec or sqlite3_prepare_v2, sqlite3_bind_*, sqlite3_step, sqlite3_finalize
    // 2. Converting 'id', 'embedding', 'metadata' to C compatible types (Pointers)
    // 3. Constructing and executing SQL, potentially something like:
    //    CREATE VIRTUAL TABLE IF NOT EXISTS vec_items USING sqlitevec(embedding_col_name FLOAT[dimensions_here]); -- Example
    //    CREATE TABLE IF NOT EXISTS items_metadata(id TEXT PRIMARY KEY, data TEXT);
    //    INSERT INTO vec_items (rowid, embedding_col_name) VALUES (?, ?); -- Use rowid for linking
    //    INSERT INTO items_metadata (id, data) VALUES (?, json_encode(metadata));
    //    (Note: Check sqlite-vec documentation for exact table creation and usage for linking vectors to metadata)
  }

  Future<List<Map<String, dynamic>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
  }) async {
    if (!_isInitialized || _db == nullptr) {
      _log.warning('VectorDbService: Not initialized or database not open. Call initialize() first.');
      return [];
    }
    _log.info('VectorDbService: querySimilarEmbeddings called (FFI not yet fully implemented)...');
    // TODO: Implement FFI calls for vector search
    // This will involve:
    // 1. Using sqlite3_prepare_v2, sqlite3_bind_*, sqlite3_step, sqlite3_column_*, sqlite3_finalize
    // 2. Constructing SQL like (example from sqlite-vec docs, adapt as needed):
    //    SELECT rowid, distance FROM vec_items WHERE embedding_col_name MATCH ? ORDER BY distance LIMIT ?;
    //    Then fetching metadata for the returned rowids from your items_metadata table.
    return [];
  }

  Future<void> dispose() async {
    if (!_isInitialized || _db == nullptr) {
      _log.info('VectorDbService: Not initialized or database already disposed.');
      return;
    }
    _log.info('VectorDbService: Disposing native SQLite database...');
    final closeResult = _sqlite3CloseV2(_db);

    if (closeResult != SQLITE_OK) {
      // It's tricky to get a meaningful error message from _sqlite3Errmsg AFTER a failed close
      // because the db handle might be invalid. Logging the code is safer.
      _log.warning('VectorDbService: Error closing database. SQLite error code: $closeResult');
    } else {
      _log.info('VectorDbService: Native SQLite database disposed successfully.');
    }

    _isInitialized = false;
    _db = nullptr; // Mark database pointer as null
  }
}