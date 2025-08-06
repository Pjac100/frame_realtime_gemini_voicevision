// lib/services/frame_gemini_audio_integration.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'frame_audio_streaming_service.dart';

/// Example integration between Frame audio and Gemini AI
/// This shows how to properly connect the audio stream to speech recognition
class FrameGeminiAudioIntegration {
  final FrameAudioStreamingService _audioService;
  final GenerativeModel _geminiModel;
  final void Function(String) _logger;
  
  // Audio buffering for speech recognition
  final List<Uint8List> _audioBuffer = [];
  int _bufferSizeBytes = 0;
  static const int _maxBufferSize = 32000; // 2 seconds at 16kHz/8-bit
  
  // Voice activity detection
  bool _isVoiceActive = false;
  // DateTime? _voiceStartTime; // TODO: Use for voice timing analytics
  // DateTime? _voiceEndTime;   // TODO: Use for voice timing analytics
  static const Duration _silenceThreshold = Duration(milliseconds: 500);
  
  Timer? _silenceTimer;
  StreamSubscription<Uint8List>? _audioSubscription;
  
  FrameGeminiAudioIntegration({
    required FrameAudioStreamingService audioService,
    required GenerativeModel geminiModel,
    required void Function(String) logger,
  }) : _audioService = audioService,
       _geminiModel = geminiModel,
       _logger = logger;

  /// Start listening to Frame audio and processing with Gemini
  void startListening() {
    _logger('🎧 Starting Frame-Gemini audio integration');
    
    _audioSubscription = _audioService.audioStream.listen(_processAudioChunk);
  }

  /// Process incoming audio chunks from Frame
  void _processAudioChunk(Uint8List audioData) {
    // Add to buffer
    _audioBuffer.add(audioData);
    _bufferSizeBytes += audioData.length;
    
    // Detect voice activity
    final hasVoice = FrameAudioProcessor.detectVoiceActivity(
      audioData, 
      _audioService.audioConfig['bitDepth'] as int,
    );
    
    if (hasVoice) {
      _handleVoiceDetected();
    } else {
      _handleSilence();
    }
    
    // Prevent buffer overflow
    if (_bufferSizeBytes > _maxBufferSize) {
      _trimBuffer();
    }
  }

