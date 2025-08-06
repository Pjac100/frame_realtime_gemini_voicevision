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

  /// Initialize the service with a connected Frame device
  Future<bool> initialize(BrilliantDevice frameDevice) async {
    try {
      _emit('🎤 Initializing Frame audio streaming service...');
      _frameDevice = frameDevice;
      
      // Subscribe to Frame data messages first
      _frameDataSubscription = _frameDevice!.dataResponse.listen(_handleFrameData);
      
      // Upload the main Lua application for audio streaming with retry
      bool uploadSuccess = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          _emit('📤 Upload attempt $attempt/3...');
          await _uploadAudioApp();
          
          // Verify the app is running by checking for startup message
          _emit('🔍 Verifying app startup...');
          await Future.delayed(const Duration(seconds: 3));
          
          // Test if Frame responds to a simple command
          await _frameDevice!.sendString('print("Verification test")', awaitResponse: true);
          
          uploadSuccess = true;
          break;
          
        } catch (e) {
          _emit('⚠️ Upload attempt $attempt failed: $e');
          if (attempt < 3) {
            await Future.delayed(const Duration(seconds: 2));
            // Try to reset Frame state
            try {
              await _frameDevice!.sendBreakSignal();
              await Future.delayed(const Duration(milliseconds: 500));
            } catch (_) {
              // Ignore break signal errors
            }
          }
        }
      }
      
      if (!uploadSuccess) {
        throw Exception('Failed to upload audio app after 3 attempts');
      }
      
      _isInitialized = true;
      _emit('✅ Frame audio service initialized successfully');
      return true;
      
    } catch (e) {
      _emit('❌ Frame audio initialization failed: $e');
      _isInitialized = false;
      _frameDataSubscription?.cancel();
      return false;
    }
  }

  /// Upload the Lua application that handles audio streaming on the Frame
  Future<void> _uploadAudioApp() async {
    _emit('📤 Uploading audio app to Frame...');
    
    // Simpler, more reliable Lua script
    const luaScript = '''
-- Frame Audio Streaming App
local data = require('data')

-- Message types (must match host)
local MSG_START = 1
local MSG_STOP = 2
local MSG_AUDIO = 3

local streaming = false
local sample_rate = 16000
local bit_depth = 8

-- Show startup message
frame.display.text("Audio App Ready", 10, 50)
frame.display.show()
print("Frame audio app started")

-- Main loop
while true do
    if data.process_raw_items() > 0 then
        local msg_type, payload = data.get_message()
        
        if msg_type == MSG_START then
            if not streaming then
                -- Parse parameters if available
                if payload and #payload >= 3 then
                    sample_rate = payload:byte(1) | (payload:byte(2) << 8)
                    bit_depth = payload:byte(3)
                end
                
                print("Starting audio:", sample_rate, bit_depth)
                frame.display.text("Streaming...", 10, 50)
                frame.display.show()
                
                -- Start microphone
                frame.microphone.start{
                    sample_rate = sample_rate,
                    bit_depth = bit_depth
                }
                streaming = true
                
                -- Audio streaming loop
                while streaming do
                    local audio = frame.microphone.read()
                    if audio and audio ~= "" then
                        data.send_message(MSG_AUDIO, audio)
                    else
                        frame.sleep(0.001)
                    end
                    
                    -- Check for stop messages
                    if data.process_raw_items() > 0 then
                        local stop_msg = data.get_message()
                        if stop_msg == MSG_STOP then
                            streaming = false
                        end
                    end
                end
                
                frame.microphone.stop()
                frame.display.text("Audio Ready", 10, 50)
                frame.display.show()
                print("Audio stopped")
            end
            
        elseif msg_type == MSG_STOP then
            streaming = false
        end
    end
    
    frame.sleep(0.01)
end
''';

    try {
      _emit('🔄 Stopping any existing Frame apps...');
      
      // Stop any existing app and clear
      await _frameDevice!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Test Frame responsiveness
      _emit('🧪 Testing Frame connection...');
      await _frameDevice!.sendString('print("Frame responsive")', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Try simple direct execution first (more reliable than file system)
      _emit('🚀 Loading audio app directly...');
      await _frameDevice!.sendString(luaScript, awaitResponse: false);
      await Future.delayed(const Duration(seconds: 2));
      
      _emit('✅ Audio app loaded on Frame');
      
    } catch (e) {
      _emit('❌ Failed to upload audio app: $e');
      
      // Fallback: try the file system approach
      _emit('🔄 Trying fallback file system method...');
      try {
        await _uploadViaFileSystem(luaScript);
      } catch (fallbackError) {
        _emit('❌ Fallback method also failed: $fallbackError');
        rethrow;
      }
    }
  }
  
  /// Fallback method using file system
  Future<void> _uploadViaFileSystem(String script) async {
    // Remove existing main.lua
    await _frameDevice!.sendString('frame.file.remove("main.lua")', awaitResponse: true);
    await Future.delayed(const Duration(milliseconds: 100));
    
    // Write script to file in smaller, more reliable chunks
    const chunkSize = 100; // Smaller chunks for reliability
    final scriptBytes = script.codeUnits;
    
    await _frameDevice!.sendString('f = frame.file.open("main.lua", "w")', awaitResponse: true);
    
    for (int i = 0; i < scriptBytes.length; i += chunkSize) {
      final end = (i + chunkSize < scriptBytes.length) ? i + chunkSize : scriptBytes.length;
      final chunk = String.fromCharCodes(scriptBytes.sublist(i, end));
      
      // Simple write without complex escaping
      final chunkStr = chunk.replaceAll('"', '\\"').replaceAll('\n', '\\n');
      await _frameDevice!.sendString('f:write("$chunkStr")', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 30));
    }
    
    await _frameDevice!.sendString('f:close()', awaitResponse: true);
    await Future.delayed(const Duration(milliseconds: 100));
    
    // Run the file
    await _frameDevice!.sendString('require("main")', awaitResponse: true);
    await Future.delayed(const Duration(seconds: 2));
    
    _emit('✅ Fallback upload successful');
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

  /// Start audio streaming with specified parameters
  Future<bool> startStreaming({int sampleRate = 16000, int bitDepth = 8}) async {
    if (!_isInitialized || _isStreaming || _frameDevice == null) {
      _emit('⚠️ Cannot start audio stream - not initialized or already streaming');
      return false;
    }
    
    // Validate parameters based on Frame documentation
    if (sampleRate != 8000 && sampleRate != 16000) {
      _emit('⚠️ Invalid sample rate. Must be 8000 or 16000 Hz');
      return false;
    }
    
    if (bitDepth != 8 && bitDepth != 16) {
      _emit('⚠️ Invalid bit depth. Must be 8 or 16 bits');
      return false;
    }
    
    // Calculate bandwidth requirement
    final bandwidthKBps = (sampleRate * bitDepth / 8) / 1024.0;
    final bandwidthPercent = (bandwidthKBps / 40.0) * 100; // 40 kB/s max
    
    _emit('🎤 Starting audio stream: ${sampleRate}Hz, $bitDepth-bit');
    _emit('📊 Bandwidth: ${bandwidthKBps.toStringAsFixed(1)} kB/s (${bandwidthPercent.toStringAsFixed(0)}% of max)');
    
    if (bandwidthPercent > 80) {
      _emit('⚠️ Warning: High bandwidth usage may cause audio drops');
    }
    
    // Retry logic for robust startup
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _emit('🔄 Audio start attempt $attempt/3...');
        
        // Test Frame responsiveness first
        await _frameDevice!.sendString('print("Frame ready for audio")', awaitResponse: true);
        await Future.delayed(const Duration(milliseconds: 200));
        
        // Create start message with audio parameters
        final params = ByteData(4);
        params.setUint16(0, sampleRate, Endian.little);
        params.setUint8(2, bitDepth);
        params.setUint8(3, 0); // Reserved
        
        // Send start command to Frame using raw data message
        await _frameDevice!.sendMessage(msgStartAudio, params.buffer.asUint8List());
        
        // Wait for confirmation or timeout
        final startTime = DateTime.now();
        bool confirmed = false;
        
        while (DateTime.now().difference(startTime).inSeconds < 5) {
          await Future.delayed(const Duration(milliseconds: 100));
          // Check if we're getting data (confirmation of streaming)
          if (_packetsReceived > 0) {
            confirmed = true;
            break;
          }
        }
        
        if (confirmed || attempt == 3) {
          // Reset statistics
          _packetsReceived = 0;
          _bytesReceived = 0;
          _streamStartTime = DateTime.now();
          _currentSampleRate = sampleRate;
          _currentBitDepth = bitDepth;
          
          _isStreaming = true;
          _emit('✅ Audio streaming started successfully');
          return true;
        } else {
          _emit('⚠️ No audio confirmation, retrying...');
          await Future.delayed(const Duration(milliseconds: 500));
        }
        
      } catch (e) {
        _emit('❌ Audio start attempt $attempt failed: $e');
        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
    
    _emit('❌ Failed to start audio stream after 3 attempts');
    _isStreaming = false;
    return false;
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
