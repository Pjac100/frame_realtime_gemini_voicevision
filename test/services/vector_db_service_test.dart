import 'package:flutter_test/flutter_test.dart';
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';

void main() {
  group('VectorDbService smoke tests', () {
    late VectorDbService service;

    setUp(() {
      service = VectorDbService();          // no arg needed after refactor
    });

    test('instantiates without error', () {
      expect(service, isA<VectorDbService>());
    });

    test('initialize completes cleanly', () async {
      await expectLater(service.initialize(), completes);
    });

    test('addEmbedding runs before and after init', () async {
      await expectLater(
        service.addEmbedding(
          id: 'pre_init',
          embedding: [0.1, 0.2],
          metadata: const {'source': 'test'},
        ),
        completes,
      );
      await service.initialize();
      await expectLater(
        service.addEmbedding(
          id: 'post_init',
          embedding: [0.3, 0.4],
          metadata: const {'source': 'test'},
        ),
        completes,
      );
    });

    test('querySimilarEmbeddings returns a list', () async {
      final result = await service.querySimilarEmbeddings(
        queryEmbedding: [0.0, 0.0],
        topK: 1,
      );
      expect(result, isA<List<Map<String, Object?>>>());
    });
  });
}
