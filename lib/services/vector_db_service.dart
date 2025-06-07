// lib/services/vector_db_service.dart
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package.path/path.dart' as p;

final _log = Logger('VectorDbService');

// --- FFI Definitions ---
final class _SQLiteDB extends Opaque {}
typedef SQLiteDBPointer = Pointer<_SQLiteDB>;
typedef _Sqlite3OpenV2Native = Int32 Function(Pointer<Utf8> filename, Pointer<SQLiteDBPointer> ppDb, Int32 flags, Pointer<Utf8> zVfs);
typedef _Sqlite3OpenV2Dart = int Function(Pointer<Utf8> filename, Pointer<SQLiteDBPointer> ppDb, int flags, Pointer<Utf8> zVfs);
typedef _Sqlite3CloseV2Native = Int32 Function(SQLiteDBPointer pDb);
typedef _Sqlite3CloseV2Dart = int Function(SQLiteDBPointer pDb);
typedef _Sqlite3ErrmsgNative = Pointer<Utf8> Function(SQLiteDBPointer pDb);
typedef _Sqlite3ErrmsgDart = Pointer<Utf8> Function(SQLiteDBPointer pDb);

// --- SQLite Constants ---
const int SQLITE_OK = 0;
const int SQLITE_OPEN_READWRITE = 0x00000002;
const int SQLITE_OPEN_CREATE = 0x00000004;

class VectorDbService {
  bool _isInitialized = false;
  DynamicLibrary? _nativeLib;
  SQLiteDBPointer _db = nullptr;

  late _Sqlite3OpenV2Dart _sqlite3OpenV2;
  late _Sqlite3CloseV2Dart _sqlite3CloseV2;
  late _Sqlite3ErrmsgDart _sqlite3Errmsg;

  final Function(String) eventLogger;

  // <<< MODIFIED: Constructor is now lean. It only stores the eventLogger.
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
      // <<< MOVED FFI setup from constructor to here >>>
      eventLogger('VectorDB: Loading native library...');
      String libraryName;
      if (Platform.isAndroid) {
        libraryName = 'libsqlite_vector_search.so';
      } else if (Platform.isIOS) {
        libraryName = 'sqlite_vector_search.framework/sqlite_vector_search'; // Example for iOS
      } else {
        throw UnsupportedError('Platform not supported for native library loading');
      }
      _nativeLib = DynamicLibrary.open(libraryName);
      eventLogger('VectorDB: Native library loaded successfully.');

      // Look up the C functions from the loaded library
      _sqlite3OpenV2 = _nativeLib!.lookupFunction<_Sqlite3OpenV2Native, _Sqlite3OpenV2Dart>('sqlite3_open_v2');
      _sqlite3CloseV2 = _nativeLib!.lookupFunction<_Sqlite3CloseV2Native, _Sqlite3CloseV2Dart>('sqlite3_close_v2');
      _sqlite3Errmsg = _nativeLib!.lookupFunction<_Sqlite3ErrmsgNative, _Sqlite3ErrmsgDart>('sqlite3_errmsg');
      eventLogger('VectorDB: SQLite functions looked up.');
      // <<< END OF MOVED FFI setup >>>

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
          final Pointer<Utf8> errMessageC = _sqlite3Errmsg(dbPointerPointer.value);
          if (errMessageC != nullptr) {
            errorMsg += ": ${errMessageC.toDartString()}";
          }
          _sqlite3CloseV2(dbPointerPointer.value);
        }
        eventLogger(errorMsg); // Log error to UI
        throw Exception(errorMsg);
      }

      _db = dbPointerPointer.value;

      if (_db == nullptr) {
        eventLogger('VectorDB: open returned OK but DB pointer is null.');
        throw Exception('Failed to open SQLite database: received null pointer despite SQLITE_OK.');
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
      _log.warning('VectorDbService: Error closing database. SQLite error code: $closeResult');
    } else {
      eventLogger('VectorDB: Native DB disposed successfully.');
      _log.info('VectorDbService: Native SQLite database disposed successfully.');
    }

    _isInitialized = false;
    _db = nullptr;
  }
}