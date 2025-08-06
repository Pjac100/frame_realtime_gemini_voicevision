// lib/services/frame_audio_streaming_service.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:frame_ble/brilliant_device.dart';

/// Frame audio streaming service that uses Frame SDK
/// Handles Lua script upload and audio data streaming
class FrameAudioStreamingService {
  BrilliantDevice? _frameDevice;
  
  // Audio streaming state
  bool _isStreaming = false;
  bool _isInitialized = false;
  int _currentSampleRate = 16000;
  int _currentBitDepth = 8;
  
  // Audio data stream
  final StreamController<Uint8List> _audioDataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioStream => _audioDataController.stream;
  
  // Log stream for UI
  final StreamController<String> _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;
  
  // Statistics
  int _packetsReceived = 0;
  int _bytesReceived = 0;
  DateTime? _streamStartTime;
  
  // Message types for Frame communication (must match Lua script)
  static const int msgStartAudio = 1;
  static const int msgStopAudio = 2;
  static const int msgAudioChunk = 3;
  
  // Subscription for Frame responses
  StreamSubscription<dynamic>? _frameDataSubscription;
  
  final void Function(String) _emit;

  FrameAudioStreamingService([void Function(String msg)? logger])
      : _emit = logger ?? ((_) {});

  /// Initialize service without deploying scripts (to avoid disconnection)
  Future<bool> initialize(BrilliantDevice frameDevice) async {
    try {
      _emit('🎤 Setting up Frame audio service...');
      _frameDevice = frameDevice;
      
      // Subscribe to Frame data messages
      _frameDataSubscription = _frameDevice!.dataResponse.listen(_handleFrameData);
      
      // Don't deploy scripts here - wait until session start
      _isInitialized = true;
      _emit('✅ Frame audio service ready (script deployment deferred)');
      return true;
      
    } catch (e) {
      _emit('❌ Frame audio service setup failed: $e');
      _isInitialized = false;
      _frameDataSubscription?.cancel();
      return false;
    }
  }
  
  /// Deploy audio scripts only when starting a session
  Future<bool> deployAudioScripts() async {
    if (_frameDevice == null) {
      _emit('❌ No Frame device available for script deployment');
      return false;
    }
    
    try {
      _emit('📤 Deploying audio scripts for session...');
      await _uploadAudioApp();
      _emit('✅ Audio scripts deployed');
      return true;
      
    } catch (e) {
      _emit('❌ Script deployment failed: $e');
      return false;
    }
  }

  /// Simplified audio app deployment following official pattern
  Future<void> _uploadAudioApp() async {
    _emit('📤 Deploying minimal audio handler...');
    
    // Minimal Lua script similar to official repository approach
    const minimalScript = '''
-- Minimal Frame Audio Handler
local data = require('data')

frame.display.text("Audio Ready", 20, 60)
frame.display.show()
print("Minimal audio handler ready")

-- Simple message loop
while true do
    if data.process_raw_items() > 0 then
        local msg_type, payload = data.get_message()
        
        if msg_type == 1 then -- Start audio
            print("Start audio command received")
            frame.display.text("Audio ON", 20, 60)
            frame.display.show()
            
            -- Simple audio streaming
            frame.microphone.start{sample_rate=8000, bit_depth=8}
            
            for i = 1, 100 do -- Limit loop iterations
                local audio = frame.microphone.read()
                if audio and #audio > 0 then
                    data.send_message(3, audio)
                end
                frame.sleep(0.01)
            end
            
            frame.microphone.stop()
            frame.display.text("Audio Ready", 20, 60)
            frame.display.show()
            
        elseif msg_type == 2 then -- Stop audio
            print("Stop audio command received")
            break
        end
    end
    frame.sleep(0.05)
end
''';

    try {
      // Clear any existing scripts
      await _frameDevice!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Send minimal script directly - no file system complexity
      _emit('🚀 Loading minimal audio handler...');
      await _frameDevice!.sendString(minimalScript, awaitResponse: false);
      await Future.delayed(const Duration(milliseconds: 1000));
      
      _emit('✅ Minimal audio handler deployed');
      
    } catch (e) {
      _emit('❌ Failed to deploy audio handler: $e');
      throw Exception('Audio handler deployment failed: $e');
    }
  }

