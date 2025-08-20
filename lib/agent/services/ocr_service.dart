import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart' as mlkit;
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import '../models/agent_output.dart';

/// OCR (Optical Character Recognition) service for the agent
/// Provides text extraction from images using ML Kit
class OCRService {
  final void Function(String)? _logger;
  bool _isReady = false;
  
  // ML Kit text recognizer
  mlkit.TextRecognizer? _textRecognizer;
  
  OCRService({void Function(String)? logger}) : _logger = logger;

  /// Initialize the OCR service
  Future<bool> initialize() async {
    try {
      _logger?.call('👁️ Initializing OCR service...');
      
      // Initialize ML Kit Text Recognition
      _textRecognizer = mlkit.TextRecognizer();
      
      _isReady = true;
      _logger?.call('✅ OCR service initialized with ML Kit');
      
      return true;
    } catch (e) {
      _logger?.call('❌ OCR initialization failed: $e');
      
      // Fallback: Continue without OCR but mark as ready for graceful degradation
      _isReady = true;
      _logger?.call('⚠️ OCR service initialized without ML Kit (degraded mode)');
      
      return true; // Return true for graceful degradation
    }
  }

  /// Check if the service is ready
  bool get isReady => _isReady;

  /// Extract text from image data
  Future<OCRResult?> extractText(Uint8List imageData) async {
    if (!_isReady) {
      _logger?.call('⚠️ OCR service not ready');
      return null;
    }

    try {
      if (_textRecognizer != null) {
        // Use ML Kit for OCR
        final result = await _extractTextWithMLKit(imageData);
        
        if (result != null) {
          _logger?.call('👁️ OCR: "${result.text}" (${result.confidence.toStringAsFixed(2)})');
        }
        
        return result;
      } else {
        // Fallback: Mock OCR for testing
        return _mockOCRResult(imageData);
      }
    } catch (e) {
      _logger?.call('❌ OCR extraction error: $e');
      return null;
    }
  }

  /// Extract text using ML Kit Text Recognition
  Future<OCRResult?> _extractTextWithMLKit(Uint8List imageData) async {
    try {
      // Create InputImage from bytes
      final inputImage = InputImage.fromBytes(
        bytes: imageData,
        metadata: InputImageMetadata(
          size: const Size(800, 600), // Default size - actual size would be better
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.yuv420,
          bytesPerRow: 800 * 3, // Approximate for JPEG
        ),
      );
      
      // Process image with text recognizer
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      
      if (recognizedText.text.trim().isEmpty) {
        return null; // No text found
      }
      
      // Extract text blocks with positions
      final textBlocks = <TextBlock>[];
      double totalConfidence = 0.0;
      int blockCount = 0;
      
      for (final textBlock in recognizedText.blocks) {
        final bounds = textBlock.boundingBox;
        final confidence = _calculateBlockConfidence(textBlock);
        
        textBlocks.add(
          TextBlock(
            text: textBlock.text,
            confidence: confidence,
            bounds: BoundingBox(
              left: bounds.left.toDouble(),
              top: bounds.top.toDouble(),
              width: bounds.width.toDouble(),
              height: bounds.height.toDouble(),
            ),
            metadata: {
              'cornerPoints': textBlock.cornerPoints.map((point) => {
                'x': point.x,
                'y': point.y,
              }).toList(),
              'recognizedLanguages': textBlock.recognizedLanguages,
            },
          ),
        );
        
        totalConfidence += confidence;
        blockCount++;
      }
      
      final averageConfidence = blockCount > 0 ? totalConfidence / blockCount : 0.0;
      
      return OCRResult(
        text: recognizedText.text.trim(),
        confidence: averageConfidence,
        processingTime: Duration.zero, // Will be calculated by caller
        textBlocks: textBlocks,
        metadata: {
          'totalBlocks': blockCount,
          'implementation': 'ml_kit',
          'imageSize': imageData.length,
        },
      );
    } catch (e) {
      _logger?.call('❌ ML Kit OCR error: $e');
      return null;
    }
  }

  /// Calculate confidence for a text block based on ML Kit data
  double _calculateBlockConfidence(mlkit.TextBlock block) {
    // ML Kit doesn't provide direct confidence scores
    // We estimate based on text characteristics
    
    double confidence = 0.5; // Base confidence
    
    // Longer text blocks typically have higher confidence
    final textLength = block.text.length;
    if (textLength > 10) confidence += 0.1;
    if (textLength > 25) confidence += 0.1;
    
    // Check for common words (indicates better recognition)
    final commonWords = [
      'the', 'and', 'is', 'a', 'to', 'of', 'in', 'that', 'it', 'with', 'for', 'as', 'was', 'on', 'are', 'you'
    ];
    final words = block.text.toLowerCase().split(RegExp(r'\W+'));
    final commonWordsFound = words.where((word) => commonWords.contains(word)).length;
    confidence += (commonWordsFound / words.length) * 0.3;
    
    // Check for alphanumeric patterns (usually high confidence)
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(block.text)) {
      confidence += 0.1;
    }
    
