// lib/services/frame_audio_streaming_service.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/rx/rx.dart';

/// Frame audio streaming service that uses simple_frame_app
/// Handles Lua script upload and audio data streaming
class FrameAudioStreamingService {
  FrameApp? _frameApp;
  
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
  
  // Message types for Frame communication
  static const int msgStartAudio = 1;
  static const int msgStopAudio = 2;
  static const int msgAudioChunk = 3;
  
  // Subscription for Frame responses
  StreamSubscription<dynamic>? _frameDataSubscription;
  
  final void Function(String) _emit;

  FrameAudioStreamingService([void Function(String msg)? logger])
      : _emit = logger ?? ((_) {});

  /// Initialize the service with a connected Frame app
  Future<bool> initialize(FrameApp frameApp) async {
    try {
      _emit('🎤 Initializing Frame audio streaming service...');
      _frameApp = frameApp;
      
      // Upload the main Lua application for audio streaming
      await _uploadAudioApp();
      
      // Subscribe to Frame data messages
      _frameDataSubscription = _frameApp!.dataResponse.listen(_handleFrameData);
      
      _isInitialized = true;
      _emit('✅ Frame audio service initialized');
      return true;
      
    } catch (e) {
      _emit('❌ Frame audio initialization failed: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Upload the Lua application that handles audio streaming on the Frame
  Future<void> _uploadAudioApp() async {
    _emit('📤 Uploading audio app to Frame...');
    
    const luaScript = '''
-- Frame Audio Streaming Application
local data = require('data')

-- Message types (must match host)
local MSG_TYPE = {
    START_AUDIO = 1,
    STOP_AUDIO = 2,
    AUDIO_CHUNK = 3
}

local streaming_active = false
local sample_rate = 16000
local bit_depth = 8

-- Function to handle audio streaming
local function stream_audio()
    local mtu = frame.bluetooth.max_length()
    local chunk_size = mtu - 8  -- Leave room for message header
    
    while streaming_active do
        -- Read audio data from microphone buffer
        local audio_data = frame.microphone.read(chunk_size)
        
        if audio_data == nil then
            -- Stream stopped and buffer empty
            streaming_active = false
            break
        end
        
        if audio_data ~= '' then
            -- Send audio chunk to host
            data.send_message(MSG_TYPE.AUDIO_CHUNK, audio_data)
        else
            -- Buffer temporarily empty, yield CPU
            frame.sleep(0.001)
        end
    end
    
    -- Ensure microphone is stopped
    frame.microphone.stop()
end

-- Main event loop
local function app_loop()
    print("Frame audio app ready")
    
    while true do
        -- Process messages from host
        if data.process_raw_items() > 0 then
            local msg_type, msg_payload = data.get_message()
            
            if msg_type == MSG_TYPE.START_AUDIO then
                if not streaming_active then
                    -- Parse audio parameters from payload
                    if msg_payload and #msg_payload >= 4 then
                        sample_rate = (msg_payload:byte(1) | (msg_payload:byte(2) << 8))
                        bit_depth = msg_payload:byte(3)
                    end
                    
                    -- Start microphone
                    frame.microphone.start{
                        sample_rate = sample_rate,
                        bit_depth = bit_depth
                    }
                    
                    streaming_active = true
                    stream_audio()
                end
                
            elseif msg_type == MSG_TYPE.STOP_AUDIO then
                streaming_active = false
            end
        end
        
        -- Small sleep to yield CPU
        frame.sleep(0.001)
    end
end

-- Start the application
app_loop()
''';

    // Upload and run the Lua script using TxCode
    await _frameApp!.sendMessage(
      TxCode(
        msgCode: 0x0b, // Code upload/execute
        luaScript: luaScript,
      ),
    );
    
    _emit('✅ Audio app uploaded and running');
  }

  /// Handle data messages from Frame
  void _handleFrameData(dynamic data) {
    if (data == null) return;
    
    // Check if it's an RxData message with audio
    if (data is Map && data['type'] == 'data') {
      final messageType = data['message_type'] ?? data['msgType'];
      final payload = data['data'] ?? data['payload'];
      
      if (messageType == msgAudioChunk && payload != null) {
        // Audio data received
        Uint8List audioData;
        
        if (payload is List<int>) {
          audioData = Uint8List.fromList(payload);
        } else if (payload is Uint8List) {
          audioData = payload;
        } else {
          return;
        }
        
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
    if (!_isInitialized || _isStreaming || _frameApp == null) {
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
    
    try {
      // Create start message with audio parameters
      final params = ByteData(4);
      params.setUint16(0, sampleRate, Endian.little);
      params.setUint8(2, bitDepth);
      params.setUint8(3, 0); // Reserved
      
      // Send start command to Frame using raw data message
      await _frameApp!.sendMessage(
        TxRawData(
          msgCode: msgStartAudio,
          data: params.buffer.asUint8List(),
        ),
      );
      
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
    if (!_isStreaming || _frameApp == null) {
      _emit('⚠️ Audio stream not active');
      return false;
    }
    
    try {
      _emit('⏹️ Stopping audio stream...');
      
      // Send stop command to Frame
      await _frameApp!.sendMessage(
        TxRawData(
          msgCode: msgStopAudio,
          data: Uint8List(0),
        ),
      );
      
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

  /// Send display text to Frame (for testing)
  Future<void> sendDisplayText(String text) async {
    if (_frameApp != null) {
      await _frameApp!.sendMessage(
        TxPlainText(
          msgCode: 0x0a,
          text: text,
          x: 50,
          y: 100,
        ),
      );
      _emit('📺 Sent to display: "$text"');
    }
  }

  /// Clear Frame display
  Future<void> clearDisplay() async {
    if (_frameApp != null) {
      await _frameApp!.sendMessage(
        TxClearDisplay(msgCode: 0x10),
      );
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
