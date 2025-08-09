import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/code.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
// import 'package:google_generative_ai/google_generative_ai.dart'; // Not needed - using WebSocket realtime API
import 'package:path_provider/path_provider.dart';

// ObjectBox imports
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';
import 'package:frame_realtime_gemini_voicevision/services/frame_audio_streaming_service.dart';
import 'package:frame_realtime_gemini_voicevision/services/frame_gemini_realtime_integration.dart';
import 'package:frame_realtime_gemini_voicevision/gemini_realtime.dart' as gemini_realtime;
import 'package:frame_realtime_gemini_voicevision/audio_upsampler.dart';
import 'package:frame_realtime_gemini_voicevision/objectbox.g.dart';

// Foreground service (matches official repository)
import 'package:frame_realtime_gemini_voicevision/foreground_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Global ObjectBox store instance
late Store store;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize foreground service (matches official repository)
  initializeForegroundService();
  
  // Initialize ObjectBox
  await _initializeObjectBox();
  
  runApp(const MyApp());
}

Future<void> _initializeObjectBox() async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final storeDir = Directory('${appDir.path}/objectbox');
    
    store = await openStore(directory: storeDir.path);
    debugPrint('✅ ObjectBox initialized successfully');
  } catch (e) {
    debugPrint('❌ ObjectBox initialization failed: $e');
    rethrow;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Realtime Gemini Voice+Vision',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MainApp(title: 'Frame Realtime Gemini Voice+Vision'),
    );
  }
}

// Voice options for Gemini integration - matches official repository
enum GeminiVoiceName {
  puck('Puck'),
  charon('Charon'),
  kore('Kore'),
  fenrir('Fenrir'),
  aoede('Aoede');

  const GeminiVoiceName(this.displayName);
  final String displayName;
}

class MainApp extends StatefulWidget {
  const MainApp({super.key, required this.title});
  final String title;

  @override
  State<MainApp> createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // Frame connection using simple_frame_app
  // FrameApp is now available through the mixin
  bool _isConnected = false;
  bool _isScanning = false;
  
  // AI Configuration
  String _geminiApiKey = '';
  String? _tempApiKey; // Temporary storage for API key input
  GeminiVoiceName _selectedVoice = GeminiVoiceName.puck;
  // NOTE: Using WebSocket-based Gemini Realtime API only (matches official repository)
  // GenerativeModel? _model; // Not needed - using WebSocket realtime connection
  // ChatSession? _chatSession; // Not needed - using WebSocket realtime connection
  
  // Session state
  bool _isSessionActive = false;
  // ignore: unused_field
  Uint8List? _lastPhoto; // For integration service
  Widget? _image; // Original repo style photo display
  
  // Photo capture timer (like original repository)
  Timer? _photoTimer;
  
  // Audio state
  bool _isAudioStreaming = false;
  bool _isVoiceDetected = false;
  int _audioPacketsReceived = 0;
  int _totalAudioBytes = 0;
  
  // Event logging
  final List<String> _eventLog = [];
  final ScrollController _scrollController = ScrollController();
  
  // Vector database with MobileBERT
  VectorDbService? _vectorDb;
  
  // Frame audio streaming service
  FrameAudioStreamingService? _frameAudioService;
  
  // Complete Frame-Gemini integration service
  FrameGeminiRealtimeIntegration? _frameGeminiIntegration;
  gemini_realtime.GeminiRealtime? _geminiRealtime;
  
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<String>? _frameLogSubscription;
  StreamSubscription<dynamic>? _frameDataSubscription;
  
