import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'frame_audio_streaming_service.dart';
import '../gemini_realtime.dart' as gemini_realtime;
import 'vector_db_service.dart';

/// Complete integration service that bridges Frame hardware with Gemini Realtime API
/// Provides end-to-end voice conversation with smart glasses
class FrameGeminiRealtimeIntegration {
  final FrameAudioStreamingService _frameAudioService;
  final gemini_realtime.GeminiRealtime _geminiRealtime;
  final VectorDbService? _vectorDb;
  // Frame device for future extensions
  // ignore: unused_field
  final BrilliantDevice? _frameDevice;
  final void Function(String) _logger;
  
  // Integration state
  bool _isActive = false;
  bool _isListening = false;
  final bool _isProcessing = false;
  
  // Audio processing
  final List<Uint8List> _audioBuffer = [];
  int _bufferSizeBytes = 0;
  static const int _maxBufferSize = 64000; // 4 seconds at 16kHz
  
  // Voice activity detection
  bool _isVoiceActive = false;
  Timer? _silenceTimer;
  static const Duration _silenceThreshold = Duration(milliseconds: 1000);
  
  // Audio conversion constants
  static const int _targetBitDepth = 16; // Gemini expects 16-bit PCM
  
  // Subscriptions
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<String>? _frameLogSubscription;
  
  // Audio playback
  bool _isPlayingAudio = false;
  bool _isAudioSetup = false;
  
  // Statistics
  int _totalAudioPackets = 0;
  int _totalResponsesReceived = 0;
  DateTime? _sessionStartTime;

  FrameGeminiRealtimeIntegration({
    required FrameAudioStreamingService frameAudioService,
    required gemini_realtime.GeminiRealtime geminiRealtime,
    required BrilliantDevice? frameDevice,
    VectorDbService? vectorDb,
    required void Function(String) logger,
  }) : _frameAudioService = frameAudioService,
       _geminiRealtime = geminiRealtime,
       _frameDevice = frameDevice,
       _vectorDb = vectorDb,
       _logger = logger;

  /// Initialize the integration service
  Future<bool> initialize() async {
    try {
      _logger('🔧 Initializing Frame-Gemini realtime integration...');
      
      // Initialize PCM audio player
      try {
        await FlutterPcmSound.setup(
          sampleRate: 24000, // Gemini responses are 24kHz
          channelCount: 1,   // Mono audio
        );
        FlutterPcmSound.setFeedThreshold(1000); // Buffer threshold
        await FlutterPcmSound.setLogLevel(LogLevel.standard);
        _isAudioSetup = true;
        _logger('✅ Audio player initialized');
      } catch (e) {
        _logger('⚠️ Audio player init warning: $e');
      }
      
      // Subscribe to Frame audio service logs
      _frameLogSubscription = _frameAudioService.logStream.listen(_logger);
      
      _logger('✅ Frame-Gemini integration initialized');
      return true;
    } catch (e) {
      _logger('❌ Integration initialization failed: $e');
      return false;
    }
  }

  /// Start a complete voice conversation session
  Future<bool> startSession({
    required String geminiApiKey,
    required gemini_realtime.GeminiVoiceName voice,
    String systemInstruction = 'You are a helpful AI assistant integrated with Frame smart glasses. Keep responses concise and conversational.',
  }) async {
    if (_isActive) {
      _logger('⚠️ Session already active');
      return false;
    }

    try {
      _logger('🚀 Starting Frame-Gemini realtime session...');
      _sessionStartTime = DateTime.now();
      
      // Connect to Gemini Realtime API
      final geminiConnected = await _geminiRealtime.connect(
        geminiApiKey,
        voice,
        systemInstruction,
      );
      
      if (!geminiConnected) {
        _logger('❌ Failed to connect to Gemini Realtime');
        return false;
      }
      
      // Start Frame audio streaming
      final audioStarted = await _frameAudioService.startStreaming(
        sampleRate: 16000, // Match Gemini's expected rate
        bitDepth: 16,      // Match Gemini's expected depth
      );
      
      if (!audioStarted) {
        _logger('❌ Failed to start Frame audio streaming');
        await _geminiRealtime.disconnect();
        return false;
      }
      
      // Set up audio stream processing
      _setupAudioStreaming();
      
      // Set up Gemini response handling
      _setupResponseHandling();
      
      // Display session start on Frame
      await _displayOnFrame('🎤 Voice session active');
      
      _isActive = true;
      _isListening = true;
      _logger('✅ Realtime session started successfully');
      return true;
      
    } catch (e) {
      _logger('❌ Failed to start session: $e');
      await stopSession();
      return false;
    }
  }

  /// Set up Frame audio stream processing
  void _setupAudioStreaming() {
    _audioSubscription = _frameAudioService.audioStream.listen(
      _processFrameAudio,
      onError: (error) => _logger('❌ Audio stream error: $error'),
    );
  }

