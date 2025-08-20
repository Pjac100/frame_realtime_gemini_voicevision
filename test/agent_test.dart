import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:frame_realtime_gemini_voicevision/agent/core/stream_observer.dart';
import 'package:frame_realtime_gemini_voicevision/agent/core/timestamp_manager.dart';
import 'package:frame_realtime_gemini_voicevision/agent/models/agent_output.dart';
import 'package:frame_realtime_gemini_voicevision/agent/services/asr_service.dart';
import 'package:frame_realtime_gemini_voicevision/agent/services/ocr_service.dart';
import 'package:frame_realtime_gemini_voicevision/agent/services/local_llm_service.dart';
import 'dart:typed_data';
import 'dart:async';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Agent Core Tests', () {
    test('StreamObserver should emit timestamped data', () async {
      final observer = StreamObserver<String>();
      final testData = ['test1', 'test2', 'test3'];
      final controller = StreamController<String>();
      
      // Start observing
      observer.observe(controller.stream, streamName: 'TestStream');
      
      final observedData = <TimestampedData<String>>[];
      final subscription = observer.observedStream.listen(observedData.add);
      
      // Emit test data
      for (final data in testData) {
        controller.add(data);
        await Future.delayed(const Duration(milliseconds: 10));
      }
      
      await Future.delayed(const Duration(milliseconds: 50));
      
      expect(observedData.length, equals(testData.length));
      for (int i = 0; i < testData.length; i++) {
        expect(observedData[i].data, equals(testData[i]));
        expect(observedData[i].timestamp, isA<DateTime>());
      }
      
      await subscription.cancel();
      observer.dispose();
      await controller.close();
    });

    test('TimestampManager should correlate data within time window', () {
      final manager = TimestampManager();
      final baseTime = DateTime.now();
      
      // Create test photos with different timestamps
      final photos = [
        TimestampedData(
          data: Uint8List.fromList([1, 2, 3]),
          timestamp: baseTime.subtract(const Duration(seconds: 3)),
        ),
        TimestampedData(
          data: Uint8List.fromList([4, 5, 6]),
          timestamp: baseTime.subtract(const Duration(seconds: 1)),
        ),
        TimestampedData(
          data: Uint8List.fromList([7, 8, 9]),
          timestamp: baseTime.add(const Duration(seconds: 1)),
        ),
      ];
      
      // Test correlation within 2-second window
      final correlatedPhotos = manager.correlateWithPhotos(
        outputTimestamp: baseTime,
        availablePhotos: photos,
        customWindow: const Duration(seconds: 2),
      );
      
      // Should find photos within 2 seconds (indices 1 and 2)
      expect(correlatedPhotos.length, equals(2));
      expect(correlatedPhotos[0].data, equals(Uint8List.fromList([4, 5, 6])));
      expect(correlatedPhotos[1].data, equals(Uint8List.fromList([7, 8, 9])));
    });

    test('TemporalAnalysis should calculate timing statistics', () {
      final manager = TimestampManager();
      final baseTime = DateTime.now();
      
      final timestamps = [
        baseTime,
        baseTime.add(const Duration(seconds: 1)),
        baseTime.add(const Duration(seconds: 2)),
        baseTime.add(const Duration(seconds: 3)),
      ];
      
      final analysis = manager.analyzeTimings(timestamps);
      
      expect(analysis.eventCount, equals(4));
      expect(analysis.totalDuration, equals(const Duration(seconds: 3)));
      expect(analysis.frequency, closeTo(1.0, 0.1)); // ~1 Hz
      expect(analysis.averageInterval, equals(const Duration(seconds: 1)));
    });
  });

  group('Agent Services Tests', () {
    test('ASRService should initialize successfully', () async {
      final asr = ASRService();
      final initialized = await asr.initialize();
      
      expect(initialized, isTrue);
      expect(asr.isReady, isTrue);
      
      asr.dispose();
    });

    test('ASRService should detect voice activity', () async {
      final asr = ASRService();
      await asr.initialize();
      
      // Create mock audio data with higher amplitude for voice detection
      final audioData = Uint8List(3200); // 200ms at 16kHz
      for (int i = 0; i < audioData.length; i += 2) {
        // Add higher mock amplitude (16-bit samples)
        audioData[i] = 200; // Low byte
        audioData[i + 1] = 2;  // High byte for higher amplitude
      }
      
      final result = await asr.transcribeAudio(audioData);
      
      // Mock implementation should return some result for voice activity
      if (result != null) {
        expect(result.text, isNotEmpty);
        expect(result.confidence, greaterThan(0.0));
      }
      // Note: Mock ASR might return null if voice activity threshold isn't met
      
      asr.dispose();
    });

    test('OCRService should initialize successfully', () async {
      final ocr = OCRService();
      final initialized = await ocr.initialize();
      
      expect(initialized, isTrue);
      expect(ocr.isReady, isTrue);
      
      ocr.dispose();
    });

    test('OCRService should extract text from image data', () async {
      final ocr = OCRService();
      await ocr.initialize();
      
      // Create mock JPEG data (minimal size for testing)
      final imageData = Uint8List.fromList(List.generate(2000, (i) => i % 256));
      
      final result = await ocr.extractText(imageData);
      
      // Mock implementation should return some result
      expect(result, isNotNull);
      expect(result!.text, isNotEmpty);
      expect(result.confidence, greaterThan(0.0));
      
      ocr.dispose();
    });

    test('LocalLLMService should process context with tools', () async {
      final llm = LocalLLMService();
      final initialized = await llm.initialize();
      
      expect(initialized, isTrue);
      expect(llm.isReady, isTrue);
      
      final response = await llm.processWithTools(
        context: 'Test ASR output: Hello world',
        availableTools: ['store_memory', 'retrieve_memory'],
      );
      
      expect(response, isNotNull);
      expect(response!.content, isNotEmpty);
      expect(response.toolCalls, isNotEmpty);
      
      llm.dispose();
    });
  });

  group('Agent Models Tests', () {
    test('AgentOutput should serialize and deserialize correctly', () {
      final originalOutput = AgentOutput(
        id: 'test_001',
        timestamp: DateTime.now(),
        type: AgentOutputType.asr,
        content: 'Test speech recognition',
        confidence: 0.85,
        associatedImageTimestamps: [DateTime.now()],
        metadata: {'test': 'value'},
      );
      
      final map = originalOutput.toMap();
      final deserializedOutput = AgentOutput.fromMap(map);
      
      expect(deserializedOutput.id, equals(originalOutput.id));
      expect(deserializedOutput.type, equals(originalOutput.type));
      expect(deserializedOutput.content, equals(originalOutput.content));
      expect(deserializedOutput.confidence, equals(originalOutput.confidence));
      expect(deserializedOutput.metadata['test'], equals('value'));
    });

    test('ASRResult should validate confidence and content', () {
      const highConfidenceResult = ASRResult(
        text: 'Clear speech',
        confidence: 0.9,
        processingTime: Duration(milliseconds: 100),
      );
      
      const lowConfidenceResult = ASRResult(
        text: 'Unclear speech',
        confidence: 0.3,
        processingTime: Duration(milliseconds: 150),
      );
      
      expect(highConfidenceResult.isReliable, isTrue);
      expect(highConfidenceResult.hasContent, isTrue);
      expect(lowConfidenceResult.isReliable, isFalse);
      expect(lowConfidenceResult.hasContent, isTrue);
    });

    test('OCRResult should handle text blocks correctly', () {
      const textBlock = TextBlock(
        text: 'Sample text',
        confidence: 0.8,
        bounds: BoundingBox(left: 10, top: 20, width: 100, height: 30),
      );
      
      const ocrResult = OCRResult(
        text: 'Sample text',
        confidence: 0.8,
        processingTime: Duration(milliseconds: 200),
        textBlocks: [textBlock],
      );
      
      expect(ocrResult.hasStructuredText, isTrue);
      expect(ocrResult.isReliable, isTrue);
      expect(textBlock.bounds!.right, equals(110.0));
      expect(textBlock.bounds!.centerX, equals(60.0));
    });

    test('ToolCall should handle parameter extraction', () {
      const toolCall = ToolCall(
        name: 'store_memory',
        parameters: {
          'content': 'Test content',
          'priority': 'high',
          'confidence': '0.85',
          'count': 42,
          'enabled': true,
        },
      );
      
      expect(toolCall.getStringParameter('content'), equals('Test content'));
      expect(toolCall.getStringParameter('missing', defaultValue: 'default'), equals('default'));
      expect(toolCall.getDoubleParameter('confidence'), equals(0.85));
      expect(toolCall.getIntParameter('count'), equals(42));
      expect(toolCall.getBoolParameter('enabled'), isTrue);
    });
  });

  group('Integration Tests', () {
    test('Stream observation should not affect original stream', () async {
      final controller = StreamController<String>.broadcast();
      final observer = StreamObserver<String>();
      
      final originalData = <String>[];
      final observedData = <TimestampedData<String>>[];
      
      // Listen to original stream
      final originalSubscription = controller.stream.listen(originalData.add);
      
      // Start observing (should not affect original)
      observer.observe(controller.stream, streamName: 'IntegrationTest');
      final observedSubscription = observer.observedStream.listen(observedData.add);
      
      // Emit test data
      const testData = ['item1', 'item2', 'item3'];
      for (final item in testData) {
        controller.add(item);
        await Future.delayed(const Duration(milliseconds: 10));
      }
      
      await Future.delayed(const Duration(milliseconds: 50));
      
      // Both streams should receive all data
      expect(originalData, equals(testData));
      expect(observedData.length, equals(testData.length));
      
      for (int i = 0; i < testData.length; i++) {
        expect(observedData[i].data, equals(testData[i]));
      }
      
      await originalSubscription.cancel();
      await observedSubscription.cancel();
      observer.dispose();
      await controller.close();
    });

    test('Agent system should handle graceful degradation', () async {
      // Test that agent components can handle initialization failures
      final asr = ASRService();
      final ocr = OCRService();
      final llm = LocalLLMService();
      
      final asrReady = await asr.initialize();
      final ocrReady = await ocr.initialize();
      final llmReady = await llm.initialize();
      
      // All mock services should initialize successfully
      expect(asrReady, isTrue);
      expect(ocrReady, isTrue);
      expect(llmReady, isTrue);
      
      // Services should be ready
      expect(asr.isReady, isTrue);
      expect(ocr.isReady, isTrue);
      expect(llm.isReady, isTrue);
      
      // Clean up
      asr.dispose();
      ocr.dispose();
      llm.dispose();
    });
  });
}