import 'dart:developer';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:frame_realtime_gemini_voicevision/utils/bert_tokenizer.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:math' as math;

/// A service that handles on-device text embedding using the low-level TFLite interpreter.
class LocalEmbeddingService {
  late Interpreter _interpreter;
  late BertTokenizer _tokenizer;
  bool _isInitialized = false;

  static const int _maxLength = 128; // Standard for MobileBERT

  LocalEmbeddingService();

  /// Loads the TFLite model and tokenizer, then initializes the interpreter.
  Future<void> initialize() async {
    if (_isInitialized) {
      log('LocalEmbeddingService is already initialized.');
      return;
    }
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobilebert_embedding.tflite',
        options: InterpreterOptions()..threads = 2,
      );

      _tokenizer = await BertTokenizer.create(
        vocabPath: 'assets/models/vocab.txt',
        maxLength: _maxLength,
      );

      _isInitialized = true;
      log('LocalEmbeddingService initialized successfully.');
    } catch (e) {
      log('Failed to initialize LocalEmbeddingService: $e');
      _isInitialized = false;
    }
  }

  bool get isInitialized => _isInitialized;

  /// Generates a normalized embedding vector for the given text.
  Future<List<double>?> getEmbedding(String text) async {
    if (!_isInitialized) {
      log('Error: Interpreter is not initialized.');
      return null;
    }

    try {
      // 1. Tokenize the input text
      final tokenized = _tokenizer.tokenize(text);

      // 2. Prepare model inputs
      // TFLite interpreter expects inputs as a List of objects.
      final inputs = [
        [tokenized['input_ids']!],
        [tokenized['attention_mask']!],
        [tokenized['token_type_ids']!],
      ];

      // 3. Prepare model outputs
      // The model outputs a single embedding vector of shape [1, 384].
      final outputShape = [1, 384];
      final outputs = {
        0: List.generate(
            outputShape[0], (i) => List<double>.filled(outputShape[1], 0.0)),
      };

      // 4. Run inference
      _interpreter.runForMultipleInputs(inputs, outputs);

      // 5. Extract and normalize the result
      final embedding = outputs[0]![0].cast<double>();
      return _l2Normalize(embedding);
    } catch (e) {
      log('Error getting embedding: $e');
      return null;
    }
  }

  /// Normalizes a vector to unit length (L2 normalization).
  List<double> _l2Normalize(List<double> vector) {
    double norm = 0.0;
    for (final double val in vector) {
      norm += val * val;
    }
    norm = 1.0 / math.sqrt(norm);

    return vector.map((val) => val * norm).toList();
  }

  /// Closes the interpreter and releases resources.
  void close() {
    if (_isInitialized) {
      _interpreter.close();
      _isInitialized = false;
      log('LocalEmbeddingService closed.');
    }
  }
}
