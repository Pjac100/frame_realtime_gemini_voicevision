import 'dart:async';
import 'dart:typed_data';
import '../models/agent_output.dart';

/// ASR (Automatic Speech Recognition) service for the agent
/// Provides speech-to-text capabilities using on-device recognition
class ASRService {
  final void Function(String)? _logger;
  bool _isReady = false;
  
  // ASR configuration
  static const int sampleRate = 16000; // Expected sample rate
  static const int minAudioLength = 1600; // Minimum audio length (100ms at 16kHz)
  static const double silenceThreshold = 0.01; // Voice activity threshold
  
  ASRService({void Function(String)? logger}) : _logger = logger;

  /// Initialize the ASR service
  Future<bool> initialize() async {
    try {
      _logger?.call('🎤 Initializing ASR service...');
      
      // TODO: Initialize actual ASR engine (e.g., Google Speech, Apple Speech, etc.)
      // For now, we'll use a mock implementation
      
      await Future.delayed(const Duration(milliseconds: 300)); // Simulate initialization
      
      _isReady = true;
      _logger?.call('✅ ASR service initialized (mock implementation)');
      
      return true;
    } catch (e) {
      _logger?.call('❌ ASR initialization failed: $e');
      return false;
    }
  }

  /// Check if the service is ready
  bool get isReady => _isReady;

  /// Transcribe audio data to text
  Future<ASRResult?> transcribeAudio(Uint8List audioData) async {
    if (!_isReady) {
      _logger?.call('⚠️ ASR service not ready');
      return null;
    }

    if (audioData.length < minAudioLength) {
      // Audio too short for reliable transcription
      return null;
    }

    try {
      // Check for voice activity
      if (!_hasVoiceActivity(audioData)) {
        return null; // No voice detected
      }

      // Mock transcription (replace with actual ASR implementation)
      final result = await _mockTranscription(audioData);
      
      if (result != null) {
        _logger?.call('🎤 ASR: "${result.text}" (${result.confidence.toStringAsFixed(2)})');
      }
      
      return result;
    } catch (e) {
      _logger?.call('❌ ASR transcription error: $e');
      return null;
    }
  }

  /// Check for voice activity in audio data
  bool _hasVoiceActivity(Uint8List audioData) {
    if (audioData.length < 2) return false;

    // Convert bytes to 16-bit samples
    final samples = Int16List.view(audioData.buffer);
    
    // Calculate RMS (Root Mean Square) energy
    double sum = 0.0;
    for (final sample in samples) {
      sum += sample * sample;
    }
    
    final rms = sum / samples.length.toDouble();
    final normalizedRms = rms / (32768.0 * 32768.0); // Normalize to 0-1 range
    
    return normalizedRms > silenceThreshold;
  }

  /// Mock transcription implementation (replace with actual ASR)
  Future<ASRResult?> _mockTranscription(Uint8List audioData) async {
    // Simulate processing time based on audio length
    final processingMs = 50 + (audioData.length ~/ 1000);
    await Future.delayed(Duration(milliseconds: processingMs));
    
    // Calculate mock confidence based on audio characteristics
    final confidence = _calculateMockConfidence(audioData);
    
    // Generate mock transcription based on audio characteristics
    final transcription = _generateMockTranscription(audioData, confidence);
    
    if (transcription.isEmpty) return null;
    
    return ASRResult(
      text: transcription,
      confidence: confidence,
      processingTime: Duration(milliseconds: processingMs),
      metadata: {
        'audioLength': audioData.length,
        'sampleRate': sampleRate,
        'mockImplementation': true,
      },
    );
  }

