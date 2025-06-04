// lib/services/vector_db_service.dart
import 'dart:ffi'; // For FFI
import 'dart:io' show Platform; // For checking platform
// ignore: depend_on_referenced_packages
import 'package:ffi/ffi.dart'; // For Utf8, calloc, etc.
import 'package:logging/logging.dart'; //
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart'; // To get documents directory
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p; // For joining paths

final _log = Logger('VectorDbService'); //

// --- FFI Definitions ---

// Opaque struct representing the C sqlite3 object.
// We don't need to define its members, just use it as a Pointer.
final class _SQLiteDB extends Opaque {} //

typedef SQLiteDBPointer = Pointer<_SQLiteDB>; //

// Signature of the C function sqlite3_open_v2
// SQLITE_API int sqlite3_open_v2(
//   const char *filename,   /* Database filename (UTF-8) */
//   sqlite3 **ppDb,         /* OUT: SQLite db handle */
//   int flags,              /* Flags */
//   const char *zVfs        /* Name of VFS module to use */
// );
typedef _Sqlite3OpenV2Native = Int32 Function(
    Pointer<Utf8> filename, //
    Pointer<SQLiteDBPointer> ppDb,
    Int32 flags,
    Pointer<Utf8> zVfs); //
typedef _Sqlite3OpenV2Dart = int Function(
    Pointer<Utf8> filename, //
    Pointer<SQLiteDBPointer> ppDb,
    int flags,
    Pointer<Utf8> zVfs); //

// Signature of the C function sqlite3_close_v2
// SQLITE_API int sqlite3_close_v2(sqlite3*);
typedef _Sqlite3CloseV2Native = Int32 Function(SQLiteDBPointer pDb); //
typedef _Sqlite3CloseV2Dart = int Function(SQLiteDBPointer pDb); //

// Signature of the C function sqlite3_errmsg
// SQLITE_API const char *sqlite3_errmsg(sqlite3*);
typedef _Sqlite3ErrmsgNative = Pointer<Utf8> Function(SQLiteDBPointer pDb); //
typedef _Sqlite3ErrmsgDart = Pointer<Utf8> Function(SQLiteDBPointer pDb); //

// --- SQLite Constants (from sqlite3.h) ---
// ignore: constant_identifier_names
const int SQLITE_OK = 0; //
// Flags for sqlite3_open_v2 (you can combine them)
// ignore: constant_identifier_names
const int SQLITE_OPEN_READWRITE =
    0x00000002; // Open for reading and writing. //
// ignore: constant_identifier_names
const int SQLITE_OPEN_CREATE = //
    0x00000004; // Create the file if it does not exist. //
// Add other flags as needed, e.g., SQLITE_OPEN_FULLMUTEX, etc.

class VectorDbService {
  //
  bool _isInitialized = false; //
  late final DynamicLibrary _nativeLib; // Mark as late final
  SQLiteDBPointer _db = //
      nullptr; // Initialize with nullptr, will be set in initialize()

  // Dart representations of the native functions
  late final _Sqlite3OpenV2Dart _sqlite3OpenV2; // Mark as late final
  late final _Sqlite3CloseV2Dart _sqlite3CloseV2; // Mark as late final
  late final _Sqlite3ErrmsgDart _sqlite3Errmsg; // Mark as late final

  VectorDbService() {
    //
    // Determine library name based on platform
    String libraryName; //
    if (Platform.isAndroid) {
      //
      libraryName = 'libsqlite_vector_search.so'; //
    } else if (Platform.isIOS) {
      //
      libraryName = //
          'sqlite_vector_search.framework/sqlite_vector_search'; // Example
    } else if (Platform.isWindows) {
      //
      libraryName = //
          'sqlite_vector_search.dll'; // Example for Windows if you build for it
    } else {
      throw UnsupportedError(//
          'Platform not supported for native library loading'); //
    }
    _nativeLib = DynamicLibrary.open(libraryName); //

    // Look up the functions
    _sqlite3OpenV2 = //
        _nativeLib.lookupFunction<_Sqlite3OpenV2Native, _Sqlite3OpenV2Dart>(//
            'sqlite3_open_v2'); //
    _sqlite3CloseV2 = //
        _nativeLib.lookupFunction<_Sqlite3CloseV2Native, _Sqlite3CloseV2Dart>(//
            'sqlite3_close_v2'); //
    _sqlite3Errmsg = //
        _nativeLib.lookupFunction<_Sqlite3ErrmsgNative, _Sqlite3ErrmsgDart>(//
            'sqlite3_errmsg'); //

    _log.info(//
        'VectorDbService: Native library loaded and SQLite functions looked up.'); //
  }