  /// Set up Gemini response handling
  void _setupResponseHandling() {
    // Start checking for audio responses
    _startResponsePlayback();
  }

  /// Process audio data from Frame
  void _processFrameAudio(Uint8List audioData) {
    if (!_isActive || !_isListening) return;
    
    _totalAudioPackets++;
    
    // Convert audio format if needed
    final convertedAudio = _convertAudioFormat(audioData);
    
    // Add to buffer for voice activity detection
    _audioBuffer.add(convertedAudio);
    _bufferSizeBytes += convertedAudio.length;
    
    // Detect voice activity
    final hasVoice = FrameAudioProcessor.detectVoiceActivity(
      convertedAudio, 
      _targetBitDepth,
      threshold: 0.015, // Slightly higher threshold for better detection
    );
    
    if (hasVoice) {
      _handleVoiceDetected(convertedAudio);
    } else {
      _handleSilence();
    }
    
    // Prevent buffer overflow
    if (_bufferSizeBytes > _maxBufferSize) {
      _trimBuffer();
    }
  }

  /// Convert Frame audio to Gemini Realtime format
  Uint8List _convertAudioFormat(Uint8List frameAudio) {
    // Frame audio should already be 16kHz/16-bit based on our streaming config
    // But we'll ensure it's in the correct format for Gemini
    return frameAudio;
  }

  /// Handle voice activity detected
  void _handleVoiceDetected(Uint8List audioData) {
    if (!_isVoiceActive) {
      _isVoiceActive = true;
      _logger('🗣️ Voice detected - streaming to Gemini');
      
      // Stop any current audio playback
      if (_isPlayingAudio) {
        _stopAudioPlayback();
      }
    }
    
    // Cancel silence timer
    _silenceTimer?.cancel();
    _silenceTimer = null;
    
    // Send audio directly to Gemini Realtime
    _sendAudioToGemini(audioData);
  }

  /// Handle silence detected
  void _handleSilence() {
    if (_isVoiceActive && _silenceTimer == null) {
      // Start silence timer
      _silenceTimer = Timer(_silenceThreshold, () {
        _isVoiceActive = false;
        _logger('🤫 Voice ended - processing complete');
        
        // Add conversation to vector DB if available
        _addConversationToVectorDb();
      });
    }
  }

  /// Send audio data to Gemini Realtime API
  void _sendAudioToGemini(Uint8List audioData) {
    if (_geminiRealtime.isConnected()) {
      _geminiRealtime.sendAudio(audioData);
    }
  }

  /// Add conversation context to vector database
  Future<void> _addConversationToVectorDb() async {
    if (_vectorDb == null) return;
    
    try {
      // Create a conversation summary for the vector DB
      final timestamp = DateTime.now().toIso8601String();
      const conversationSummary = 'User spoke to Frame assistant'; // This could be enhanced with actual transcription
      
      await _vectorDb.addTextWithEmbedding(
        content: conversationSummary,
        metadata: {
          'type': 'conversation',
          'timestamp': timestamp,
          'source': 'frame_realtime_session',
        },
      );
    } catch (e) {
      _logger('⚠️ Failed to add conversation to vector DB: $e');
    }
  }

  /// Start monitoring for Gemini audio responses
  void _startResponsePlayback() {
    Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!_isActive) {
        timer.cancel();
        return;
      }
      
