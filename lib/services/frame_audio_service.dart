// lib/services/frame_audio_service.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

class FrameAudioService {
  static const String frameAudioServiceUuid = '7a230001-5475-a6a4-654c-8431f6ad49c4';
  static const String audioDataCharacteristicUuid = '7a230002-5475-a6a4-654c-8431f6ad49c4';
  static const String audioControlCharacteristicUuid = '7a230003-5475-a6a4-654c-8431f6ad49c4';
  static const String audioConfigCharacteristicUuid = '7a230004-5475-a6a4-654c-8431f6ad49c4';
  
  // Audio configuration constants
  static const int sampleRate = 16000; // 16kHz for speech
  static const int channels = 1; // Mono
  static const int bitDepth = 16; // 16-bit PCM
  static const int bufferSize = 1024; // 1KB buffers for real-time processing
  
  fbp.BluetoothService? _audioService;
  fbp.BluetoothCharacteristic? _audioDataCharacteristic;
  fbp.BluetoothCharacteristic? _audioControlCharacteristic;
  fbp.BluetoothCharacteristic? _audioConfigCharacteristic;
  
  // Audio streaming state
  bool _isStreaming = false;
  bool _isInitialized = false;
  
  // Audio data stream
  final StreamController<Uint8List> _audioDataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;
  
  // Audio statistics
  int _packetsReceived = 0;
  int _bytesReceived = 0;
  DateTime? _streamStartTime;
  
  final void Function(String) _emit;

  FrameAudioService([void Function(String msg)? logger])
      : _emit = logger ?? ((_) {});