  /// Handle data messages from Frame
  void _handleFrameData(List<int> data) {
    if (data.isEmpty) return;
    
    // Check if it's an audio message
    if (data.length > 1 && data[0] == msgAudioChunk) {
      final payload = data.sublist(1);
      if (payload.isNotEmpty) {
        // Audio data received
        final audioData = Uint8List.fromList(payload);
        
        _packetsReceived++;
        _bytesReceived += audioData.length;
        
        // Emit to stream
        _audioDataController.add(audioData);
        
        // Log statistics periodically
        if (_packetsReceived % 100 == 0) {
          final duration = DateTime.now().difference(_streamStartTime!).inSeconds;
          final kbps = duration > 0 ? (_bytesReceived / 1024) / duration : 0;
          _emit('📊 Audio: $_packetsReceived packets, ${(_bytesReceived/1024).toStringAsFixed(1)}KB, ${kbps.toStringAsFixed(1)} KB/s');
        }
      }
    }
  }

  /// Simplified audio streaming startup
  Future<bool> startStreaming({int sampleRate = 8000, int bitDepth = 8}) async {
    if (!_isInitialized || _isStreaming || _frameDevice == null) {
      _emit('⚠️ Cannot start audio - service not ready');
      return false;
    }
    
    try {
      _emit('🎤 Starting audio stream: ${sampleRate}Hz, $bitDepth-bit');
      
      // Simple start command
      await _frameDevice!.sendMessage(msgStartAudio, Uint8List.fromList([sampleRate & 0xFF, (sampleRate >> 8) & 0xFF, bitDepth]));
      
      // Reset statistics
      _packetsReceived = 0;
      _bytesReceived = 0;
      _streamStartTime = DateTime.now();
      _currentSampleRate = sampleRate;
      _currentBitDepth = bitDepth;
      _isStreaming = true;
      
      _emit('✅ Audio streaming started');
      return true;
      
    } catch (e) {
      _emit('❌ Failed to start audio stream: $e');
      _isStreaming = false;
      return false;
    }
  }

  /// Stop audio streaming
  Future<bool> stopStreaming() async {
    if (!_isStreaming || _frameDevice == null) {
      _emit('⚠️ Audio stream not active');
      return false;
    }
    
    try {
      _emit('⏹️ Stopping audio stream...');
      
      // Send stop command to Frame
      await _frameDevice!.sendMessage(msgStopAudio, Uint8List(0));
      
      _isStreaming = false;
      
      // Log final statistics
      if (_streamStartTime != null) {
        final duration = DateTime.now().difference(_streamStartTime!);
        final totalKB = _bytesReceived / 1024;
        final avgKbps = duration.inSeconds > 0 ? totalKB / duration.inSeconds : 0;
        _emit('📊 Final stats: $_packetsReceived packets, ${totalKB.toStringAsFixed(1)}KB total');
        _emit('📊 Duration: ${duration.inSeconds}s, Avg: ${avgKbps.toStringAsFixed(1)} KB/s');
      }
      
      _emit('✅ Audio streaming stopped');
      return true;
      
    } catch (e) {
      _emit('❌ Failed to stop audio stream: $e');
      return false;
    }
  }

  /// Get current streaming status
  bool get isStreaming => _isStreaming;
  bool get isInitialized => _isInitialized;
  
  /// Get audio configuration
  Map<String, dynamic> get audioConfig => {
    'sampleRate': _currentSampleRate,
    'bitDepth': _currentBitDepth,
    'isStreaming': _isStreaming,
    'isInitialized': _isInitialized,
    'packetsReceived': _packetsReceived,
    'bytesReceived': _bytesReceived,
  };
  
