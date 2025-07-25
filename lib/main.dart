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
import 'package:objectbox/objectbox.dart';
import 'model/document_entity.dart';
import 'services/vector_db_service.dart';
import 'objectbox.g.dart';

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
  
  // Vector database
  VectorDbService? _vectorDb;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _loadGeminiApiKey();
    _requestPermissions();
    _logEvent('🚀 App initialized');
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _connectedDevice?.disconnect();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize vector database
      _vectorDb = VectorDbService(_logEvent);
      await _vectorDb!.initialize(store);
      
      _logEvent('🔧 Services initialized');
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
          'You have access to conversation history through vector search for context.'
        ),
      );

      _chatSession = _model!.startChat();
      _logEvent('🤖 Gemini models initialized');
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

    _logEvent('🎤 AI session started');
    
    // Simulate AI conversation for testing
    _simulateAiInteraction();
  }

  void _stopSession() {
    if (!_isSessionActive) return;

    setState(() {
      _isSessionActive = false;
    });

    _logEvent('⏹️ AI session stopped');
  }

  Future<void> _simulateAiInteraction() async {
    if (!_isSessionActive || _chatSession == null) return;
    
    try {
      // Simulate a conversation with Gemini
      final response = await _chatSession!.sendMessage(
        Content.text('Hello! I am testing the Gemini integration with Frame smart glasses. Please respond with a brief, friendly message.')
      );
      
      final responseText = response.text;
      if (responseText != null && responseText.isNotEmpty) {
        _logEvent('🤖 Gemini: $responseText');
        
        // Store conversation in vector database
        if (_vectorDb != null) {
          try {
            await _vectorDb!.addEmbedding(
              id: 'conversation_${DateTime.now().millisecondsSinceEpoch}',
              embedding: await _generateEmbedding(responseText),
              metadata: {
                'content': responseText,
                'type': 'conversation',
                'timestamp': DateTime.now().toIso8601String(),
                'source': 'gemini_response',
              },
            );
          } catch (e) {
            _logEvent('⚠️ Failed to store conversation in vector DB: $e');
          }
        }
        
        _logEvent('📱 Response stored in conversation memory');
      }
    } catch (e) {
      _logEvent('❌ Gemini conversation error: $e');
    }
  }

  Future<List<double>> _generateEmbedding(String text) async {
    // Placeholder for actual embedding generation
    // In a real implementation, you would use a proper embedding model
    return List.generate(384, (index) => (text.hashCode + index) / 1000000.0);
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

  Future<void> _testVectorDatabase() async {
    if (_vectorDb == null) {
      _logEvent('❌ Vector database not initialized');
      return;
    }
    
    try {
      _logEvent('🔍 Testing vector database...');
      
      // Test embedding storage
      await _vectorDb!.addEmbedding(
        id: 'test_${DateTime.now().millisecondsSinceEpoch}',
        embedding: List.generate(384, (i) => i / 100.0),
        metadata: {
          'content': 'Test vector database functionality',
          'type': 'test',
          'timestamp': DateTime.now().toIso8601String(),
          'source': 'test_function',
        },
      );
      
      // Test similarity search
      final results = await _vectorDb!.querySimilarEmbeddings(
        queryEmbedding: List.generate(384, (i) => i / 100.0),
        topK: 5,
      );
      
      // Get database stats
      final stats = await _vectorDb!.getStats();
      _logEvent('📊 DB Stats: ${stats['totalDocuments']} docs, types: ${stats['typeDistribution']}');
      
      _logEvent('✅ Vector DB test complete: ${results.length} results');
    } catch (e) {
      _logEvent('❌ Vector DB test failed: $e');
    }
  }

  Future<void> _testGeminiConversation() async {
    if (_chatSession == null) {
      _logEvent('❌ Gemini not initialized');
      return;
    }
    
    try {
      _logEvent('🤖 Testing Gemini conversation...');
      
      final response = await _chatSession!.sendMessage(
        Content.text('This is a test message. Please respond with something creative and brief.')
      );
      
      final responseText = response.text;
      if (responseText != null && responseText.isNotEmpty) {
        _logEvent('🤖 Gemini test response: $responseText');
        
        // Store in vector database
        if (_vectorDb != null) {
          await _vectorDb!.addEmbedding(
            id: 'test_conversation_${DateTime.now().millisecondsSinceEpoch}',
            embedding: await _generateEmbedding(responseText),
            metadata: {
              'content': responseText,
              'type': 'test_conversation',
              'timestamp': DateTime.now().toIso8601String(),
              'source': 'gemini_test',
            },
          );
        }
        
        _logEvent('✅ Gemini conversation test complete');
      }
    } catch (e) {
      _logEvent('❌ Gemini conversation test failed: $e');
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
                maxHeight: 250, // Limit photo height to prevent overflow
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
                          fit: BoxFit.contain, // Changed from cover to contain
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
                    onPressed: _testVectorDatabase,
                    icon: const Icon(Icons.storage),
                    label: const Text('Test Vector DB'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _geminiApiKey.isNotEmpty ? _testGeminiConversation : null,
                    icon: const Icon(Icons.chat),
                    label: const Text('Test Gemini'),
                  ),
                ),
              ],
            ),
            if (_isSessionActive)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(
                  '🎤 AI session active - testing Gemini integration',
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