  /// Calculate mock confidence based on audio characteristics
  double _calculateMockConfidence(Uint8List audioData) {
    if (audioData.length < 2) return 0.0;

    final samples = Int16List.view(audioData.buffer);
    
    // Calculate audio characteristics
    double sum = 0.0;
    double maxAmplitude = 0.0;
    
    for (final sample in samples) {
      final amplitude = sample.abs().toDouble();
      sum += amplitude;
      if (amplitude > maxAmplitude) {
        maxAmplitude = amplitude;
      }
    }
    
    final averageAmplitude = sum / samples.length.toDouble();
    final normalizedMax = maxAmplitude / 32768.0;
    final normalizedAvg = averageAmplitude / 32768.0;
    
    // Mock confidence calculation
    double confidence = 0.3; // Base confidence
    
    // Higher amplitude generally means clearer speech
    if (normalizedMax > 0.1) confidence += 0.2;
    if (normalizedAvg > 0.05) confidence += 0.2;
    
    // Longer audio generally has better recognition
    if (audioData.length > 8000) confidence += 0.1; // >500ms
    if (audioData.length > 16000) confidence += 0.1; // >1s
    
    // Add some randomness to simulate real-world variance
    final randomFactor = (DateTime.now().millisecondsSinceEpoch % 100) / 500.0 - 0.1;
    confidence += randomFactor;
    
    return confidence.clamp(0.0, 1.0);
  }

  /// Generate mock transcription text
  String _generateMockTranscription(Uint8List audioData, double confidence) {
    // List of possible transcriptions based on confidence and characteristics
    final highConfidenceTexts = [
      "Hello, can you hear me?",
      "What's the weather like today?",
      "I'm looking at something interesting",
      "Frame is working perfectly",
      "This is a test of the speech recognition",
      "The quick brown fox jumps over the lazy dog",
      "I need help with this task",
      "Can you see what I'm looking at?",
    ];
    
    final mediumConfidenceTexts = [
      "Hello there",
      "What is this",
      "Frame device",
      "Looking good",
      "Test speech",
      "Help me",
      "I can see",
      "Working well",
    ];
    
    final lowConfidenceTexts = [
      "Hello",
      "Yes",
      "Frame",
      "Good",
      "Test",
      "Help",
      "See",
      "Work",
    ];
    
    List<String> candidateTexts;
    if (confidence > 0.7) {
      candidateTexts = highConfidenceTexts;
    } else if (confidence > 0.4) {
      candidateTexts = mediumConfidenceTexts;
    } else if (confidence > 0.2) {
      candidateTexts = lowConfidenceTexts;
    } else {
      return ''; // Too low confidence
    }
    
    // Select text based on audio characteristics
    final index = (audioData.length + DateTime.now().millisecond) % candidateTexts.length;
    return candidateTexts[index];
  }

  /// Process continuous audio stream (for streaming recognition)
  Stream<ASRResult> processAudioStream(Stream<Uint8List> audioStream) async* {
    if (!_isReady) return;
    
    await for (final audioChunk in audioStream) {
      final result = await transcribeAudio(audioChunk);
      if (result != null) {
        yield result;
      }
    }
  }

  /// Get supported languages (mock implementation)
  List<String> getSupportedLanguages() {
    return [
      'en-US', // English (US)
      'en-GB', // English (UK)
      'es-ES', // Spanish
      'fr-FR', // French
      'de-DE', // German
      'it-IT', // Italian
      'pt-BR', // Portuguese (Brazil)
      'ja-JP', // Japanese
      'ko-KR', // Korean
      'zh-CN', // Chinese (Simplified)
    ];
  }

  /// Get current configuration
  Map<String, dynamic> getConfiguration() {
    return {
      'sampleRate': sampleRate,
      'minAudioLength': minAudioLength,
      'silenceThreshold': silenceThreshold,
      'supportedLanguages': getSupportedLanguages(),
      'isReady': _isReady,
    };
  }

  /// Get service statistics
  Map<String, dynamic> getStatistics() {
    return {
      'isReady': _isReady,
      'implementation': 'mock_asr',
      'sampleRate': sampleRate,
      'languagesSupported': getSupportedLanguages().length,
    };
  }

  /// Dispose resources
  void dispose() {
    _isReady = false;
    _logger?.call('🧹 ASR service disposed');
  }
}