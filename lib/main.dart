import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

// ObjectBox imports
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';
import 'package:frame_realtime_gemini_voicevision/services/frame_audio_streaming_service.dart';
import 'package:frame_realtime_gemini_voicevision/services/frame_gemini_realtime_integration.dart';
import 'package:frame_realtime_gemini_voicevision/gemini_realtime.dart' as gemini_realtime;
import 'package:frame_realtime_gemini_voicevision/objectbox.g.dart';

// Global ObjectBox store instance
late Store store;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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

// Voice options for Gemini integration
enum GeminiVoiceName {
  puck('Puck'),
  charon('Charon'),
  kore('Kore'),
  fenrir('Fenrir');

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
  GeminiVoiceName _selectedVoice = GeminiVoiceName.puck;
  GenerativeModel? _model; // TODO: Will be used for Gemini chat sessions
  ChatSession? _chatSession;
  
  // Session state
  bool _isSessionActive = false;
  Uint8List? _lastPhoto;
  
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
      
      // Initialize Frame audio streaming service
      _frameAudioService = FrameAudioStreamingService(_logEvent);
      
      // Initialize Gemini Realtime service  
      _geminiRealtime = gemini_realtime.GeminiRealtime(
        () {}, // Audio ready callback - handled by integration service
        _logEvent, // Event logger
      );
      
      // Subscribe to Frame audio service logs
      _frameLogSubscription = _frameAudioService!.logStream.listen(_logEvent);
      
