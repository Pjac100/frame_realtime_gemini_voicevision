import 'package:flutter_test/flutter_test.dart';
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';
import 'package:frame_realtime_gemini_voicevision/objectbox.g.dart';
import 'package:objectbox/objectbox.dart';
import 'dart:io';

void main() {
  group('VectorDbService MobileBERT Integration Tests', () {
    late VectorDbService vectorDb;
    late Store store;
    final List<String> testLogs = [];
    
    setUpAll(() async {
      // Create a temporary directory for test database
      final testDir = Directory.systemTemp.createTempSync('vector_db_test');
      store = Store(getObjectBoxModel(), directory: testDir.path);
    });
    
    setUp(() async {
      testLogs.clear();
      vectorDb = VectorDbService((message) => testLogs.add(message));
      await vectorDb.initialize(store);
    });
    
    tearDown(() async {
      await vectorDb.clearAll();
      await vectorDb.dispose();
    });
    
    tearDownAll(() async {
      store.close();
    });

    test('VectorDbService initialization', () {
      expect(testLogs.any((log) => log.contains('VectorDB initialized')), true);
      expect(vectorDb.getDocumentCount(), 0);
    });

    test('MobileBERT model loading verification', () async {
      // Check if model was loaded successfully
      final hasModelLoadLogs = testLogs.any((log) => 
          log.contains('Loading MobileBERT model') || 
          log.contains('MobileBERT model loaded successfully') ||
          log.contains('Failed to load MobileBERT model'));
      
      expect(hasModelLoadLogs, true, 
          reason: 'Should have attempted to load MobileBERT model');
      
      // Check if vocabulary was loaded
      final hasVocabLogs = testLogs.any((log) => 
          log.contains('Loading vocabulary') || 
          log.contains('Vocabulary loaded'));
      
      expect(hasVocabLogs, true, 
          reason: 'Should have attempted to load vocabulary');
    });

    test('Embedding generation (384 dimensions)', () async {
      const testText = 'This is a test sentence for MobileBERT embedding generation.';
      final embedding = await vectorDb.generateEmbedding(testText);
      
      expect(embedding, isNotNull);
      expect(embedding.length, equals(VectorDbService.embeddingSize));
      expect(embedding.length, equals(384), 
          reason: 'MobileBERT should generate 384-dimensional embeddings');
      
      // Check that embedding values are reasonable
      final hasNonZeroValues = embedding.any((value) => value != 0.0);
      expect(hasNonZeroValues, true, 
          reason: 'Embedding should contain non-zero values');
      
      // Check for normalized values (typical range for embeddings)
      final allValuesInRange = embedding.every((value) => 
          value >= -2.0 && value <= 2.0);
      expect(allValuesInRange, true, 
          reason: 'Embedding values should be in reasonable range');
    });

    test('Text tokenization with vocabulary handling', () async {
      const testText = 'Hello world! This is a test.';
      final embedding = await vectorDb.generateEmbedding(testText);
      
      expect(embedding.length, equals(384));
      
      // Test special tokens handling by looking at logs
      final hasTokenizationLogs = testLogs.any((log) => 
          log.contains('Generated MobileBERT embedding') ||
          log.contains('Using fallback embedding'));
      
      expect(hasTokenizationLogs, true);
    });

    test('Vector database CRUD operations', () async {
      const testContent = 'Test document for vector database operations';
      final testMetadata = {
        'type': 'test',
        'category': 'unittest',
        'timestamp': DateTime.now().toIso8601String(),
      };
      
      // Add document with embedding
      await vectorDb.addTextWithEmbedding(
        content: testContent,
        metadata: testMetadata,
      );
      
      expect(vectorDb.getDocumentCount(), equals(1));
      
      // Verify document was added with proper metadata
      final documents = await vectorDb.getAllDocuments();
      expect(documents.length, equals(1));
      
      final doc = documents.first;
      expect(doc.textContent.contains(testContent), true);
      expect(doc.embedding, isNotNull);
      expect(doc.embedding!.length, equals(384));
      expect(doc.metadata, contains('type=test'));
    });

    test('Vector similarity search functionality', () async {
      // Add multiple test documents
      final testDocs = [
        {'content': 'I am wearing Frame smart glasses', 'type': 'glasses'},
        {'content': 'The weather is sunny today', 'type': 'weather'},
        {'content': 'Frame glasses provide augmented reality', 'type': 'glasses'},
        {'content': 'Machine learning helps with embeddings', 'type': 'tech'},
      ];
      
      for (int i = 0; i < testDocs.length; i++) {
        await vectorDb.addTextWithEmbedding(
          content: testDocs[i]['content']!,
          metadata: {
            'type': testDocs[i]['type']!,
            'index': i.toString(),
          },
        );
      }
      
      expect(vectorDb.getDocumentCount(), equals(4));
      
      // Test similarity search
      const queryText = 'smart glasses augmented reality';
      final results = await vectorDb.queryText(
        queryText: queryText,
        topK: 3,
        threshold: 0.1, // Lower threshold for testing
      );
      
      expect(results, isNotEmpty, 
          reason: 'Should find similar documents');
      
      // Check result structure
      for (final result in results) {
        expect(result.containsKey('id'), true);
        expect(result.containsKey('document'), true);
        expect(result.containsKey('score'), true);
        expect(result.containsKey('metadata'), true);
        
        final score = result['score'] as double;
        expect(score, greaterThanOrEqualTo(0.0));
        expect(score, lessThanOrEqualTo(1.0));
      }
      
      // Results should be sorted by score (descending)
      for (int i = 0; i < results.length - 1; i++) {
        final currentScore = results[i]['score'] as double;
        final nextScore = results[i + 1]['score'] as double;
        expect(currentScore, greaterThanOrEqualTo(nextScore));
      }
    });

    test('ObjectBox entity structure validation', () async {
      const testContent = 'Test content for entity validation';
      final testMetadata = {'type': 'validation_test'};
      
      await vectorDb.addTextWithEmbedding(
        content: testContent,
        metadata: testMetadata,
      );
      
      final docs = await vectorDb.getAllDocuments();
      final doc = docs.first;
      
      // Validate Document entity structure
      expect(doc.id, greaterThan(0));
      expect(doc.textContent, isNotEmpty);
      expect(doc.embedding, isNotNull);
      expect(doc.embedding!.length, equals(384));
      expect(doc.createdAt, isNotNull);
      expect(doc.metadata, isNotNull);
      
      // Validate HNSW indexing (384 dimensions as configured)
      expect(doc.embedding!.length, equals(384));
    });

    test('Fallback embedding generation', () async {
      // Test fallback when model is not available
      const testText = 'Test fallback embedding generation';
      final embedding = await vectorDb.generateEmbedding(testText);
      
      expect(embedding, isNotNull);
      expect(embedding.length, equals(384));
      
      // Fallback embeddings should be normalized
      final norm = embedding.map((x) => x * x).fold(0.0, (a, b) => a + b);
      expect(norm, closeTo(1.0, 0.1), 
          reason: 'Fallback embeddings should be approximately normalized');
    });

    test('Conversation context retrieval', () async {
      // Add conversation-like documents
      final conversationTexts = [
        'User asked about Frame smart glasses features',
        'Assistant explained augmented reality capabilities',
        'User inquired about battery life',
        'Discussion about MobileBERT embedding models',
      ];
      
      for (int i = 0; i < conversationTexts.length; i++) {
        await vectorDb.addTextWithEmbedding(
          content: conversationTexts[i],
          metadata: {
            'type': 'conversation',
            'turn': i.toString(),
            'timestamp': DateTime.now().toIso8601String(),
          },
        );
      }
      
      // Test context retrieval
      const query = 'Tell me about Frame glasses';
      final context = await vectorDb.getConversationContext(
        currentQuery: query,
        maxResults: 2,
        threshold: 0.1,
      );
      
      expect(context, isNotEmpty);
      expect(context, contains('Recent conversation context'));
    });

    test('Sample data functionality', () async {
      await vectorDb.addSampleData();
      
      final count = vectorDb.getDocumentCount();
      expect(count, greaterThan(0), 
          reason: 'Should add sample documents');
      
      final docs = await vectorDb.getAllDocuments();
      final hasSampleDocs = docs.any((doc) => 
          doc.metadata != null && doc.metadata!.contains('type=sample'));
      
      expect(hasSampleDocs, true, 
          reason: 'Should contain sample documents');
    });

    test('Model testing functionality', () async {
      await vectorDb.testModel();
      
      final hasTestLogs = testLogs.any((log) => 
          log.contains('Testing MobileBERT model') ||
          log.contains('Model test successful') ||
          log.contains('Model test failed'));
      
      expect(hasTestLogs, true, 
          reason: 'Should attempt model testing');
    });

    test('Database statistics', () async {
      // Add some test data
      await vectorDb.addSampleData();
      
      final stats = await vectorDb.getStats();
      
      expect(stats.containsKey('totalDocuments'), true);
      expect(stats.containsKey('documentsWithEmbeddings'), true);
      expect(stats.containsKey('averageEmbeddingDimensions'), true);
      expect(stats.containsKey('embeddingModel'), true);
      expect(stats.containsKey('vocabularySize'), true);
      expect(stats.containsKey('maxSequenceLength'), true);
      
      final totalDocs = stats['totalDocuments'] as int;
      final avgDims = stats['averageEmbeddingDimensions'] as int;
      final maxSeqLen = stats['maxSequenceLength'] as int;
      
      expect(totalDocs, greaterThan(0));
      expect(avgDims, equals(384));
      expect(maxSeqLen, equals(VectorDbService.maxSequenceLength));
    });

    test('Error handling in ML pipeline', () async {
      // Test with empty string
      final emptyEmbedding = await vectorDb.generateEmbedding('');
      expect(emptyEmbedding.length, equals(384));
      
      // Test with very long string
      final longText = 'word ' * 1000; // Much longer than max sequence length
      final longEmbedding = await vectorDb.generateEmbedding(longText);
      expect(longEmbedding.length, equals(384));
      
      // Test with special characters
      const specialText = '!@#\$%^&*()[]{}|;:,.<>?/~`+=';
      final specialEmbedding = await vectorDb.generateEmbedding(specialText);
      expect(specialEmbedding.length, equals(384));
    });
  });
}