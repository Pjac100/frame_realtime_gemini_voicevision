// test/services/vector_db_service_test.dart
import 'package:flutter_test/flutter_test.dart';
// Adjust the import path to match your project structure and pubspec.yaml name
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';

// Optional: If you want to see logs from the service during tests
// import 'package:logging/logging.dart';
// void setupLogging() {
//   Logger.root.level = Level.ALL;
//   Logger.root.onRecord.listen((record) {
//     print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
//   });
// }

void main() {
  // setupLogging(); // Call if you want to see logs

  group('VectorDbService Stub Tests', () {
    late VectorDbService vectorDbService;

    setUp(() {
      vectorDbService = VectorDbService();
    });

    test('service can be instantiated', () {
      expect(vectorDbService, isA<VectorDbService>());
    });

    test('initialize completes successfully', () async {
      await expectLater(vectorDbService.initialize(), completes);
    });

    test('addEmbedding does not throw error before initialization (logs warning)', () async {
      await expectLater(
        vectorDbService.addEmbedding(
          id: 'test_id_uninit',
          embedding: [0.1, 0.2],
          metadata: {'key': 'value'},
        ),
        completes,
      );
    });

    test('querySimilarEmbeddings returns empty list before initialization (logs warning)', () async {
      final result = await vectorDbService.querySimilarEmbeddings(
        queryEmbedding: [0.1, 0.2],
        topK: 5,
      );
      expect(result, isEmpty);
      expect(result, isA<List<Map<String, dynamic>>>());
    });

    test('addEmbedding completes after initialize', () async {
      await vectorDbService.initialize();
      await expectLater(
        vectorDbService.addEmbedding(
          id: 'test_id',
          embedding: [0.1, 0.2],
          metadata: {'key': 'value'},
        ),
        completes,
      );
    });

    test('querySimilarEmbeddings returns empty list (stub behavior) after initialize', () async {
      await vectorDbService.initialize();
      final result = await vectorDbService.querySimilarEmbeddings(
        queryEmbedding: [0.1, 0.2],
        topK: 5,
      );
      expect(result, isEmpty);
      expect(result, isA<List<Map<String, dynamic>>>());
    });

    test('dispose completes successfully', () async {
      await vectorDbService.initialize();
      await expectLater(vectorDbService.dispose(), completes);
    });

    test('operations log warning or return default after dispose', () async {
      await vectorDbService.initialize();
      await vectorDbService.dispose();

      await expectLater(
        vectorDbService.addEmbedding(
          id: 'test_id_disposed',
          embedding: [0.1, 0.2],
          metadata: {'key': 'value'},
        ),
        completes,
      );
      final result = await vectorDbService.querySimilarEmbeddings(
        queryEmbedding: [0.1, 0.2],
        topK: 5,
      );
      expect(result, isEmpty);
    });
  });
}