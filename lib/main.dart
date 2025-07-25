import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path_provider/path_provider.dart';

// ObjectBox imports
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';
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
  
  // Event logging
  final List<String> _eventLog = [];
  final ScrollController _scrollController = ScrollController();
  
  // Vector database with MobileBERT
  VectorDbService? _vectorDb;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _loadGeminiApiKey();
    _requestPermissions();
    _logEvent('🚀 App initialized with MobileBERT embeddings');
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _connectedDevice?.disconnect();
    _vectorDb?.dispose();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize vector database with MobileBERT
      _vectorDb = VectorDbService(_logEvent);
      await _vectorDb!.initialize(store);
      
      _logEvent('🔧 Services initialized with MobileBERT');
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
          'You can see what the user sees through their camera and hear their voice. '
          'Provide natural, conversational responses. Keep responses concise but helpful. '
          'You have access to conversation history through local vector search for context.'
        ),
      );

      _chatSession = _model!.startChat();
      _logEvent('🤖 Gemini conversation model initialized');
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
      _logEvent('🎉 Ready for AI sessions!');
      
    } catch (e) {
      _logEvent('❌ Connection failed: $e');
      setState(() {
        _connectedDevice = null;
      });
    }
  }

  Future<void> _disconnect() async {
    try {
      if (_connectedDevice != null) {
        _stopSession();
        await _connectedDevice!.disconnect();
        
        setState(() {
          _connectedDevice = null;
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

    _logEvent('🎤 AI session started with MobileBERT embeddings');
    
    // Simulate AI conversation with vector context
    _simulateContextAwareConversation();
  }

  void _stopSession() {
    if (!_isSessionActive) return;

    setState(() {
      _isSessionActive = false;
    });

    _logEvent('⏹️ AI session stopped');
  }

  Future<void> _simulateContextAwareConversation() async {
    if (!_isSessionActive || _chatSession == null) return;
    
    try {
      final userQuery = 'Hello! I am testing the Gemini integration with Frame smart glasses and MobileBERT embeddings.';
      
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

Please respond naturally, taking into account any relevant conversation history above.
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
                'source': 'user_input',
                'session_id': 'test_session',
              },
            );
            
            // Store assistant response
            await _vectorDb!.addTextWithEmbedding(
              content: responseText,
              metadata: {
                'type': 'assistant_response',
                'timestamp': DateTime.now().toIso8601String(),
                'source': 'gemini_response',
                'session_id': 'test_session',
              },
            );
            
            _logEvent('📚 Conversation stored in vector database');
          } catch (e) {
            _logEvent('⚠️ Failed to store conversation: $e');
          }
        }
      }
    } catch (e) {
      _logEvent('❌ Gemini conversation error: $e');
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
        content: 'This is a test of MobileBERT embedding generation on device',
        metadata: {
          'type': 'test',
          'timestamp': DateTime.now().toIso8601String(),
          'source': 'model_test',
        },
      );
      
      // Test similarity search
      final results = await _vectorDb!.queryText(
        queryText: 'MobileBERT embedding test',
        topK: 3,
        threshold: 0.2,
      );
      
      _logEvent('✅ MobileBERT test complete: ${results.length} similar results found');
      
      // Display results
      for (final result in results) {
        final score = ((result['score'] as double) * 100).round();
        final content = result['document']?.toString() ?? '';
        _logEvent('📄 Match ${score}%: ${content.substring(0, content.length.clamp(0, 50))}...');
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
              // Constrain device list height to prevent overflow
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
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _testMobileBertModel,
                    icon: const Icon(Icons.psychology),
                    label: const Text('Test MobileBERT'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _addSampleData,
                    icon: const Icon(Icons.data_array),
                    label: const Text('Add Sample Data'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _getVectorDatabaseStats,
                    icon: const Icon(Icons.analytics),
                    label: const Text('DB Stats'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _vectorDb != null ? () => _vectorDb!.clearAll() : null,
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear DB'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              ],
            ),
            if (_isSessionActive)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(
                  '🎤 AI session active with MobileBERT context',
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