      _logEvent('✅ Frame services initialized');
    } catch (e) {
      _logEvent('❌ Frame service initialization error: $e');
      rethrow;
    }
  }

  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.camera,
      Permission.microphone,
      Permission.bluetoothAdvertise,
      Permission.location,
    ];

    final statuses = await permissions.request();
    bool allGranted = statuses.values.every((status) => status.isGranted);
    
    _logEvent(allGranted ? '✅ All permissions granted' : '⚠️ Some permissions denied');
  }

  Future<void> _loadGeminiApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _geminiApiKey = prefs.getString('gemini_api_key') ?? '';
    });
    
    if (_geminiApiKey.isNotEmpty) {
      _initializeGemini();
      _logEvent('🤖 Gemini API key loaded');
    } else {
      _logEvent('⚠️ No Gemini API key found');
    }
  }

  void _initializeGemini() {
    try {
      _model = GenerativeModel(
        model: 'gemini-2.0-flash-exp',
        apiKey: _geminiApiKey,
        generationConfig: GenerationConfig(
          temperature: 0.7,
          maxOutputTokens: 1000,
        ),
        systemInstruction: Content.system(
          'You are a helpful AI assistant integrated with Frame smart glasses. '
          'You can see what the user sees through their camera and hear their voice through the microphone. '
          'Provide natural, conversational responses. Keep responses concise but helpful. '
          'You have access to conversation history through local vector search for context. '
          'The user is speaking to you through Frame glasses with real-time audio.'
        ),
      );

      _chatSession = _model!.startChat();
      _logEvent('🤖 Gemini conversation model initialized');
    } catch (e) {
      _logEvent('❌ Gemini initialization failed: $e');
    }
  }

  /// Get Gemini chat session status for UI display
  bool get isGeminiReady => _chatSession != null;

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
    }
  }

  Future<void> _saveGeminiApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key);
    setState(() {
      _geminiApiKey = key;
    });
    _initializeGemini();
    _logEvent('🔑 API key saved and Gemini initialized');
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;
    
    setState(() {
      _isScanning = true;
    });
    
    _logEvent('🔍 Scanning for Frame devices...');
    
    try {
      // Simple Frame App handles scanning and connection in one step
      await _connectToFrame();
      
    } catch (e) {
      _logEvent('❌ Scan error: $e');
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _connectToFrame() async {
    try {
      _logEvent('🔗 Connecting to Frame...');
      
      // Simplified connection following official pattern
      await scanOrReconnectFrame();
      
      if (currentState == ApplicationState.connected) {
        setState(() {
          _isConnected = true;
        });
        
        _logEvent('✅ Frame connected successfully');
        
        // Initialize Frame-specific services only after connection
        await _initializeFrameServices();
        
        // Setup Frame listeners
        _setupFrameListeners();
        
        // Initialize Frame audio with simplified approach
        await _initializeFrameAudioSimplified();
      } else {
        _logEvent('❌ Frame connection failed');
        setState(() {
          _isConnected = false;
        });
      }
      
    } catch (e) {
      _logEvent('❌ Connection error: $e');
      setState(() {
        _isConnected = false;
      });
    }
  }

  void _setupFrameListeners() {
    // Listen for raw data from Frame using the mixin's frame object
    if (frame != null) {
      _frameDataSubscription = frame!.dataResponse.listen((data) {
        if (data.isNotEmpty) {
          _logEvent('📦 Frame data received: ${data.length} bytes');
          
          // Check if this might be photo data
          if (data.length > 1000) { // Photos are typically larger
            try {
              final photoData = Uint8List.fromList(data);
              _handlePhotoReceived(photoData);
            } catch (e) {
              _logEvent('⚠️ Photo processing error: $e');
            }
          }
        }
      });
    }
  }

  /// Simplified Frame audio initialization following official pattern
  Future<void> _initializeFrameAudioSimplified() async {
    if (frame == null || !_isConnected) {
      _logEvent('❌ Frame not available for audio initialization');
      return;
    }
    
    try {
      _logEvent('🎤 Initializing Frame audio (simplified)...');
      
      // Test Frame responsiveness first
      await frame!.sendString('print("Audio init test")', awaitResponse: false);
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (_frameAudioService != null) {
        // Simplified initialization - no complex Lua deployment
        final success = await _frameAudioService!.testConnection();
        
        if (success) {
          _logEvent('✅ Frame audio connection verified');
          
          // Create integration service only if basic connection works
          if (_geminiRealtime != null) {
            _frameGeminiIntegration = FrameGeminiRealtimeIntegration(
              frameAudioService: _frameAudioService!,
              geminiRealtime: _geminiRealtime!,
              frameDevice: frame,
              vectorDb: _vectorDb,
              logger: _logEvent,
            );
            
            // Simple integration initialization
            final integrationReady = await _frameGeminiIntegration!.initialize();
            if (integrationReady) {
              _logEvent('✅ Ready for voice conversations');
              
              // Set up audio stream listener
              _audioSubscription = _frameAudioService!.audioStream.listen(_handleAudioData);
            } else {
              _logEvent('⚠️ Integration setup had issues, basic audio available');
            }
          }
        } else {
          _logEvent('⚠️ Frame audio test failed, will retry on session start');
        }
      }
      
    } catch (e) {
      _logEvent('❌ Simplified audio init error: $e');
      _logEvent('ℹ️ Will attempt audio setup when starting session');
    }
  }

  void _handleAudioData(Uint8List audioData) {
    setState(() {
      _audioPacketsReceived++;
      _totalAudioBytes += audioData.length;
    });
    
    // Perform voice activity detection
    final voiceDetected = _detectVoiceActivity(audioData);
    if (voiceDetected != _isVoiceDetected) {
      setState(() {
        _isVoiceDetected = voiceDetected;
      });
      
      if (voiceDetected) {
        _logEvent('🗣️ Voice activity detected');
      } else {
        _logEvent('🤫 Voice activity stopped');
      }
    }
    
    // Audio processing now handled by FrameGeminiRealtimeIntegration service
  }

  bool _detectVoiceActivity(Uint8List audioData) {
    // Simple energy-based VAD
    double energy = 0.0;
    for (int i = 0; i < audioData.length; i += 2) {
      if (i + 1 < audioData.length) {
        final sample = (audioData[i] | (audioData[i + 1] << 8));
        final normalizedSample = (sample > 32767 ? sample - 65536 : sample) / 32768.0;
        energy += normalizedSample * normalizedSample;
      }
    }
    energy = energy / (audioData.length / 2);
    
    return energy > 0.01; // Simple threshold
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
      return;
    }

    try {
      _logEvent('🚀 Starting complete AI session...');
      
      // Use the new integrated service if available
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
          _logEvent('✅ Complete AI session started successfully');
          
          // Start camera capture for vision
          await _startCameraCapture();
        } else {
          _logEvent('❌ Failed to start complete AI session');
        }
      } else {
        // Fall back to the old method
        setState(() {
          _isSessionActive = true;
        });
        _logEvent('🎤 AI session started with Frame audio (fallback mode)');
        
        // Start audio streaming
        await _startAudioStreaming();
        
        // Start camera capture
        await _startCameraCapture();
      }
    } catch (e) {
      _logEvent('❌ Session start error: $e');
    }
  }

  Future<void> _startAudioStreaming() async {
    if (_frameAudioService == null || _isAudioStreaming || !_isConnected) return;
    
    try {
      // Use 16kHz/8-bit for better reliability (16 kB/s)
      final success = await _frameAudioService!.startStreaming(
        sampleRate: 16000,
        bitDepth: 8,
      );
      
      if (success) {
        setState(() {
          _isAudioStreaming = true;
          _audioPacketsReceived = 0;
          _totalAudioBytes = 0;
        });
        _logEvent('🎤 Audio streaming started (16kHz/8-bit)');
      } else {
        _logEvent('❌ Failed to start audio streaming');
      }
    } catch (e) {
      _logEvent('❌ Audio streaming error: $e');
    }
  }

  Future<void> _stopAudioStreaming() async {
    if (_frameAudioService == null || !_isAudioStreaming) return;
    
    try {
      await _frameAudioService!.stopStreaming();
      
      setState(() {
        _isAudioStreaming = false;
        _isVoiceDetected = false;
      });
      
      _logEvent('⏹️ Audio streaming stopped');
    } catch (e) {
      _logEvent('❌ Audio stop error: $e');
    }
  }

  Future<void> _startCameraCapture() async {
    if (frame == null || !_isConnected) return;
    
    try {
      _logEvent('📷 Starting camera capture...');
      
      // Request a photo using Frame SDK
      await frame!.sendMessage(0x0d, TxCaptureSettings(
        qualityIndex: 50,
      ).pack());
      
      _logEvent('📸 Photo request sent');
    } catch (e) {
      _logEvent('❌ Camera capture error: $e');
    }
  }

  /// Handle photo received from Frame and send to integration service
  void _handlePhotoReceived(Uint8List photoData) {
    setState(() {
      _lastPhoto = photoData;
    });
    
    // Send photo to the integration service if active
    if (_frameGeminiIntegration != null) {
      // Update the integration service with the new photo
      _frameGeminiIntegration!.setLastCapturedPhoto(photoData);
      
      if (_isSessionActive) {
        _logEvent('📸 Photo received and available for AI analysis');
      } else {
        _logEvent('📸 Photo received and cached');
      }
    }
  }

  Future<void> _stopSession() async {
    if (!_isSessionActive) return;

    try {
      // Use the new integrated service if available
      if (_frameGeminiIntegration != null) {
        await _frameGeminiIntegration!.stopSession();
        _logEvent('⏹️ Complete AI session stopped');
      } else {
        // Fall back to the old method
        await _stopAudioStreaming();
        _logEvent('⏹️ AI session stopped (fallback mode)');
      }

      setState(() {
        _isSessionActive = false;
      });
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
                    
                    // Live Photo View
                    if (_lastPhoto != null) _buildPhotoView(),
                    if (_lastPhoto != null) const SizedBox(height: 16),
                    
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
                      backgroundColor: Colors.green.withValues(alpha: 0.1),
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
                      backgroundColor: Colors.red.withValues(alpha: 0.1),
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
            TextFormField(
              initialValue: _geminiApiKey,
              decoration: const InputDecoration(
                labelText: 'Gemini API Key',
                hintText: 'Enter your Gemini API key',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              onFieldSubmitted: (value) {
                if (value.isNotEmpty) {
                  _saveGeminiApiKey(value);
                }
              },
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
                      color: Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
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
                        backgroundColor: Colors.red.withValues(alpha: 0.1),
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

  Widget _buildPhotoView() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '📷 Live Camera View',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: 250,
                minHeight: 150,
              ),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _lastPhoto != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          _lastPhoto!,
                          fit: BoxFit.contain,
                          width: double.infinity,
                        ),
                      )
                    : const Center(
                        child: Text('No photo captured yet'),
                      ),
              ),
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
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
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
    _logEvent('🏃 Starting Frame app run');
    currentState = ApplicationState.running;
    if (mounted) setState(() {});
    // The actual running logic is handled by the session management
  }

  @override
  Future<void> cancel() async {
    _logEvent('⏹️ Canceling Frame app');
    await _stopSession();
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }
}
