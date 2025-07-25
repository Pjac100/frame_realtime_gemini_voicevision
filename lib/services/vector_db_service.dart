import 'dart:math' as math;
import 'package:objectbox/objectbox.dart';
import 'package:frame_realtime_gemini_voicevision/model/document_entity.dart';
import 'package:frame_realtime_gemini_voicevision/objectbox.g.dart';

class VectorDbService {
  late final Box<Document> _box;
  late final Store _store;

  VectorDbService([void Function(String msg)? uiLogger])
      : _emit = uiLogger ?? ((_) {});

  final void Function(String) _emit;

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

  Future<void> addEmbedding({
    required String id,
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    try {
      final content = metadata['content']?.toString() ?? 
                      metadata['source']?.toString() ?? 
                      id;
      
      final metadataStr = metadata.entries
          .map((e) => '${e.key}=${e.value}')
          .join('|');
      
      final fullContent = '$content||META:$metadataStr';
      
      final doc = Document(
        textContent: fullContent,
        embedding: embedding,
        createdAt: DateTime.now(),
        metadata: metadataStr,
      );
      
      final docId = _box.put(doc);
      _emit('📝 Added embedding for "$content" (ID: $docId)');
    } catch (e) {
      _emit('❌ Failed to add embedding: $e');
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
  }) async {
    try {
      final query = _box.query().build();
      final docs = query.find();
      query.close();

      _emit('🔍 Found ${docs.length} documents, calculating similarity');
      
      final results = <Map<String, Object?>>[];
      
      for (final doc in docs) {
        final parts = doc.textContent.split('||META:');
        final content = parts.isNotEmpty ? parts[0] : doc.textContent;
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
        
        double score = 0.5;
        if (doc.embedding != null && doc.embedding!.isNotEmpty) {
          score = _cosineSimilarity(queryEmbedding, doc.embedding!);
        }
        
        results.add({
          'id': doc.id,
          'document': content,
          'score': score,
          'metadata': metadata,
        });
      }
      
      results.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
      return results.take(topK).toList();
    } catch (e) {
      _emit('❌ Vector search failed: $e');
      return [];
    }
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    
    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    
    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    
    if (normA == 0.0 || normB == 0.0) return 0.0;
    
    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }

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

  int getDocumentCount() {
    try {
      return _box.count();
    } catch (e) {
      return 0;
    }
  }

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
      
      double averageEmbeddingDimensions = 0;
      final docsWithEmbeddings = allDocs.where((d) => d.embedding != null).toList();
      if (docsWithEmbeddings.isNotEmpty) {
        final totalDimensions = docsWithEmbeddings
            .map((d) => d.embedding!.length)
            .fold<int>(0, (a, b) => a + b);
        averageEmbeddingDimensions = totalDimensions / docsWithEmbeddings.length;
      }
      
      return {
        'totalDocuments': totalDocs,
        'typeDistribution': typeGroups,
        'averageEmbeddingDimensions': averageEmbeddingDimensions,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}