  // Audio response handling for fallback mode
  Timer? _audioResponseTimer;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _loadGeminiApiKey();
    _requestPermissions();
    _logEvent('🚀 App initialized with Frame SDK integration');
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _audioSubscription?.cancel();
    _frameLogSubscription?.cancel();
    _frameDataSubscription?.cancel();
    _photoTimer?.cancel(); // Clean up photo timer
    _audioResponseTimer?.cancel(); // Clean up audio response timer
    _frameAudioService?.dispose();
    _frameGeminiIntegration?.dispose();
    if (frame != null) {
      disconnectFrame();
    }
    _vectorDb?.dispose();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      // Configure Bluetooth logging (from official repo)
      // Note: Uncomment if flutter_blue_plus is available
      // FlutterBluePlus.setLogLevel(LogLevel.info);
      
      // Initialize only essential services at startup
      _vectorDb = VectorDbService(_logEvent);
      await _vectorDb!.initialize(store);
      
      _logEvent('🔧 Essential services initialized');
    } catch (e) {
      _logEvent('❌ Service initialization error: $e');
    }
  }
  
  /// Initialize Frame-specific services after successful connection
  Future<void> _initializeFrameServices() async {
    try {
      _logEvent('🔧 Initializing Frame services...');
      
      // Audio streaming now handled directly using official Frame protocol
      _logEvent('🎤 Audio will be handled via official Frame message protocol');
      
      // Initialize Gemini Realtime service  
      _geminiRealtime = gemini_realtime.GeminiRealtime(
        _handleGeminiAudioReady, // Audio ready callback for fallback mode
        _logEvent, // Event logger
      );
      
      // Frame audio logs handled directly in main message processing
      
      _logEvent('✅ Frame services initialized');
    } catch (e) {
      _logEvent('❌ Frame service initialization error: $e');
      rethrow;
    }
  }

  Future<void> _requestPermissions() async {
    // Official repository pattern: minimal explicit permission handling
    // Most permissions are handled by simple_frame_app package
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location, // Required for Bluetooth scanning
    ];

    final statuses = await permissions.request();
    bool coreGranted = statuses.values.every((status) => status.isGranted || status.isDenied);
    
    _logEvent(coreGranted ? '✅ Core permissions handled' : '⚠️ Permission issues detected');
  }

  Future<void> _loadGeminiApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _geminiApiKey = prefs.getString('gemini_api_key') ?? '';
    });
    
    if (_geminiApiKey.isNotEmpty) {
      // API key will be used by WebSocket realtime service when session starts
      _logEvent('🤖 Gemini API key loaded');
    } else {
      _logEvent('⚠️ No Gemini API key found');
    }
  }

  // No longer needed - using WebSocket-based Gemini Realtime API only
  // This matches the official repository pattern
  // void _initializeGemini() {
  //   // Chat-based Gemini is replaced by WebSocket realtime connection
  // }

  /// Get Gemini readiness status for UI display
  bool get isGeminiReady => _geminiApiKey.isNotEmpty;

  /// Map UI voice enum to Gemini Realtime voice enum
  gemini_realtime.GeminiVoiceName _mapVoiceName(GeminiVoiceName uiVoice) {
    switch (uiVoice) {
      case GeminiVoiceName.puck:
        return gemini_realtime.GeminiVoiceName.Puck;
      case GeminiVoiceName.charon:
        return gemini_realtime.GeminiVoiceName.Charon;
      case GeminiVoiceName.kore:
        return gemini_realtime.GeminiVoiceName.Kore;
      case GeminiVoiceName.fenrir:
        return gemini_realtime.GeminiVoiceName.Fenrir;
      case GeminiVoiceName.aoede:
        return gemini_realtime.GeminiVoiceName.Aoede;
    }
  }

  Future<void> _saveGeminiApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key);
    setState(() {
      _geminiApiKey = key;
      _tempApiKey = null; // Clear temp key
    });
    // API key will be used by WebSocket realtime service when session starts
    _logEvent('🔑 Gemini API key saved');
  }

  /// Connect to Frame using official repository pattern
  Future<void> _startScanning() async {
    if (_isScanning) return;
    
    setState(() {
      _isScanning = true;
    });
    
    _logEvent('🔍 Connecting to Frame...');
    
    try {
      // Official repository pattern: single unified connection method
      await tryScanAndConnectAndStart(andRun: true); // Deploy and start Lua scripts automatically
      
      // Check if connection and script deployment was successful
      if ((currentState == ApplicationState.ready || currentState == ApplicationState.running) && frame != null) {
        setState(() {
          _isConnected = true;
        });
        _logEvent('✅ Frame connected with official Lua scripts running');
        
        // Set up Frame listeners first (lightweight)
        _setupFrameListeners();
        
        // Initialize Frame services after successful connection
        await _initializeFrameServices();
      } else {
        _logEvent('❌ Frame connection/script deployment failed - state: $currentState');
      }
      
    } catch (e) {
      _logEvent('❌ Connection error: $e');
      setState(() {
        _isConnected = false;
      });
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  // Old connection method removed - now using official repository pattern with tryScanAndConnectAndStart()
  
  // Basic Frame connection test removed - simple_frame_app handles connection verification

  void _setupFrameListeners() {
    // Listen for raw data from Frame using the mixin's frame object
    if (frame != null) {
      _frameDataSubscription = frame!.dataResponse.listen((data) {
        if (data.isNotEmpty) {
          _logEvent('📦 Frame data received: ${data.length} bytes');
          
          // Handle official Frame message protocol
          final messageType = data[0];
          
          // Handle audio data messages (from Frame Lua script) - PRIORITY for performance
          if (messageType == 0x05 || messageType == 0x06) {
            // 0x05 = AUDIO_DATA_NON_FINAL_MSG, 0x06 = AUDIO_DATA_FINAL_MSG
            if (data.length > 1) {
              final audioData = Uint8List.fromList(data.sublist(1));
              _handleAudioData(audioData, messageType == 0x06);
            }
          }
          // Handle tap messages (0x09) - Quick check
          else if (messageType == 0x09) {
            _logEvent('👆 Frame tap detected');
          }
          // Handle photo data - optimized detection for performance
          else if (data.length > 500) { // Lower threshold for small photos
            // Check for JPEG after message type byte (official Frame protocol)
            if (data.length >= 3 && data[1] == 0xFF && data[2] == 0xD8) {
              try {
                final photoData = Uint8List.fromList(data.sublist(1));
                _logEvent('📸 Frame JPEG photo: ${photoData.length} bytes');
                _handlePhotoReceived(photoData);
              } catch (e) {
                _logEvent('⚠️ Frame photo error: $e');
              }
            }
            // Check for raw JPEG data (direct from Frame camera)
            else if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xD8) {
              try {
                final photoData = Uint8List.fromList(data);
                _logEvent('📸 Raw JPEG photo: ${data.length} bytes');
                _handlePhotoReceived(photoData);
              } catch (e) {
                _logEvent('⚠️ Raw photo error: $e');
              }
            }
          }
        }
      });
      
      // Connection monitoring handled by simple_frame_app package
    }
  }
  
  // Connection monitoring removed - handled by simple_frame_app package (official repository pattern)

  /// Initialize Frame audio services without deploying scripts (to avoid disconnection)
  Future<void> _initializeFrameAudioSimplified() async {
    if (frame == null || !_isConnected) {
      _logEvent('❌ Frame not available for audio initialization');
      return;
    }
    
    try {
      _logEvent('🎤 Preparing Frame audio services...');
      
      if (_geminiRealtime != null) {
        // For now, skip integration service creation - use direct Frame protocol
        _logEvent('🔗 Using direct Frame protocol - ready for audio streaming');
      }
      
    } catch (e) {
      _logEvent('❌ Audio service prep error: $e');
      _logEvent('ℹ️ Audio setup will be attempted when starting session');
    }
  }



  Future<void> _disconnect() async {
    try {
      if (frame != null && _isConnected) {
        await _stopSession();
        await disconnectFrame();
        
        setState(() {
          _isConnected = false;
          _isAudioStreaming = false;
          _audioPacketsReceived = 0;
          _totalAudioBytes = 0;
        });
        
        _logEvent('🔌 Disconnected from Frame');
      }
    } catch (e) {
      _logEvent('❌ Disconnect error: $e');
    }
  }

  Future<void> _startSession() async {
    if (_isSessionActive || !_isConnected || _geminiApiKey.isEmpty) {
      if (_geminiApiKey.isEmpty) {
        _logEvent('⚠️ Please set Gemini API key first');
        return;
      }
      if (!_isConnected) {
        _logEvent('⚠️ Frame not connected - please connect first');
        return;
      }
      return;
    }

    try {
      _logEvent('🚀 Starting AI session...');
      
      // Scripts are automatically deployed by simple_frame_app during connection
      _logEvent('📱 Frame ready - official Lua scripts already deployed');
      
      // Use the integrated service if available
      if (_frameGeminiIntegration != null) {
        final success = await _frameGeminiIntegration!.startSession(
          geminiApiKey: _geminiApiKey,
          voice: _mapVoiceName(_selectedVoice),
          systemInstruction: 'You are a helpful AI assistant integrated with Frame smart glasses. '
                           'You can see what the user sees through their camera and hear their voice. '
                           'Keep responses concise and conversational. The user is wearing Frame glasses.',
        );
        
        if (success) {
          setState(() {
            _isSessionActive = true;
          });
          _logEvent('✅ AI session started successfully');
          
          // Start foreground service for background operation (matches official repo)
          try {
            await startForegroundService();
            _logEvent('📱 Foreground service started');
          } catch (e) {
            _logEvent('⚠️ Foreground service warning: $e');
          }
          
          // Start camera capture for vision
          await _startCameraCapture();
        } else {
          _logEvent('❌ Failed to start AI session');
        }
      } else {
        // Fallback mode - connect to Gemini directly
        _logEvent('🔗 Connecting to Gemini (basic mode)...');
        
        final geminiConnected = await _geminiRealtime!.connect(
          _geminiApiKey,
          _mapVoiceName(_selectedVoice),
          'You are a helpful AI assistant integrated with Frame smart glasses. '
          'You can see what the user sees through their camera and hear their voice. '
          'Keep responses concise and conversational. The user is wearing Frame glasses.',
        );
        
        if (geminiConnected) {
          setState(() {
            _isSessionActive = true;
          });
          _logEvent('✅ AI session started (basic mode)');
          
          // Start audio streaming and camera
          await _startAudioStreaming();
          await _startCameraCapture();
        } else {
          _logEvent('❌ Failed to connect to Gemini');
        }
      }
    } catch (e) {
      _logEvent('❌ Session start error: $e');
    }
  }

  Future<void> _startAudioStreaming() async {
    if (_isAudioStreaming || !_isConnected || frame == null) return;
    
    try {
      _logEvent('🎤 Starting Frame audio streaming (official protocol)...');
      
      // Send audio subscription message using official Frame protocol
      // Message 0x30 (AUDIO_SUBS_MSG) with value 1 = start audio subscription
      await frame!.sendMessage(0x30, TxCode(value: 1).pack());
      
      setState(() {
        _isAudioStreaming = true;
        _audioPacketsReceived = 0;
        _totalAudioBytes = 0;
      });
      
      _logEvent('✅ Audio streaming started - Frame will send audio data via 0x05/0x06 messages');
    } catch (e) {
      _logEvent('❌ Audio streaming error: $e');
    }
  }

  Future<void> _stopAudioStreaming() async {
    if (!_isAudioStreaming || frame == null) return;
    
    try {
      _logEvent('⏹️ Stopping Frame audio streaming...');
      
      // Send audio unsubscribe message using official Frame protocol
      // Message 0x30 (AUDIO_SUBS_MSG) with value 0 = stop audio subscription
      await frame!.sendMessage(0x30, TxCode(value: 0).pack());
      
      setState(() {
        _isAudioStreaming = false;
        _isVoiceDetected = false;
      });
      
      _logEvent('✅ Audio streaming stopped');
    } catch (e) {
      _logEvent('❌ Audio stop error: $e');
    }
  }

  Future<void> _startCameraCapture() async {
    if (frame == null || !_isConnected) return;
    
    try {
      _logEvent('📷 Starting periodic camera capture...');
      
      // Start periodic photo capture like original repository (every 3 seconds)
      _photoTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (!_isConnected || !_isSessionActive) {
          timer.cancel();
          return;
        }
        
        try {
          // Request a photo using Frame SDK with higher quality
          await frame!.sendMessage(0x0d, TxCaptureSettings(
            qualityIndex: 75, // Higher quality like original
          ).pack());
        } catch (e) {
          _logEvent('⚠️ Periodic photo error: $e');
        }
      });
      
      // Take first photo immediately
      await frame!.sendMessage(0x0d, TxCaptureSettings(
        qualityIndex: 75,
      ).pack());
      
      _logEvent('📸 Periodic photo capture started');
    } catch (e) {
      _logEvent('❌ Camera capture error: $e');
    }
  }

  Future<void> _stopCameraCapture() async {
    _photoTimer?.cancel();
    _photoTimer = null;
    _logEvent('📷 Photo capture stopped');
  }

  /// Handle audio data received from Frame using official protocol
  void _handleAudioData(Uint8List audioData, bool isFinal) {
    if (audioData.isEmpty) return;
    
    // Update statistics
    _audioPacketsReceived++;
    _totalAudioBytes += audioData.length;
    
    // Log statistics periodically
    if (_audioPacketsReceived % 50 == 0) {
      _logEvent('📊 Audio: $_audioPacketsReceived packets, ${(_totalAudioBytes/1024).toStringAsFixed(1)} KB');
    }
    
    // Send audio data to Gemini directly (official repository pattern)
    if (_geminiRealtime != null && _isSessionActive && _geminiRealtime!.isConnected()) {
      try {
        // Upsample Frame audio from 8kHz to 16kHz for Gemini
        final upsampledAudio = AudioUpsampler.upsample8kTo16k(audioData);
        _geminiRealtime!.sendAudio(upsampledAudio);
      } catch (e) {
        _logEvent('❌ Gemini audio send error: $e');
      }
    }
    
    if (isFinal) {
      _logEvent('🎤 Audio stream ended (final message received)');
    }
  }

  /// Handle audio ready callback from Gemini in fallback mode
  void _handleGeminiAudioReady() {
    // Start monitoring for audio responses if not already started
    _audioResponseTimer ??= Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _checkForGeminiAudioResponse();
    });
  }

  /// Check for and play audio responses from Gemini (fallback mode)
  void _checkForGeminiAudioResponse() {
    if (_geminiRealtime != null && _geminiRealtime!.hasResponseAudio()) {
      try {
        final responseAudio = _geminiRealtime!.getResponseAudioByteData();
        if (responseAudio.lengthInBytes > 0) {
          _logEvent('🔊 Playing Gemini response (${responseAudio.lengthInBytes} bytes)');
          
          // For now, just log that we received audio
          // TODO: Add actual audio playback implementation if needed
          // The main thing is that Gemini is responding, which means the connection works
        }
      } catch (e) {
        _logEvent('❌ Audio response error: $e');
      }
    }
  }

  /// Handle photo received from Frame (original repo style)
  void _handlePhotoReceived(Uint8List photoData) {
    _logEvent('📸 Photo received from Frame');
    
    // Send photo to Gemini if connected (original repo pattern)
    if (_geminiRealtime != null && _geminiRealtime!.isConnected()) {
      _geminiRealtime!.sendPhoto(photoData);
      _logEvent('📸 Photo sent to Gemini for analysis');
    }

    // Update UI with latest image (original repo style)
    setState(() {
      _lastPhoto = photoData;
      _image = Image.memory(photoData, gaplessPlayback: true);
    });
    
    // Send photo to the integration service if active (preserve existing functionality)
    if (_frameGeminiIntegration != null) {
      _frameGeminiIntegration!.setLastCapturedPhoto(photoData);
    }
  }

  Future<void> _stopSession() async {
    if (!_isSessionActive) return;

    try {
      // Stop photo capture first
      await _stopCameraCapture();
      
      // Use the new integrated service if available
      if (_frameGeminiIntegration != null) {
        await _frameGeminiIntegration!.stopSession();
        _logEvent('⏹️ Complete AI session stopped');
        
        // Stop audio response monitoring in case it was running
        _audioResponseTimer?.cancel();
        _audioResponseTimer = null;
      } else {
        // Fall back to the old method
        await _stopAudioStreaming();
        
        // Disconnect from Gemini in basic mode
        if (_geminiRealtime != null) {
          await _geminiRealtime!.disconnect();
        }
        
        // Stop audio response monitoring
        _audioResponseTimer?.cancel();
        _audioResponseTimer = null;
        
        _logEvent('⏹️ AI session stopped (fallback mode)');
      }

      setState(() {
        _isSessionActive = false;
        _image = null; // Clear image display when session ends
      });
      
      // Stop foreground service
      try {
        await FlutterForegroundTask.stopService();
        _logEvent('📱 Foreground service stopped');
      } catch (e) {
        _logEvent('⚠️ Foreground service stop warning: $e');
      }
    } catch (e) {
      _logEvent('❌ Session stop error: $e');
      setState(() {
        _isSessionActive = false;
      });
    }
  }

  Future<void> _testFrameConnection() async {
    if (frame == null || !_isConnected) {
      _logEvent('❌ Frame not connected');
      return;
    }
    
    try {
      _logEvent('🧪 Testing Frame connection...');
      
      // Test Frame audio service connection if available
      if (_frameAudioService != null) {
        final connectionOk = await _frameAudioService!.testConnection();
        if (connectionOk) {
          _logEvent('✅ Frame connection test passed');
        } else {
          _logEvent('⚠️ Frame connection test had issues');
        }
      } else {
        // Fallback basic test
        await frame!.sendMessage(0x0a, TxPlainText(
          text: 'Hello Frame!',
          x: 50,
          y: 50,
          paletteOffset: 2,
        ).pack());
        _logEvent('📺 Basic Frame test completed');
      }
      
    } catch (e) {
      _logEvent('❌ Frame test failed: $e');
    }
  }
  
  Future<void> _testAudioConnection() async {
    if (_frameAudioService == null || !_isConnected) {
      _logEvent('❌ Audio service not available');
      return;
    }
    
    try {
      _logEvent('🎤 Testing Frame audio capability...');
      final audioOk = await _frameAudioService!.testAudioCapability();
      
      if (audioOk) {
        _logEvent('✅ Frame audio test completed - check Frame display');
      } else {
        _logEvent('❌ Frame audio test failed');
      }
      
    } catch (e) {
      _logEvent('❌ Audio test error: $e');
    }
  }
  
  Future<void> _reinitializeAudio() async {
    if (!_isConnected || frame == null) {
      _logEvent('❌ Frame not connected');
      return;
    }
    
    try {
      _logEvent('🔄 Reinitializing Frame audio service...');
      
      // Stop current session if active
      if (_isSessionActive) {
        await _stopSession();
      }
      
      // Dispose current audio service
      _frameAudioService?.dispose();
      _frameGeminiIntegration?.dispose();
      
      // Recreate and reinitialize
      _frameAudioService = FrameAudioStreamingService(_logEvent);
      await _initializeFrameAudioSimplified();
      
    } catch (e) {
      _logEvent('❌ Audio reinitialization failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Scrollable content area
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // Gemini API Key Section
                    _buildGeminiApiKeySection(),
                    const SizedBox(height: 16),
                    
                    // Voice Selection
                    if (_geminiApiKey.isNotEmpty) _buildVoiceSelection(),
                    if (_geminiApiKey.isNotEmpty) const SizedBox(height: 16),
                    
                    // Frame Connection Section
                    _buildFrameConnectionSection(),
                    const SizedBox(height: 16),
                    
                    // Audio Status Section
                    if (_isConnected) _buildAudioStatusSection(),
                    if (_isConnected) const SizedBox(height: 16),
                    
                    // Live Photo View (original repo style)
                    _image ?? Container(),
                    const SizedBox(height: 16),
                    
                    // Control Buttons
                    _buildControlButtons(),
                    const SizedBox(height: 16),
                    
                    // Event Log with fixed height
                    SizedBox(
                      height: 300, // Fixed height for event log
                      child: _buildEventLog(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioStatusSection() {
    final kbps = _audioPacketsReceived > 0 && _totalAudioBytes > 0
        ? (_totalAudioBytes / 1024.0) / (_audioPacketsReceived * 0.064) // ~64ms per packet
        : 0.0;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🎤 Frame Audio Status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            
            // Audio streaming status
            Row(
              children: [
                Icon(
                  _isAudioStreaming ? Icons.mic : Icons.mic_off,
                  color: _isAudioStreaming ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  _isAudioStreaming ? 'Audio Streaming Active' : 'Audio Streaming Inactive',
                  style: TextStyle(
                    color: _isAudioStreaming ? Colors.green : Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Voice activity status
            Row(
              children: [
                Icon(
                  _isVoiceDetected ? Icons.record_voice_over : Icons.voice_over_off,
                  color: _isVoiceDetected ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  _isVoiceDetected ? 'Voice Activity Detected' : 'No Voice Activity',
                  style: TextStyle(
                    color: _isVoiceDetected ? Colors.blue : Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Audio statistics
            Row(
              children: [
                const Icon(Icons.data_usage, color: Colors.orange),
                const SizedBox(width: 8),
                Text(
                  'Packets: $_audioPacketsReceived | ${(_totalAudioBytes / 1024).toStringAsFixed(1)} KB | ${kbps.toStringAsFixed(1)} KB/s',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButtons() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🎮 Controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            
            // Main session controls
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnected && !_isSessionActive && _geminiApiKey.isNotEmpty) 
                        ? _startSession 
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start AI Session'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.withAlpha(25),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isSessionActive ? _stopSession : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Session'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.withAlpha(25),
                    ),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Testing controls
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isConnected ? _testFrameConnection : null,
                    icon: const Icon(Icons.troubleshoot),
                    label: const Text('Test Frame'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnected && _frameAudioService != null) ? _testAudioConnection : null,
                    icon: const Icon(Icons.mic_external_on),
                    label: const Text('Test Audio'),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Photo and diagnostic controls
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnected && _isSessionActive && _frameGeminiIntegration != null) 
                        ? () => _frameGeminiIntegration!.captureAndSendPhoto() 
                        : _isConnected ? _startCameraCapture : null,
                    icon: const Icon(Icons.camera),
                    label: Text(_isSessionActive ? 'Capture & Send to AI' : 'Take Photo'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isConnected && _frameAudioService != null) ? _reinitializeAudio : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reinit Audio'),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Database controls
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _vectorDb?.addSampleData(),
                    icon: const Icon(Icons.data_array),
                    label: const Text('Add Sample Data'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (_vectorDb != null) {
                        final stats = await _vectorDb!.getStats();
                        _logEvent('📊 DB Stats: ${stats['totalDocuments']} docs');
                      }
                    },
                    icon: const Icon(Icons.analytics),
                    label: const Text('DB Stats'),
                  ),
                ),
              ],
            ),
            
            // Status messages
            if (_isSessionActive)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  _frameGeminiIntegration != null 
                    ? '🚀 Complete AI session active with Frame' 
                    : '🎤 AI session active with Frame (basic mode)',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: _frameGeminiIntegration != null ? Colors.green : Colors.blue,
                  ),
                ),
              ),
            if (!_isConnected)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(
                  '⚠️ Connect to Frame first',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.orange,
                  ),
                ),
              ),
            if (_geminiApiKey.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(
                  '⚠️ Set Gemini API key first',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.orange,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeminiApiKeySection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🤖 Gemini Configuration',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _geminiApiKey,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API Key',
                      hintText: 'Enter your Gemini API key',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    onChanged: (value) {
                      setState(() {
                        _tempApiKey = value;
                      });
                    },
                    onFieldSubmitted: (value) {
                      if (value.isNotEmpty) {
                        _saveGeminiApiKey(value);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: (_tempApiKey?.isNotEmpty ?? false) ? () => _saveGeminiApiKey(_tempApiKey!) : null,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
              ],
            ),
            if (_geminiApiKey.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Row(
                  children: [
                    Icon(
                      isGeminiReady ? Icons.check_circle : Icons.pending,
                      color: isGeminiReady ? Colors.green : Colors.orange,
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isGeminiReady ? 'Gemini ready' : 'Gemini initializing',
                      style: TextStyle(
                        color: isGeminiReady ? Colors.green : Colors.orange,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceSelection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🎭 Voice Selection',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<GeminiVoiceName>(
              value: _selectedVoice,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'TTS Voice',
              ),
              items: GeminiVoiceName.values.map((voice) {
                return DropdownMenuItem(
                  value: voice,
                  child: Text(voice.displayName),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedVoice = value;
                  });
                  _logEvent('🎭 Voice changed to: ${value.displayName}');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrameConnectionSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '📱 Frame Connection',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_isConnected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.withAlpha(50),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withAlpha(128)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bluetooth_connected, color: Colors.green, size: 16),
                        SizedBox(width: 4),
                        Text('Connected', style: TextStyle(color: Colors.green)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isScanning || _isConnected ? null : _startScanning,
                    icon: _isScanning 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(_isScanning ? 'Connecting...' : 'Connect to Frame'),
                  ),
                ),
                const SizedBox(width: 8),
                if (_isConnected)
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _disconnect,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: const Text('Disconnect'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.withAlpha(25),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildEventLog() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '📋 Event Log',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_eventLog.isNotEmpty)
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _eventLog.clear();
                      });
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.withAlpha(75)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _eventLog.isEmpty
                    ? const Center(
                        child: Text(
                          'No events logged yet...',
                          style: TextStyle(
                            color: Colors.grey,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: _eventLog.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              _eventLog[index],
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _logEvent(String event) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    final logEntry = '[$timestamp] $event';
    
    setState(() {
      _eventLog.add(logEntry);
    });

    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Required methods for SimpleFrameAppState mixin
  @override
  Future<void> run() async {
    _logEvent('🏃 Frame app run - Lua scripts are now running');
    currentState = ApplicationState.running;
    if (mounted) setState(() {});
    
    // The Frame is now running the official Lua script from assets/frame_app.lua
    // The script handles audio streaming, camera capture, and display updates
    // We can now send messages to the Frame using the official message protocol
    
    try {
      // Send initial message to Frame display (like official repository)
      await frame!.sendMessage(0x0b, TxPlainText(
        text: 'Frame Connected!\nReady for AI',
        x: 1,
        y: 1,
        paletteOffset: 2,
      ).pack());
      
      _logEvent('✅ Frame display initialized');
    } catch (e) {
      _logEvent('⚠️ Frame display setup: $e');
    }
  }

  @override
  Future<void> cancel() async {
    _logEvent('⏹️ Canceling Frame app');
    await _stopSession();
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }
  
}
