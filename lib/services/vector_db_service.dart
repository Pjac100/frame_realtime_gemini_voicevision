import 'package:objectbox/objectbox.dart';
import '../document_entity.dart';  // Document is in lib/ not lib/model/
import '../objectbox.g.dart';

class VectorDbService {
  late final Box<Document> _box;
  late final Store _store;

  /// Optional callback to echo diagnostic events to the UI.
  VectorDbService([void Function(String msg)? uiLogger])
      : _emit = uiLogger ?? ((_) {});

  final void Function(String) _emit;

  // ────────────────── lifecycle ──────────────────────────────────────────
  Future<void> initialize(Store store) async {
    try {
      _store = store;
      _box = _store.box<Document>();
      _emit('✅ VectorDB initialized (docs: ${_box.count()})');
    } catch (e) {
      _emit('❌ VectorDB initialization failed: $e');
      rethrow;
    }
  }

  Future<void> dispose() async {
    // ObjectBox store cleanup handled elsewhere
  }

  // ────────────────── public api ─────────────────────────────────────────
  
  /// Add an embedding to the vector database
  Future<void> addEmbedding({
    required String id,
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    try {
      final content = metadata['content']?.toString() ?? 
                      metadata['source']?.toString() ?? 
                      id;
      
      // Encode metadata in textContent (simple approach)
      final metadataStr = metadata.entries
          .map((e) => '${e.key}=${e.value}')
          .join('|');
      
      final fullContent = '$content||META:$metadataStr';
      
      final doc = Document(
        textContent: fullContent,
        embedding: embedding,
      );
      
      final docId = _box.put(doc);
      _emit('📝 Added embedding for "$content" (ID: $docId)');
    } catch (e) {
      _emit('❌ Failed to add embedding: $e');
      rethrow;
    }
  }

  /// Query for similar embeddings using vector search
  Future<List<Map<String, Object?>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
  }) async {
    try {
      final q = _box
          .query(Document_.embedding.nearestNeighborsF32(queryEmbedding, topK))
          .build();
      
      final res = q.findWithScores();
      q.close();

      _emit('🔍 Found ${res.length} similar docs');
      
      return res.map((r) {
        final parts = r.object.textContent.split('||META:');
        final content = parts.isNotEmpty ? parts[0] : r.object.textContent;
        final metadataStr = parts.length > 1 ? parts[1] : '';
        
        final metadata = <String, String>{};
        if (metadataStr.isNotEmpty) {
          for (final pair in metadataStr.split('|')) {
            final keyValue = pair.split('=');
            if (keyValue.length == 2) {
              metadata[keyValue[0]] = keyValue[1];
            }
          }
        }
        
        return {
          'id': r.object.id,
          'document': content,
          'score': r.score,
          'metadata': metadata,
        };
      }).toList();
    } catch (e) {
      _emit('❌ Vector search failed: $e');
      return [];
    }
  }

  /// Get all documents (for debugging)
  Future<List<Document>> getAllDocuments() async {
    try {
      final docs = _box.getAll();
      _emit('📚 Retrieved ${docs.length} total documents');
      return docs;
    } catch (e) {
      _emit('❌ Failed to get documents: $e');
      return [];
    }
  }

  /// Clear all documents
  Future<void> clearAll() async {
    try {
      final count = _box.count();
      _box.removeAll();
      _emit('🗑️ Cleared $count documents from database');
    } catch (e) {
      _emit('❌ Failed to clear database: $e');
      rethrow;
    }
  }

  /// Get document count
  int getDocumentCount() {
    try {
      return _box.count();
    } catch (e) {
      return 0;
    }
  }

  /// Get database statistics
  Future<Map<String, dynamic>> getStats() async {
    try {
      final totalDocs = getDocumentCount();
      final allDocs = await getAllDocuments();
      
      final typeGroups = <String, int>{};
      for (final doc in allDocs) {
        final parts = doc.textContent.split('||META:');
        if (parts.length > 1) {
          final metadataStr = parts[1];
          String? type;
          for (final pair in metadataStr.split('|')) {
            final keyValue = pair.split('=');
            if (keyValue.length == 2 && keyValue[0] == 'type') {
              type = keyValue[1];
              break;
            }
          }
          final docType = type ?? 'unknown';
          typeGroups[docType] = (typeGroups[docType] ?? 0) + 1;
        } else {
          typeGroups['unknown'] = (typeGroups['unknown'] ?? 0) + 1;
        }
      }
      
      return {
        'totalDocuments': totalDocs,
        'typeDistribution': typeGroups,
        'averageEmbeddingDimensions': allDocs.isNotEmpty
            ? allDocs
                .where((d) => d.embedding != null)
                .map((d) => d.embedding!.length)
                .fold(0, (a, b) => a + b) / allDocs.length
            : 0,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
