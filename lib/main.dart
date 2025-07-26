import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path_provider/path_provider.dart';

// ObjectBox imports
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';
import 'package:frame_realtime_gemini_voicevision/services/frame_audio_service.dart';
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

class MainAppState extends State<MainApp> {
  // Connection state
  bool _isScanning = false;
  final List<fbp.BluetoothDevice> _availableDevices = [];
  fbp.BluetoothDevice? _connectedDevice;
  
  // AI Configuration
  String _geminiApiKey = '';
  GeminiVoiceName _selectedVoice = GeminiVoiceName.puck;
  GenerativeModel? _model;
  ChatSession? _chatSession;
  
  // Session state
  bool _isSessionActive = false;
  Uint8List? _lastPhoto;
  
  // Audio state
  bool _isAudioStreaming = false;
  bool _isVoiceDetected = false;
  int _audioPacketsReceived = 0;
  
  // Event logging
  final List<String> _eventLog = [];
  final ScrollController _scrollController = ScrollController();
  
  // Vector database with MobileBERT
  VectorDbService? _vectorDb;
  
  // NEW: Frame audio service
  FrameAudioService? _frameAudio;
  VoiceActivityDetector? _vad;
  StreamSubscription<Uint8List>? _audioSubscription;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _loadGeminiApiKey();
    _requestPermissions();
    _logEvent('🚀 App initialized with MobileBERT embeddings + Frame audio');
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _audioSubscription?.cancel();
    _frameAudio?.dispose();
    _connectedDevice?.disconnect();
    _vectorDb?.dispose();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize vector database with MobileBERT
      _vectorDb = VectorDbService(_logEvent);
      await _vectorDb!.initialize(store);
      
      // Initialize Frame audio service
      _frameAudio = FrameAudioService(_logEvent);
      
      // Initialize voice activity detector
      _vad = VoiceActivityDetector(_logEvent);
      