  Future<void> initialize({String dbName = 'vector_database.db'}) async {
    //
    if (_isInitialized) {
      //
      _log.info('VectorDbService: Already initialized.'); //
      return; //
    }
    _log.info('VectorDbService: Initializing native database...'); //

    Pointer<Utf8> dbPathC = nullptr; //
    Pointer<SQLiteDBPointer> dbPointerPointer = nullptr; //

    try {
      //
      final documentsDir = await getApplicationDocumentsDirectory(); //
      final dbPath = p.join(documentsDir.path, dbName); //
      _log.info('VectorDbService: Database path: $dbPath'); //

      dbPathC = dbPath.toNativeUtf8(allocator: calloc); //
      dbPointerPointer = calloc<SQLiteDBPointer>(); //

      final openResult = _sqlite3OpenV2(
        //
        dbPathC, //
        dbPointerPointer, //
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, //
        nullptr, // Use default VFS //
      );

      if (openResult != SQLITE_OK) {
        //
        String errorMsg = //
            "Failed to open SQLite database. SQLite error code: $openResult"; //
        if (dbPointerPointer.value != nullptr) {
          //
          final Pointer<Utf8> errMessageC = //
              _sqlite3Errmsg(dbPointerPointer.value); //
          if (errMessageC != nullptr) {
            //
            errorMsg += ": ${errMessageC.toDartString()}"; //
          }
          _sqlite3CloseV2(dbPointerPointer.value); //
        }
        throw Exception(errorMsg); //
      }

      _db = dbPointerPointer.value; //

      if (_db == nullptr) {
        //
        throw Exception(//
            'Failed to open SQLite database: received null pointer despite SQLITE_OK.'); //
      }

      _isInitialized = true; //
      _log.info(//
          'VectorDbService: Native SQLite database initialized successfully.'); //
    } catch (e) {
      //
      _log.severe('VectorDbService: Initialization failed: $e'); //
      _isInitialized = false; //
      rethrow; //
    } finally {
      //
      if (dbPathC != nullptr) calloc.free(dbPathC); //
      if (dbPointerPointer != nullptr) calloc.free(dbPointerPointer); //
    }
  }

  Future<void> addEmbedding({
    //
    required String id, //
    required List<double> embedding, //
    required Map<String, dynamic> metadata, //
  }) async {
    if (!_isInitialized || _db == nullptr) {
      //
      _log.warning(//
          'VectorDbService: Not initialized or database not open. Call initialize() first.'); //
      return; //
    }
    _log.info(//
        'VectorDbService: addEmbedding called for id: $id (FFI not yet fully implemented)...'); //
  }

  Future<List<Map<String, dynamic>>> querySimilarEmbeddings({
    //
    required List<double> queryEmbedding, //
    required int topK, //
  }) async {
    if (!_isInitialized || _db == nullptr) {
      //
      _log.warning(//
          'VectorDbService: Not initialized or database not open. Call initialize() first.'); //
      return []; //;"]
    }
    _log.info(//
        'VectorDbService: querySimilarEmbeddings called (FFI not yet fully implemented)...'); //
    return []; //;"]
  }

  Future<void> dispose() async {
    //
    if (!_isInitialized || _db == nullptr) {
      //
      _log.info(//
          'VectorDbService: Not initialized or database already disposed.'); //
      return; //
    }
    _log.info('VectorDbService: Disposing native SQLite database...'); //
    final closeResult = _sqlite3CloseV2(_db); //

    if (closeResult != SQLITE_OK) {
      //
      _log.warning(//
          'VectorDbService: Error closing database. SQLite error code: $closeResult'); //
    } else {
      _log.info(//
          'VectorDbService: Native SQLite database disposed successfully.'); //
    }

    _isInitialized = false; //
    _db = nullptr; // Mark database pointer as null //
  }
}
