import 'package:logging/logging.dart';

// Import the main app file to get access to the global 'store'.
import '../main.dart';
// Import the entity model we created.
import '../model/document_entity.dart';
// Import the generated ObjectBox code.
import '../objectbox.g.dart';

final _log = Logger('VectorDbService');

class VectorDbService {
  // A box is like a table in SQL; it stores all objects of a specific type.
  late final Box<Document> _documentBox;

  final Function(String) eventLogger;

  VectorDbService(this.eventLogger);

  /// Initializes the service by getting a reference to the Document Box
  /// from the main ObjectBox store.
  Future<void> initialize() async {
    // The 'store' is initialized in main.dart and is available globally.
    _documentBox = store.box<Document>();
    eventLogger('VectorDB: Service initialized. Box ready.');
    _log.info('ObjectBox VectorDbService initialized.');
  }

  /// NEW: Adds a new Document object directly to the database.
  void addDocument(Document document) {
    _documentBox.put(document);
    eventLogger('VectorDB: Stored: "${document.textContent}"');
    _log.info(
        'Stored document in ObjectBox with text: ${document.textContent}');
  }

  /// Adds a new document with its vector embedding to the database.
  /// This method is updated to work with the new Document model.
  Future<void> addEmbedding({
    required String id, // We'll use textContent as the effective ID for now.
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    final newDocument = Document(
      timestamp: DateTime.now(), // Add timestamp here to fix constructor error
      textContent: metadata['source'] ?? id, // Use metadata or the passed id.
      embedding: embedding,
    );

    // Use the new, simpler method
    addDocument(newDocument);
  }

  /// Queries the database to find the most similar documents to the given vector.
  Future<List<Map<String, dynamic>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
  }) async {
    // 1. Build the query using the generated 'Document_' helper class.
    // 2. Use 'nearestNeighborsF32' for vector search on the 'embedding' property.
    final query = _documentBox
        .query(Document_.embedding.nearestNeighborsF32(queryEmbedding, topK))
        .build();

    // 3. 'findWithScores' returns the matching objects along with their distance score.
    final resultsWithScores = query.findWithScores();
    query.close(); // It's good practice to close queries when done.

    eventLogger(
        'VectorDB: Found ${resultsWithScores.length} similar documents.');

    // 4. Format the results into a list of maps, similar to the old API.
    return resultsWithScores.map((result) {
      return {
        'document': result.object.textContent,
        'score': result.score, // Lower score = more similar (closer distance)
      };
    }).toList();
  }

  /// Disposes of resources. For ObjectBox, the store is managed globally
  /// and typically lives for the duration of the app.
  Future<void> dispose() async {
    // The global store is managed in main.dart, so we don't close it here.
    // If you had specific streams or queries in this service, you would close them here.
    _log.info('VectorDbService disposed.');
    return Future.value();
  }
}