      _logEvent('🔧 Services initialized with MobileBERT + Audio');
    } catch (e) {
      _logEvent('❌ Service initialization error: $e');
      // Continue anyway - some services might still work
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
      Permission.audio, // NEW: Audio recording permission
    ];

    final statuses = await permissions.request();
    bool allGranted = statuses.values.every((status) => status.isGranted);
    
    _logEvent(allGranted ? '✅ All permissions granted' : '⚠️ Some permissions denied');
    
    // Check critical audio permissions
    if (statuses[Permission.microphone] != PermissionStatus.granted) {
      _logEvent('⚠️ Microphone permission required for audio features');
    }
    if (statuses[Permission.audio] != PermissionStatus.granted) {
      _logEvent('⚠️ Audio permission required for recording');
    }
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
      _logEvent('🤖 Gemini conversation model initialized with audio support');
    } catch (e) {
      _logEvent('❌ Gemini initialization failed: $e');
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
      _availableDevices.clear();
    });
    
    _logEvent('🔍 Scanning for Frame devices...');
    
    try {
      // Check Bluetooth state
      if (await fbp.FlutterBluePlus.isSupported == false) {
        _logEvent('❌ Bluetooth not supported');
        return;
      }

      // Wait for Bluetooth to be ready
      await fbp.FlutterBluePlus.adapterState
          .where((state) => state == fbp.BluetoothAdapterState.on)
          .first;
      
      // Start scanning
      await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      
      // Listen for scan results
      fbp.FlutterBluePlus.scanResults.listen((results) {
        for (fbp.ScanResult result in results) {
          final deviceName = result.device.platformName.toLowerCase();
          if (deviceName.contains('frame') || deviceName.contains('brilliant')) {
            if (!_availableDevices.any((d) => d.remoteId == result.device.remoteId)) {
              setState(() {
                _availableDevices.add(result.device);
              });
              _logEvent('📱 Found device: ${result.device.platformName}');
            }
          }
        }
      });
      
      // Stop scanning after timeout
      await Future.delayed(const Duration(seconds: 10));
      await fbp.FlutterBluePlus.stopScan();
      
    } catch (e) {
      _logEvent('❌ Scan error: $e');
    } finally {
      setState(() {
        _isScanning = false;
      });
      _logEvent('🔍 Scan completed');
    }
  }

  Future<void> _connectToDevice(fbp.BluetoothDevice device) async {
    try {
      _logEvent('🔗 Connecting to ${device.platformName}...');
      
      await device.connect();
      
      setState(() {
        _connectedDevice = device;
      });
      
      _logEvent('✅ Connected to ${device.platformName}');
      
      // NEW: Initialize Frame audio service after connection
      await _initializeFrameAudio();
      
    } catch (e) {
      _logEvent('❌ Connection failed: $e');
      setState(() {
        _connectedDevice = null;
      });
    }
  }

  // NEW: Initialize Frame audio service
  Future<void> _initializeFrameAudio() async {
    if (_connectedDevice == null || _frameAudio == null) return;
    
    try {
      _logEvent('🎤 Initializing Frame audio service...');
      
      final success = await _frameAudio!.initialize(_connectedDevice!);
      if (success) {
        _logEvent('✅ Frame audio service ready');
        _logEvent('🎉 Ready for voice conversations!');
        
        // Setup audio stream listener
        _audioSubscription = _frameAudio!.audioDataStream.listen(_handleAudioData);
        
      } else {
        _logEvent('❌ Frame audio service initialization failed');
      }
    } catch (e) {
      _logEvent('❌ Frame audio initialization error: $e');
    }
  }

  // NEW: Handle incoming audio data
  void _handleAudioData(Uint8List audioData) {
    setState(() {
      _audioPacketsReceived++;
    });
    
    // Perform voice activity detection
    if (_vad != null) {
      final voiceDetected = _vad!.detectVoiceActivity(audioData);
      if (voiceDetected != _isVoiceDetected) {
        setState(() {
          _isVoiceDetected = voiceDetected;
        });
        
        if (voiceDetected) {
          _logEvent('🗣️ Voice activity started');
        } else {
          _logEvent('🤫 Voice activity stopped');
        }
      }
    }
    
    // TODO: Process audio for speech-to-text
    // This is where we'll add speech recognition in the next phase
  }

  Future<void> _disconnect() async {
    try {
      if (_connectedDevice != null) {
        _stopSession();
        await _connectedDevice!.disconnect();
        
        setState(() {
          _connectedDevice = null;
          _isAudioStreaming = false;
          _audioPacketsReceived = 0;
        });
        
        _logEvent('🔌 Disconnected from Frame');
      }
    } catch (e) {
      _logEvent('❌ Disconnect error: $e');
    }
  }

  Future<void> _startSession() async {
    if (_isSessionActive || _connectedDevice == null || _geminiApiKey.isEmpty) {
      if (_geminiApiKey.isEmpty) {
        _logEvent('⚠️ Please set Gemini API key first');
        return;
      }
      return;
    }

    setState(() {
      _isSessionActive = true;
    });

    _logEvent('🎤 AI session started with Frame audio');
    
    // Start audio streaming
    await _startAudioStreaming();
    
    // Simulate conversation context retrieval
    _simulateContextAwareConversation();
  }

  // NEW: Start audio streaming
  Future<void> _startAudioStreaming() async {
    if (_frameAudio == null || _isAudioStreaming) return;
    
    try {
      bool success;
      
      // Use mock audio in Codespace, real audio on device
      if (!Platform.isAndroid) {
        // Codespace development - use mock audio
        _frameAudio!.startMockAudioStream();
        success = true;
        _logEvent('🧪 Started mock audio stream for Codespace testing');
      } else {
        // Real device - use Frame hardware
        success = await _frameAudio!.startAudioStream();
      }
      
      if (success) {
        setState(() {
          _isAudioStreaming = true;
          _audioPacketsReceived = 0;
        });
        _logEvent('🎤 Audio streaming active');
      } else {
        _logEvent('❌ Failed to start audio streaming');
      }
    } catch (e) {
      _logEvent('❌ Audio streaming error: $e');
    }
  }

  // NEW: Stop audio streaming
  Future<void> _stopAudioStreaming() async {
    if (_frameAudio == null || !_isAudioStreaming) return;
    
    try {
      if (!Platform.isAndroid) {
        _frameAudio!.stopMockAudioStream();
      } else {
        await _frameAudio!.stopAudioStream();
      }
      
      setState(() {
        _isAudioStreaming = false;
        _isVoiceDetected = false;
      });
      
      _logEvent('⏹️ Audio streaming stopped');
    } catch (e) {
      _logEvent('❌ Audio stop error: $e');
    }
  }

  void _stopSession() {
    if (!_isSessionActive) return;

    _stopAudioStreaming();

    setState(() {
      _isSessionActive = false;
    });

    _logEvent('⏹️ AI session stopped');
  }

  Future<void> _simulateContextAwareConversation() async {
    if (!_isSessionActive || _chatSession == null) return;
    
    try {
      const userQuery = 'Hello! I am testing the Gemini integration with Frame smart glasses, MobileBERT embeddings, and real-time audio streaming.';
      
      // Get conversation context from vector database
      String context = '';
      if (_vectorDb != null) {
        context = await _vectorDb!.getConversationContext(
          currentQuery: userQuery,
          maxResults: 3,
          threshold: 0.3,
        );
      }
      
      // Create enhanced prompt with context
      final enhancedPrompt = '''
$context

Current user message: $userQuery

Audio streaming status: ${_isAudioStreaming ? 'Active' : 'Inactive'}
Voice activity detected: ${_isVoiceDetected ? 'Yes' : 'No'}
Audio packets received: $_audioPacketsReceived

Please respond naturally, taking into account any relevant conversation history above and the current audio status.
''';
      
      final response = await _chatSession!.sendMessage(
        Content.text(enhancedPrompt)
      );
      
      final responseText = response.text;
      if (responseText != null && responseText.isNotEmpty) {
        _logEvent('🤖 Gemini: $responseText');
        
        // Store both user query and response in vector database
        if (_vectorDb != null) {
          try {
            // Store user query
            await _vectorDb!.addTextWithEmbedding(
              content: userQuery,
              metadata: {
                'type': 'user_message',
                'timestamp': DateTime.now().toIso8601String(),
                'source': 'user_input_audio',
                'session_id': 'audio_test_session',
                'has_audio': 'true',
              },
            );
            
            // Store assistant response
            await _vectorDb!.addTextWithEmbedding(
              content: responseText,
              metadata: {
                'type': 'assistant_response',
                'timestamp': DateTime.now().toIso8601String(),
                'source': 'gemini_response_audio',
                'session_id': 'audio_test_session',
                'audio_packets': _audioPacketsReceived.toString(),
              },
            );
            
            _logEvent('📚 Audio conversation stored in vector database');
          } catch (e) {
            _logEvent('⚠️ Failed to store conversation: $e');
          }
        }
      }
    } catch (e) {
      _logEvent('❌ Gemini audio conversation error: $e');
    }
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

  // NEW: Test Frame audio functionality
  Future<void> _testFrameAudio() async {
    if (_frameAudio == null) {
      _logEvent('❌ Frame audio service not initialized');
      return;
    }
    
    try {
      _logEvent('🧪 Testing Frame audio functionality...');
      
      final config = _frameAudio!.audioConfig;
      _logEvent('🎵 Audio config: ${config['sampleRate']}Hz, ${config['channels']}ch, ${config['bitDepth']}bit');
      _logEvent('📊 Streaming: ${config['isStreaming']}, Initialized: ${config['isInitialized']}');
      _logEvent('📈 Packets: ${config['packetsReceived']}, Bytes: ${config['bytesReceived']}');
      
      // Test VAD if available
      if (_vad != null) {
        _logEvent('🗣️ Voice Activity Detection ready');
        _vad!.reset();
        _logEvent('🔄 VAD state reset');
      }
      
    } catch (e) {
      _logEvent('❌ Frame audio test failed: $e');
    }
  }

  // Existing methods remain the same...
  Future<void> _testMobileBertModel() async {
    if (_vectorDb == null) {
      _logEvent('❌ MobileBERT vector database not initialized');
      return;
    }
    
    try {
      _logEvent('🧪 Testing MobileBERT model...');
      
      // Test the model directly
      await _vectorDb!.testModel();
      
      // Test embedding generation and storage
      await _vectorDb!.addTextWithEmbedding(
        content: 'This is a test of MobileBERT embedding generation with Frame audio integration',
        metadata: {
          'type': 'test',
          'timestamp': DateTime.now().toIso8601String(),
          'source': 'model_test_audio',
          'has_frame_audio': 'true',
        },
      );
      
      // Test similarity search
      final results = await _vectorDb!.queryText(
        queryText: 'MobileBERT Frame audio test',
        topK: 3,
        threshold: 0.2,
      );
      
      _logEvent('✅ MobileBERT test complete: ${results.length} similar results found');
      
      // Display results
      for (final result in results) {
        final score = ((result['score'] as double) * 100).round();
        final content = result['document']?.toString() ?? '';
        _logEvent('📄 Match $score%: ${content.substring(0, content.length.clamp(0, 50))}...');
      }
      
    } catch (e) {
      _logEvent('❌ MobileBERT test failed: $e');
    }
  }

  Future<void> _addSampleData() async {
    if (_vectorDb == null) {
      _logEvent('❌ Vector database not initialized');
      return;
    }
    
    try {
      _logEvent('📝 Adding sample data with MobileBERT embeddings...');
      await _vectorDb!.addSampleData();
      
      // Add audio-specific sample data
      const audioSamples = [
        'User spoke through Frame glasses microphone',
        'Voice activity detected in real-time audio stream',
        'Audio conversation with Gemini AI assistant',
        'Frame smart glasses audio integration working perfectly',
      ];
      
      for (int i = 0; i < audioSamples.length; i++) {
        final timestamp = DateTime.now().toIso8601String();
        await _vectorDb!.addTextWithEmbedding(
          content: audioSamples[i],
          metadata: {
            'type': 'audio_sample',
            'index': i.toString(),
            'timestamp': timestamp,
            'source': 'audio_sample_generator',
            'frame_audio': 'true',
          },
        );
        
        await Future.delayed(const Duration(milliseconds: 200));
      }
      
      // Get updated stats
      final stats = await _vectorDb!.getStats();
      _logEvent('📊 Database updated: ${stats['totalDocuments']} docs, model: ${stats['embeddingModel']}');
      
    } catch (e) {
      _logEvent('❌ Failed to add sample data: $e');
    }
  }

  Future<void> _getVectorDatabaseStats() async {
    if (_vectorDb == null) {
      _logEvent('❌ Vector database not initialized');
      return;
    }
    
    try {
      final stats = await _vectorDb!.getStats();
      
      _logEvent('📊 Vector DB Stats:');
      _logEvent('  • Total documents: ${stats['totalDocuments']}');
      _logEvent('  • With embeddings: ${stats['documentsWithEmbeddings']}');
      _logEvent('  • Embedding model: ${stats['embeddingModel']}');
      _logEvent('  • Avg dimensions: ${stats['averageEmbeddingDimensions']}');
      _logEvent('  • Vocabulary size: ${stats['vocabularySize']}');
      _logEvent('  • Max sequence length: ${stats['maxSequenceLength']}');
      
      if (stats['typeDistribution'] != null) {
        final types = stats['typeDistribution'] as Map<String, int>;
        _logEvent('  • Document types: ${types.entries.map((e) => '${e.key}:${e.value}').join(', ')}');
      }
      
    } catch (e) {
      _logEvent('❌ Failed to get stats: $e');
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
                    
                    // NEW: Audio Status Section
                    _buildAudioStatusSection(),
                    const SizedBox(height: 16),
                    
                    // Live Photo View (placeholder)
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

  // NEW: Audio status section
  Widget _buildAudioStatusSection() {
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
            
            // Audio packets counter
            Row(
              children: [
                const Icon(Icons.data_usage, color: Colors.orange),
                const SizedBox(width: 8),
                Text(
                  'Audio Packets: $_audioPacketsReceived',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Updated control buttons with audio controls
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
                    onPressed: (_connectedDevice != null && !_isSessionActive && _geminiApiKey.isNotEmpty) 
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
            
            // Audio specific controls
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_connectedDevice != null && !_isAudioStreaming) 
                        ? _startAudioStreaming 
                        : null,
                    icon: const Icon(Icons.mic),
                    label: const Text('Start Audio'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isAudioStreaming ? _stopAudioStreaming : null,
                    icon: const Icon(Icons.mic_off),
                    label: const Text('Stop Audio'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.withValues(alpha: 0.1),
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
                    onPressed: _testFrameAudio,
                    icon: const Icon(Icons.audiotrack),
                    label: const Text('Test Audio'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _testMobileBertModel,
                    icon: const Icon(Icons.psychology),
                    label: const Text('Test MobileBERT'),
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
                    onPressed: _addSampleData,
                    icon: const Icon(Icons.data_array),
                    label: const Text('Add Sample Data'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _getVectorDatabaseStats,
                    icon: const Icon(Icons.analytics),
                    label: const Text('DB Stats'),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Clear button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _vectorDb != null ? () => _vectorDb!.clearAll() : null,
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear Database'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.withValues(alpha: 0.1),
                ),
              ),
            ),
            
            // Status messages
            if (_isSessionActive)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(
                  '🎤 AI session active with Frame audio streaming',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.blue,
                  ),
                ),
              ),
            if (_connectedDevice == null)
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

  // Keep all existing widget methods unchanged...
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
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 16,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'API key configured',
                      style: TextStyle(color: Colors.green),
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
                if (_connectedDevice != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.bluetooth_connected, color: Colors.green, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          _connectedDevice!.platformName.isEmpty 
                              ? 'Connected' 
                              : _connectedDevice!.platformName,
                          style: const TextStyle(color: Colors.green),
                        ),
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
                    onPressed: _isScanning || (_connectedDevice != null) ? null : _startScanning,
                    icon: _isScanning 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(_isScanning ? 'Scanning...' : 'Scan for Frame'),
                  ),
                ),
                const SizedBox(width: 8),
                if (_connectedDevice != null)
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
            if (_availableDevices.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Available Devices:'),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _availableDevices.length,
                  itemBuilder: (context, index) {
                    final device = _availableDevices[index];
                    return ListTile(
                      leading: const Icon(Icons.smartphone),
                      title: Text(device.platformName.isEmpty ? 'Unknown Device' : device.platformName),
                      subtitle: Text(device.remoteId.str),
                      trailing: ElevatedButton(
                        onPressed: () => _connectToDevice(device),
                        child: const Text('Connect'),
                      ),
                    );
                  },
                ),
              ),
            ],
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
                        child: Text('Camera feed coming soon'),
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
}