      try {
        _checkForAudioResponse();
      } catch (e) {
        _logger('⚠️ Response check error: $e');
      }
    });
  }

  /// Check for and play audio responses from Gemini
  void _checkForAudioResponse() {
    if (_geminiRealtime.hasResponseAudio() && !_isPlayingAudio && !_isVoiceActive) {
      _playGeminiResponse();
    }
  }

  /// Play audio response from Gemini
  Future<void> _playGeminiResponse() async {
    if (_isPlayingAudio || !_isAudioSetup) return;
    
    try {
      _isPlayingAudio = true;
      _totalResponsesReceived++;
      _logger('🔊 Playing Gemini response');
      
      // Display response indicator on Frame
      await _displayOnFrame('🤖 AI responding...');
      
      // Get audio data from Gemini
      final responseAudio = _geminiRealtime.getResponseAudioByteData();
      
      if (responseAudio.lengthInBytes > 0) {
        // Convert ByteData to Int16 list for flutter_pcm_sound
        final audioSamples = <int>[];
        for (int i = 0; i < responseAudio.lengthInBytes - 1; i += 2) {
          final sample = responseAudio.getInt16(i, Endian.little);
          audioSamples.add(sample);
        }
        
        // Play audio through phone speaker using flutter_pcm_sound
        if (audioSamples.isNotEmpty) {
          FlutterPcmSound.start();
          await FlutterPcmSound.feed(PcmArrayInt16.fromList(audioSamples));
          
          // Wait for playback to complete
          await Future.delayed(Duration(
            milliseconds: (audioSamples.length / 24000 * 1000).round(),
          ));
        }
      }
      
      // Clear response indicator
      await _displayOnFrame('🎤 Listening...');
      
    } catch (e) {
      _logger('❌ Audio playback error: $e');
    } finally {
      _isPlayingAudio = false;
    }
  }

  /// Stop audio playback
  void _stopAudioPlayback() {
    try {
      // flutter_pcm_sound doesn't have a stop method - just stop feeding audio
      _geminiRealtime.stopResponseAudio();
      _isPlayingAudio = false;
    } catch (e) {
      _logger('⚠️ Stop playback error: $e');
    }
  }

  /// Display text on Frame glasses
  Future<void> _displayOnFrame(String text) async {
    try {
      await _frameAudioService.sendDisplayText(text);
    } catch (e) {
      _logger('⚠️ Frame display error: $e');
    }
  }

  /// Send photo from Frame to Gemini
  Future<void> sendPhotoToGemini(Uint8List jpegPhoto) async {
    if (!_isActive || !_geminiRealtime.isConnected()) {
      _logger('⚠️ Cannot send photo - session not active');
      return;
    }
    
    try {
      _logger('📸 Sending photo to Gemini...');
      _geminiRealtime.sendPhoto(jpegPhoto);
      
      // Add photo context to vector DB
      if (_vectorDb != null) {
        await _vectorDb.addTextWithEmbedding(
          content: 'User shared a photo through Frame glasses',
          metadata: {
            'type': 'photo',
            'timestamp': DateTime.now().toIso8601String(),
            'source': 'frame_camera',
          },
        );
      }
    } catch (e) {
      _logger('❌ Failed to send photo: $e');
    }
  }

  /// Trim audio buffer to prevent memory overflow
  void _trimBuffer() {
    while (_bufferSizeBytes > _maxBufferSize && _audioBuffer.isNotEmpty) {
      final removed = _audioBuffer.removeAt(0);
      _bufferSizeBytes -= removed.length;
    }
    _logger('⚠️ Audio buffer trimmed to prevent overflow');
  }

  /// Stop the voice conversation session
  Future<void> stopSession() async {
    if (!_isActive) return;
    
    try {
      _logger('⏹️ Stopping realtime session...');
      
      _isActive = false;
      _isListening = false;
      
      // Stop timers
      _silenceTimer?.cancel();
      
      // Stop audio streaming with error handling
      try {
        await _frameAudioService.stopStreaming();
      } catch (e) {
        _logger('⚠️ Audio stop error: $e');
      }
      
      // Stop audio playback
      _stopAudioPlayback();
      
      // Disconnect from Gemini with error handling
      try {
        await _geminiRealtime.disconnect();
      } catch (e) {
        _logger('⚠️ Gemini disconnect error: $e');
      }
      
      // Cancel subscriptions
      await _audioSubscription?.cancel();
      
      // Clear buffers
      _audioBuffer.clear();
      _bufferSizeBytes = 0;
      
      // Display session end on Frame
      try {
        await _displayOnFrame('Session ended');
        await Future.delayed(const Duration(seconds: 2));
        await _frameAudioService.clearDisplay();
      } catch (e) {
        _logger('⚠️ Frame display error: $e');
      }
      
      // Log session statistics
      if (_sessionStartTime != null) {
        final duration = DateTime.now().difference(_sessionStartTime!);
        _logger('📊 Session stats: ${duration.inSeconds}s, $_totalAudioPackets audio packets, $_totalResponsesReceived responses');
      }
      
      _logger('✅ Realtime session stopped');
      
    } catch (e) {
      _logger('❌ Error stopping session: $e');
      // Force cleanup even if there are errors
      _forceCleanup();
    }
  }

  /// Force cleanup in case of errors
  void _forceCleanup() {
    try {
      _isActive = false;
      _isListening = false;
      _silenceTimer?.cancel();
      _audioSubscription?.cancel();
      _audioBuffer.clear();
      _bufferSizeBytes = 0;
      _logger('🧹 Force cleanup completed');
    } catch (e) {
      _logger('❌ Force cleanup error: $e');
    }
  }

  /// Get current session status
  Map<String, dynamic> get status => {
    'isActive': _isActive,
    'isListening': _isListening,
    'isProcessing': _isProcessing,
    'isVoiceActive': _isVoiceActive,
    'isPlayingAudio': _isPlayingAudio,
    'totalAudioPackets': _totalAudioPackets,
    'totalResponses': _totalResponsesReceived,
    'bufferSize': _bufferSizeBytes,
    'geminiConnected': _geminiRealtime.isConnected(),
    'frameAudioActive': _frameAudioService.isStreaming,
  };

  /// Dispose resources
  void dispose() {
    stopSession();
    _frameLogSubscription?.cancel();
    _logger('🧹 Frame-Gemini integration disposed');
  }
}