  /// Test Frame connection and responsiveness
  Future<bool> testConnection() async {
    if (_frameDevice == null) {
      _emit('❌ No Frame device available for testing');
      return false;
    }
    
    try {
      _emit('🧪 Testing Frame connection...');
      
      // Simple Lua command test
      await _frameDevice!.sendString('print("Connection test OK")', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Display test
      await _frameDevice!.sendString('frame.display.text("Test", 10, 10); frame.display.show()', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
      
      _emit('✅ Frame connection test passed');
      return true;
      
    } catch (e) {
      _emit('❌ Frame connection test failed: $e');
      return false;
    }
  }
  
  /// Minimal audio test without full streaming setup
  Future<bool> testAudioCapability() async {
    if (_frameDevice == null) {
      _emit('❌ No Frame device for audio test');
      return false;
    }
    
    try {
      _emit('🎤 Testing Frame audio capability...');
      
      // Simple audio test script
      const testScript = '''
frame.display.text("Audio Test", 10, 30)
frame.display.show()
print("Starting audio test")

frame.microphone.start{sample_rate=8000, bit_depth=8}
frame.sleep(1)
local test_data = frame.microphone.read()
frame.microphone.stop()

if test_data then
    print("Audio test: Got data", #test_data)
    frame.display.text("Audio OK", 10, 50)
else
    print("Audio test: No data")
    frame.display.text("Audio FAIL", 10, 50)
end
frame.display.show()
''';
      
      await _frameDevice!.sendString(testScript, awaitResponse: false);
      await Future.delayed(const Duration(seconds: 3));
      
      _emit('✅ Audio capability test completed');
      return true;
      
    } catch (e) {
      _emit('❌ Audio capability test failed: $e');
      return false;
    }
  }

  /// Send display text to Frame (for testing)
  Future<void> sendDisplayText(String text) async {
    if (_frameDevice != null) {
      await _frameDevice!.sendMessage(0x0a, TxPlainText(
        text: text,
        x: 50,
        y: 100,
      ).pack());
      _emit('📺 Sent to display: "$text"');
    }
  }

  /// Clear Frame display
  Future<void> clearDisplay() async {
    if (_frameDevice != null) {
      await _frameDevice!.clearDisplay();
      _emit('📺 Display cleared');
    }
  }

  /// Cleanup resources
  void dispose() {
    stopStreaming();
    _frameDataSubscription?.cancel();
    _audioDataController.close();
    _logController.close();
    _emit('🧹 Frame audio service disposed');
  }
}

/// Helper class for raw data messages
class TxRawData {
  final int msgCode;
  final Uint8List data;
  
  TxRawData({required this.msgCode, required this.data});
}

/// Helper class for clear display message
class TxClearDisplay {
  final int msgCode;
  
  TxClearDisplay({required this.msgCode});
}

/// Helper class for processing Frame audio data
class FrameAudioProcessor {
  /// Convert Frame PCM audio to format suitable for speech recognition
  /// Frame audio is signed PCM, little-endian for 16-bit
  static Uint8List processAudioData(Uint8List rawData, int bitDepth) {
    if (bitDepth == 8) {
      // 8-bit audio is signed, convert to unsigned if needed
      final processed = Uint8List(rawData.length);
      for (int i = 0; i < rawData.length; i++) {
        processed[i] = rawData[i] + 128; // Convert from signed to unsigned
      }
      return processed;
    } else {
      // 16-bit audio is already in the correct format (signed, little-endian)
      return rawData;
    }
  }
  
  /// Calculate audio level for visualization or VAD
  static double calculateAudioLevel(Uint8List audioData, int bitDepth) {
    double sum = 0.0;
    int sampleCount = 0;
    
    if (bitDepth == 8) {
      for (int i = 0; i < audioData.length; i++) {
        final sample = (audioData[i] - 128) / 128.0; // Convert to normalized float
        sum += sample * sample;
        sampleCount++;
      }
    } else if (bitDepth == 16) {
      for (int i = 0; i < audioData.length - 1; i += 2) {
        final sample = (audioData[i] | (audioData[i + 1] << 8));
        final normalizedSample = (sample > 32767 ? sample - 65536 : sample) / 32768.0;
        sum += normalizedSample * normalizedSample;
        sampleCount++;
      }
    }
    
    return sampleCount > 0 ? sum / sampleCount : 0.0;
  }
  
  /// Simple voice activity detection based on energy
  static bool detectVoiceActivity(Uint8List audioData, int bitDepth, {double threshold = 0.01}) {
    final level = calculateAudioLevel(audioData, bitDepth);
    return level > threshold;
  }
}