  /// Initialize audio service with connected Frame device
  Future<bool> initialize(fbp.BluetoothDevice device) async {
    try {
      _emit('🎤 Initializing Frame audio service...');
      
      // Discover services
      final services = await device.discoverServices();
      _emit('🔍 Discovered $services.length services');
      
      // Find Frame audio service
      _audioService = services.firstWhere(
        (service) => service.serviceUuid.toString().toLowerCase() == frameAudioServiceUuid.toLowerCase(),
        orElse: () => throw Exception('Frame audio service not found'),
      );
      
      _emit('✅ Found Frame audio service: ${_audioService!.serviceUuid}');
      
      // Discover audio characteristics
      await _discoverAudioCharacteristics();
      
      // Configure audio settings
      await _configureAudioSettings();
      
      _isInitialized = true;
      _emit('✅ Frame audio service initialized successfully');
      return true;
      
    } catch (e) {
      _emit('❌ Frame audio initialization failed: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Discover and setup audio characteristics
  Future<void> _discoverAudioCharacteristics() async {
    final characteristics = _audioService!.characteristics;
          _emit('🔍 Found $characteristics.length audio characteristics');
    
    for (final char in characteristics) {
      final uuid = char.characteristicUuid.toString().toLowerCase();
      _emit('📡 Characteristic: $uuid');
      
      switch (uuid) {
        case audioDataCharacteristicUuid:
          _audioDataCharacteristic = char;
          _emit('✅ Audio data characteristic found');
          break;
        case audioControlCharacteristicUuid:
          _audioControlCharacteristic = char;
          _emit('✅ Audio control characteristic found');
          break;
        case audioConfigCharacteristicUuid:
          _audioConfigCharacteristic = char;
          _emit('✅ Audio config characteristic found');
          break;
      }
    }
    
    if (_audioDataCharacteristic == null) {
      throw Exception('Audio data characteristic not found');
    }
    
    // Setup notifications for audio data
    await _audioDataCharacteristic!.setNotifyValue(true);
    _audioDataCharacteristic!.lastValueStream.listen(_handleAudioData);
    _emit('🔔 Audio data notifications enabled');
  }

  /// Configure Frame audio settings
  Future<void> _configureAudioSettings() async {
    if (_audioConfigCharacteristic == null) {
      _emit('⚠️ Audio config characteristic not available, using defaults');
      return;
    }
    
    try {
      final config = ByteData(6);
      config.setUint16(0, sampleRate, Endian.little);
      config.setUint8(2, channels);
      config.setUint8(3, bitDepth);
      config.setUint16(4, bufferSize, Endian.little);
      
      await _audioConfigCharacteristic!.write(config.buffer.asUint8List());
      _emit('🔧 Audio configuration sent: $sampleRate Hz, $channels ch, $bitDepth bit');
      
      // Wait for configuration acknowledgment
      await Future.delayed(const Duration(milliseconds: 100));
      
    } catch (e) {
      _emit('⚠️ Audio configuration failed: $e');
    }
  }

  /// Handle incoming audio data from Frame
  void _handleAudioData(List<int> data) {
    if (!_isStreaming) return;
    
    final audioData = Uint8List.fromList(data);
    _packetsReceived++;
    _bytesReceived += audioData.length;
    
    // Emit audio data to stream
    _audioDataController.add(audioData);
    
    // Log statistics periodically
    if (_packetsReceived % 100 == 0) {
      final duration = DateTime.now().difference(_streamStartTime!).inSeconds;
      final kbps = duration > 0 ? (_bytesReceived / 1024) / duration : 0;
              _emit('📊 Audio: $_packetsReceived packets, ${(_bytesReceived/1024).toStringAsFixed(1)}KB, ${kbps.toStringAsFixed(1)} KB/s');
    }
  }

  /// Start audio streaming from Frame
  Future<bool> startAudioStream() async {
    if (!_isInitialized || _isStreaming) {
      _emit('⚠️ Cannot start audio stream - not initialized or already streaming');
      return false;
    }
    
    try {
      _emit('🎤 Starting Frame audio stream...');
      
      if (_audioControlCharacteristic != null) {
        // Send start command to Frame
        final startCommand = Uint8List.fromList([0x01]); // START command
        await _audioControlCharacteristic!.write(startCommand);
        _emit('📤 Start command sent to Frame');
      }
      
      // Reset statistics
      _packetsReceived = 0;
      _bytesReceived = 0;
      _streamStartTime = DateTime.now();
      
      _isStreaming = true;
      _emit('✅ Frame audio streaming started');
      return true;
      
    } catch (e) {
      _emit('❌ Failed to start audio stream: $e');
      _isStreaming = false;
      return false;
    }
  }

  /// Stop audio streaming from Frame
  Future<bool> stopAudioStream() async {
    if (!_isStreaming) {
      _emit('⚠️ Audio stream not active');
      return false;
    }
    
    try {
      _emit('⏹️ Stopping Frame audio stream...');
      
      if (_audioControlCharacteristic != null) {
        // Send stop command to Frame
        final stopCommand = Uint8List.fromList([0x00]); // STOP command
        await _audioControlCharacteristic!.write(stopCommand);
        _emit('📤 Stop command sent to Frame');
      }
      
      _isStreaming = false;
      
      // Log final statistics
      if (_streamStartTime != null) {
        final duration = DateTime.now().difference(_streamStartTime!);
        final totalKB = _bytesReceived / 1024;
        final avgKbps = duration.inSeconds > 0 ? totalKB / duration.inSeconds : 0;
        _emit('📊 Final stats: $_packetsReceived packets, ${totalKB.toStringAsFixed(1)}KB, ${avgKbps.toStringAsFixed(1)} KB/s avg');
      }
      
      _emit('✅ Frame audio streaming stopped');
      return true;
      
    } catch (e) {
      _emit('❌ Failed to stop audio stream: $e');
      return false;
    }
  }

  /// Get current audio streaming status
  bool get isStreaming => _isStreaming;
  bool get isInitialized => _isInitialized;
  
  /// Get audio configuration info
  Map<String, dynamic> get audioConfig => {
    'sampleRate': sampleRate,
    'channels': channels,
    'bitDepth': bitDepth,
    'bufferSize': bufferSize,
    'isStreaming': _isStreaming,
    'isInitialized': _isInitialized,
    'packetsReceived': _packetsReceived,
    'bytesReceived': _bytesReceived,
  };

  /// Create mock audio data for Codespace testing
  void startMockAudioStream() {
    if (_isStreaming) return;
    
    _emit('🧪 Starting mock audio stream for testing...');
    _isStreaming = true;
    _streamStartTime = DateTime.now();
    _packetsReceived = 0;
    _bytesReceived = 0;
    
    // Generate mock audio data at 16kHz, 16-bit mono
    Timer.periodic(const Duration(milliseconds: 64), (timer) { // ~64ms = 1024 samples at 16kHz
      if (!_isStreaming) {
        timer.cancel();
        return;
      }
      
      // Generate simple sine wave as mock audio
      final samples = <int>[];
      for (int i = 0; i < bufferSize ~/ 2; i++) { // 16-bit = 2 bytes per sample
        final time = (_packetsReceived * bufferSize ~/ 2 + i) / sampleRate;
        final amplitude = (math.sin(2 * math.pi * 440 * time) * 16000).round(); // 440Hz tone
        samples.add(amplitude & 0xFFFF); // Convert to 16-bit unsigned
      }
      
      // Convert to bytes (little endian)
      final bytes = <int>[];
      for (final sample in samples) {
        bytes.add(sample & 0xFF);
        bytes.add((sample >> 8) & 0xFF);
      }
      
      final audioData = Uint8List.fromList(bytes);
      _packetsReceived++;
      _bytesReceived += audioData.length;
      
      _audioDataController.add(audioData);
      
      // Log mock statistics
      if (_packetsReceived % 50 == 0) {
        _emit('🧪 Mock audio: $_packetsReceived packets, ${(_bytesReceived/1024).toStringAsFixed(1)}KB');
      }
    });
  }

  /// Stop mock audio stream
  void stopMockAudioStream() {
    if (!_isStreaming) return;
    
    _isStreaming = false;
    _emit('🧪 Mock audio stream stopped');
  }

  /// Cleanup resources
  void dispose() {
    stopAudioStream();
    _audioDataController.close();
    _emit('🧹 Frame audio service disposed');
  }
}

// Voice Activity Detection helper class
class VoiceActivityDetector {
  static const int windowSize = 1024; // Samples in analysis window
  static const double energyThreshold = 0.01; // Energy threshold for speech
  static const double zeroCrossingThreshold = 0.1; // Zero crossing rate threshold
  
  final List<double> _energyHistory = [];
  final int _historySize = 10; // Keep last 10 energy measurements
  
  final void Function(String) _emit;

  VoiceActivityDetector([void Function(String msg)? logger])
      : _emit = logger ?? ((_) {});

  /// Analyze audio buffer for voice activity
  bool detectVoiceActivity(Uint8List audioData) {
    try {
      // Convert bytes to 16-bit samples
      final samples = <double>[];
      for (int i = 0; i < audioData.length; i += 2) {
        if (i + 1 < audioData.length) {
          final sample = (audioData[i] | (audioData[i + 1] << 8));
          final normalizedSample = (sample > 32767 ? sample - 65536 : sample) / 32768.0;
          samples.add(normalizedSample);
        }
      }
      
      if (samples.isEmpty) return false;
      
      // Calculate energy (RMS)
      double energy = 0.0;
      for (final sample in samples) {
        energy += sample * sample;
      }
      energy = math.sqrt(energy / samples.length);
      
      // Calculate zero crossing rate
      int zeroCrossings = 0;
      for (int i = 1; i < samples.length; i++) {
        if ((samples[i] >= 0) != (samples[i - 1] >= 0)) {
          zeroCrossings++;
        }
      }
      final zeroCrossingRate = zeroCrossings / samples.length;
      
      // Update energy history
      _energyHistory.add(energy);
      if (_energyHistory.length > _historySize) {
        _energyHistory.removeAt(0);
      }
      
      // Calculate adaptive threshold based on recent history
      double adaptiveThreshold = energyThreshold;
      if (_energyHistory.length >= 3) {
        final avgEnergy = _energyHistory.reduce((a, b) => a + b) / _energyHistory.length;
        adaptiveThreshold = math.max(energyThreshold, avgEnergy * 2.0);
      }
      
      // Voice activity decision
      final hasVoiceActivity = energy > adaptiveThreshold && 
                               zeroCrossingRate > zeroCrossingThreshold &&
                               zeroCrossingRate < 0.8; // Not too noisy
      
      if (hasVoiceActivity) {
        _emit('🗣️ Voice detected: E=${energy.toStringAsFixed(4)}, ZCR=${zeroCrossingRate.toStringAsFixed(3)}');
      }
      
      return hasVoiceActivity;
      
    } catch (e) {
      _emit('❌ VAD error: $e');
      return false;
    }
  }

  /// Reset VAD state
  void reset() {
    _energyHistory.clear();
    _emit('🔄 VAD state reset');
  }
}