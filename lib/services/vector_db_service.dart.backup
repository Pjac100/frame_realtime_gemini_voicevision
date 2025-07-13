import 'package:logging/logging.dart';

import '../model/document_entity.dart';
import '../objectbox.g.dart';
import '../main.dart';                // provides global `store`

final _log = Logger('VectorDbService');

class VectorDbService {
  late final Box<Document> _box;

  /// Optional callback to echo diagnostic events to the UI.
  VectorDbService([void Function(String msg)? uiLogger])
      : _emit = uiLogger ?? ((_) {});

  final void Function(String) _emit;

  // ────────────────── lifecycle ──────────────────────────────────────────
  Future<void> initialize() async {
    _box = store.box<Document>();
    _emit('VectorDB initialised (docs: ${_box.count()})');
  }

  Future<void> dispose() async => _log.info('VectorDB disposed');

  // ────────────────── public api ─────────────────────────────────────────
  Future<void> addEmbedding({
    required String id,
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    final doc = Document(
      textContent: metadata['source'] ?? id,
      embedding: embedding,
    );
    _box.put(doc);
    _emit('Added embedding for "${doc.textContent}"');
  }

  Future<List<Map<String, Object?>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
  }) async {
    final q = _box
        .query(Document_.embedding.nearestNeighborsF32(queryEmbedding, topK))
        .build();
    final res = q.findWithScores();
    q.close();

    _emit('Found ${res.length} similar docs');
    return res
        .map((r) => {
              'document': r.object.textContent,
              'score': r.score,
            })
        .toList();
  }
}