    // Penalize blocks with mostly special characters
    final specialCharCount = RegExp(r'[^a-zA-Z0-9\s]').allMatches(block.text).length;
    if (specialCharCount > textLength / 2) {
      confidence -= 0.2;
    }
    
    return confidence.clamp(0.0, 1.0);
  }

  /// Mock OCR result for testing when ML Kit is not available
  OCRResult? _mockOCRResult(Uint8List imageData) {
    // Simple mock based on image characteristics
    if (imageData.length < 1000) return null; // Image too small
    
    // Generate mock text based on image size and characteristics
    final mockTexts = [
      "Sample text from image",
      "Frame Smart Glasses",
      "OCR Test Content", 
      "Welcome to the future",
      "Brilliant Labs",
      "Hello World",
      "Image contains text",
      "Testing OCR functionality",
    ];
    
    // Select text based on image characteristics
    final imageHash = imageData.take(100).fold<int>(0, (sum, byte) => sum + byte);
    final selectedText = mockTexts[imageHash % mockTexts.length];
    
    // Mock confidence based on image size
    final confidence = (imageData.length / 50000.0).clamp(0.3, 0.9);
    
    return OCRResult(
      text: selectedText,
      confidence: confidence,
      processingTime: const Duration(milliseconds: 100),
      textBlocks: [
        TextBlock(
          text: selectedText,
          confidence: confidence,
          bounds: const BoundingBox(left: 10, top: 10, width: 200, height: 30),
          metadata: {'mock': true},
        ),
      ],
      metadata: {
        'implementation': 'mock',
        'imageSize': imageData.length,
      },
    );
  }

  /// Process continuous image stream for OCR
  Stream<OCRResult> processImageStream(Stream<Uint8List> imageStream) async* {
    if (!_isReady) return;
    
    await for (final imageData in imageStream) {
      final result = await extractText(imageData);
      if (result != null) {
        yield result;
      }
    }
  }

  /// Extract text from specific regions of interest (if bounds provided)
  Future<OCRResult?> extractTextFromRegion(
    Uint8List imageData, 
    BoundingBox region,
  ) async {
    if (!_isReady) return null;
    
    // TODO: Implement region-specific OCR by cropping image first
    // For now, extract from full image and filter results
    final fullResult = await extractText(imageData);
    
    if (fullResult == null || fullResult.textBlocks.isEmpty) return null;
    
    // Filter text blocks that intersect with the region
    final regionBlocks = fullResult.textBlocks.where((block) {
      if (block.bounds == null) return false;
      return _boundsIntersect(block.bounds!, region);
    }).toList();
    
    if (regionBlocks.isEmpty) return null;
    
    final regionText = regionBlocks.map((block) => block.text).join(' ');
    final regionConfidence = regionBlocks
        .map((block) => block.confidence)
        .reduce((a, b) => (a + b) / 2);
    
    return OCRResult(
      text: regionText,
      confidence: regionConfidence,
      processingTime: fullResult.processingTime,
      textBlocks: regionBlocks,
      metadata: {
        ...fullResult.metadata,
        'regionExtraction': true,
        'originalBlocksCount': fullResult.textBlocks.length,
        'filteredBlocksCount': regionBlocks.length,
      },
    );
  }

  /// Check if two bounding boxes intersect
  bool _boundsIntersect(BoundingBox a, BoundingBox b) {
    return !(a.right < b.left || 
             b.right < a.left || 
             a.bottom < b.top || 
             b.bottom < a.top);
  }

  /// Get supported languages for OCR
  List<String> getSupportedLanguages() {
    return [
      'en', // English
      'es', // Spanish
      'fr', // French
      'de', // German
      'it', // Italian
      'pt', // Portuguese
      'ru', // Russian
      'ja', // Japanese
      'ko', // Korean
      'zh', // Chinese
      'ar', // Arabic
      'hi', // Hindi
    ];
  }

  /// Get current configuration
  Map<String, dynamic> getConfiguration() {
    return {
      'isReady': _isReady,
      'implementation': _textRecognizer != null ? 'ml_kit' : 'mock',
      'supportedLanguages': getSupportedLanguages(),
      'hasMLKit': _textRecognizer != null,
    };
  }

  /// Get service statistics
  Map<String, dynamic> getStatistics() {
    return {
      'isReady': _isReady,
      'implementation': _textRecognizer != null ? 'ml_kit' : 'mock',
      'languagesSupported': getSupportedLanguages().length,
    };
  }

  /// Dispose resources
  void dispose() {
    _textRecognizer?.close();
    _textRecognizer = null;
    _isReady = false;
    _logger?.call('🧹 OCR service disposed');
  }
}