  /// Handle voice detection
  void _handleVoiceDetected() {
    if (!_isVoiceActive) {
      _isVoiceActive = true;
      // _voiceStartTime = DateTime.now(); // TODO: Use for timing analytics
      _logger('🗣️ Voice started');
    }
    
    // Cancel any pending silence timer
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Handle silence detection
  void _handleSilence() {
    if (_isVoiceActive && _silenceTimer == null) {
      // Start silence timer
      _silenceTimer = Timer(_silenceThreshold, () {
        // _voiceEndTime = DateTime.now(); // TODO: Use for timing analytics
        _isVoiceActive = false;
        _logger('🤫 Voice ended - processing speech');
        
        // Process the buffered audio
        _processSpeechSegment();
      });
    }
  }

  /// Process a complete speech segment
  Future<void> _processSpeechSegment() async {
    if (_audioBuffer.isEmpty) return;
    
    try {
      // Combine audio buffers
      final totalSize = _audioBuffer.fold<int>(0, (sum, chunk) => sum + chunk.length);
      final combinedAudio = Uint8List(totalSize);
      int offset = 0;
      for (final chunk in _audioBuffer) {
        combinedAudio.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      
      // Calculate duration
      final sampleRate = _audioService.audioConfig['sampleRate'] as int;
      final bitDepth = _audioService.audioConfig['bitDepth'] as int;
      final bytesPerSecond = sampleRate * (bitDepth / 8);
      final durationSeconds = totalSize / bytesPerSecond;
      
      _logger('🎵 Processing ${durationSeconds.toStringAsFixed(1)}s of audio');
      
      // Here's where you would integrate with a speech-to-text service
      // For now, we'll simulate it
      await _simulateSpeechToText(combinedAudio, durationSeconds);
      
      // Clear buffer after processing
      _clearBuffer();
      
    } catch (e) {
      _logger('❌ Error processing speech: $e');
      _clearBuffer();
    }
  }

  /// Simulate speech-to-text processing
  /// In a real implementation, this would send audio to a STT service
  Future<void> _simulateSpeechToText(Uint8List audioData, double duration) async {
    _logger('🔄 Converting speech to text...');
    
    // Simulate processing delay
    await Future.delayed(Duration(milliseconds: (duration * 200).round()));
    
    // In a real app, you would:
    // 1. Convert PCM to a format your STT service accepts (e.g., WAV)
    // 2. Send to STT service (Google Speech-to-Text, Whisper API, etc.)
    // 3. Get transcription result
    
    // For demo, we'll just generate a sample transcription
    const sampleTranscript = "Hello, I'm testing the Frame audio integration";
    _logger('📝 Transcription: "$sampleTranscript"');
    
    // Send to Gemini for response
    await _sendToGemini(sampleTranscript);
  }

  /// Send transcribed text to Gemini and get response
  Future<void> _sendToGemini(String transcript) async {
    try {
      _logger('🤖 Sending to Gemini: "$transcript"');
      
      final response = await _geminiModel.generateContent([
        Content.text(transcript)
      ]);
      
      final responseText = response.text;
      if (responseText != null) {
        _logger('💬 Gemini response: "$responseText"');
        
        // Here you would:
        // 1. Send response text to Frame display
        // 2. Optionally use TTS to speak the response
        await _displayOnFrame(responseText);
      }
      
    } catch (e) {
      _logger('❌ Gemini error: $e');
    }
  }

  /// Display text on Frame glasses
  Future<void> _displayOnFrame(String text) async {
    // Truncate to fit Frame display
    final displayText = text.length > 50 
        ? '${text.substring(0, 47)}...' 
        : text;
    
    await _audioService.sendDisplayText(displayText);
  }

  /// Trim buffer to prevent overflow
  void _trimBuffer() {
    while (_bufferSizeBytes > _maxBufferSize && _audioBuffer.isNotEmpty) {
      final removed = _audioBuffer.removeAt(0);
      _bufferSizeBytes -= removed.length;
    }
    _logger('⚠️ Audio buffer trimmed to prevent overflow');
  }

  /// Clear the audio buffer
  void _clearBuffer() {
    _audioBuffer.clear();
    _bufferSizeBytes = 0;
  }

  /// Stop listening and cleanup
  void stopListening() {
    _logger('🛑 Stopping Frame-Gemini audio integration');
    
    _audioSubscription?.cancel();
    _silenceTimer?.cancel();
    _clearBuffer();
  }

  /// Get current status
  Map<String, dynamic> get status => {
    'isListening': _audioSubscription != null,
    'isVoiceActive': _isVoiceActive,
    'bufferSize': _bufferSizeBytes,
    'bufferChunks': _audioBuffer.length,
  };
}

/// Helper class to convert Frame PCM audio to WAV format
/// This is needed for most speech-to-text services
class WavEncoder {
  /// Encode PCM data to WAV format
  static Uint8List encodeWav(Uint8List pcmData, int sampleRate, int bitDepth) {
    const channels = 1; // Frame is mono
    final byteRate = sampleRate * channels * (bitDepth ~/ 8);
    final blockAlign = channels * (bitDepth ~/ 8);
    final dataSize = pcmData.length;
    final fileSize = 44 + dataSize - 8; // WAV header is 44 bytes
    
    final wav = ByteData(44 + dataSize);
    int offset = 0;
    
    // RIFF header
    wav.setUint8(offset++, 0x52); // 'R'
    wav.setUint8(offset++, 0x49); // 'I'
    wav.setUint8(offset++, 0x46); // 'F'
    wav.setUint8(offset++, 0x46); // 'F'
    wav.setUint32(offset, fileSize, Endian.little);
    offset += 4;
    
    // WAVE header
    wav.setUint8(offset++, 0x57); // 'W'
    wav.setUint8(offset++, 0x41); // 'A'
    wav.setUint8(offset++, 0x56); // 'V'
    wav.setUint8(offset++, 0x45); // 'E'
    
    // fmt subchunk
    wav.setUint8(offset++, 0x66); // 'f'
    wav.setUint8(offset++, 0x6D); // 'm'
    wav.setUint8(offset++, 0x74); // 't'
    wav.setUint8(offset++, 0x20); // ' '
    wav.setUint32(offset, 16, Endian.little); // Subchunk size
    offset += 4;
    wav.setUint16(offset, 1, Endian.little); // Audio format (1 = PCM)
    offset += 2;
    wav.setUint16(offset, channels, Endian.little);
    offset += 2;
    wav.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    wav.setUint32(offset, byteRate, Endian.little);
    offset += 4;
    wav.setUint16(offset, blockAlign, Endian.little);
    offset += 2;
    wav.setUint16(offset, bitDepth, Endian.little);
    offset += 2;
    
    // data subchunk
    wav.setUint8(offset++, 0x64); // 'd'
    wav.setUint8(offset++, 0x61); // 'a'
    wav.setUint8(offset++, 0x74); // 't'
    wav.setUint8(offset++, 0x61); // 'a'
    wav.setUint32(offset, dataSize, Endian.little);
    offset += 4;
    
    // Copy PCM data
    final wavBytes = wav.buffer.asUint8List();
    wavBytes.setRange(44, 44 + dataSize, pcmData);
    
    return wavBytes;
  }
}
