import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ── Frame packages (working combination) ───────────────────────────────────
import 'package:frame_msg/rx/audio.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';

// ── Your existing services ─────────────────────────────────────────────────
import 'gemini_realtime.dart';
import 'services/vector_db_service.dart';
import 'foreground_service.dart';
import 'objectbox.g.dart';
import 'audio_upsampler.dart';

// ────────────────────────────── init ────────────────────────────────────────
late Store store;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterForegroundTask.initCommunicationPort();
  store = await openStore();
  initializeForegroundService();

  runApp(const MainApp());
}

// ────────────────────────────── widget ──────────────────────────────────────
class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  State<MainApp> createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // ── services (your existing) ───────────────────────────────────────────
  late final VectorDbService _vectorDb;
  late final GeminiRealtime   _gemini;

  // ── Frame receivers (your existing) ─────────────────────────────────────
  final RxAudio _rxAudio = RxAudio(streaming: true);
  final RxPhoto _rxPhoto = RxPhoto(quality: 'VERY_HIGH', resolution: 720);

  // ── UI state (your existing) ────────────────────────────────────────────
  final _apiKeyCtrl = TextEditingController();
  final _systemCtrl = TextEditingController();
  final _events     = <String>[];
  final _scroll     = ScrollController();

  // ── Enhanced connection state ───────────────────────────────────────────
  bool _geminiConnected = false;
  bool _isStartingSession = false;
  bool _audioStreaming = false;

  // ───────────────────── lifecycle ────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadPrefs();
    await _requestBluetoothPermissions();
    await _checkBluetoothState();

    _vectorDb = VectorDbService(_log)..initialize();
    _gemini   = GeminiRealtime(_audioReady, _log);

    await _configurePcm();
    await startForegroundService();

    // Set up Frame audio streaming
    _setupFrameAudioHandling();

    _log('🔵 Frame app ready - scan for Frame device to connect');
  }

  @override
  Future<void> dispose() async {
    await _stopFrameStreaming();
    _gemini.disconnect();
    await FlutterPcmSound.release();
    await _vectorDb.dispose();
    store.close();
    super.dispose();
  }

  // ────────────────── Frame Audio Handling ───────────────────────────────
  void _setupFrameAudioHandling() {
    // Handle incoming audio from Frame
    _rxAudio.stream.listen((audioData) async {
      if (_geminiConnected && audioData.isNotEmpty) {
        try {
          // Upsample Frame audio (8kHz) to Gemini format (16kHz)
          final upsampled = AudioUpsampler.upsample8kTo16k(audioData);
          _gemini.sendAudio(upsampled);
          _log('🎤 Audio sent to Gemini (${upsampled.length} bytes)');
        } catch (e) {
          _log('❌ Audio processing error: $e');
        }
      }
    });

    // Handle incoming photos from Frame  
    _rxPhoto.stream.listen((photoData) async {
      if (_geminiConnected && photoData.isNotEmpty) {
        try {
          _gemini.sendPhoto(photoData);
          _log('📷 Photo sent to Gemini (${photoData.length} bytes)');
        } catch (e) {
          _log('❌ Photo processing error: $e');
        }
      }
    });
  }

  // ────────────────── SimpleFrameApp hooks ───────────────────────────────
  @override
  Future<void> run() async {
    await _startFrameStreaming();
  }

  @override
  Future<void> cancel() async {
    await _stopFrameStreaming();
  }

  // ────────────────── Frame Streaming Control ────────────────────────────
  Future<void> _startFrameStreaming() async {
    if (frame == null || !frame!.isConnected) {
      _log('❌ No Frame connected');
      return;
    }

    try {
      _log('🎤 Starting Frame audio streaming...');
      
      // Send audio subscription message (0x30 = AUDIO_SUBS_MSG, '1' = enable)
      await frame!.sendMessage(TxPlainText(msgCode: 0x30, text: '1'));
      
      setState(() => _audioStreaming = true);
      _log('✅ Frame audio streaming started');
      
      // Optional: Send display message to Frame
      await frame!.sendMessage(TxPlainText(
        msgCode: 0x0b, 
        text: 'Listening...\nSpeak to AI assistant'
      ));
      
    } catch (e) {
      _log('❌ Error starting Frame streaming: $e');
    }
  }

  Future<void> _stopFrameStreaming() async {
    if (frame == null || !frame!.isConnected) return;

    try {
      _log('⏹️ Stopping Frame audio streaming...');
      
      // Send audio subscription message (0x30 = AUDIO_SUBS_MSG, '0' = disable)
      await frame!.sendMessage(TxPlainText(msgCode: 0x30, text: '0'));
      
      setState(() => _audioStreaming = false);
      _log('✅ Frame audio streaming stopped');
      
      // Update Frame display
      await frame!.sendMessage(TxPlainText(
        msgCode: 0x0b, 
        text: 'Frame Ready\nSession stopped'
      ));
      
    } catch (e) {
      _log('❌ Error stopping Frame streaming: $e');
    }
  }

  // ────────────────── Enhanced Bluetooth Setup ───────────────────────────
  Future<void> _requestBluetoothPermissions() async {
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.location,
      Permission.locationWhenInUse,
    ];

    Map<Permission, PermissionStatus> statuses = await permissions.request();
    
    for (var permission in permissions) {
      final status = statuses[permission];
      _log('🔐 Permission $permission: $status');
      
      if (status == PermissionStatus.permanentlyDenied) {
        _log('⚠️ $permission permanently denied - please enable in settings');
      }
    }
  }

  Future<void> _checkBluetoothState() async {
    try {
      final isAvailable = await FlutterBluePlus.isAvailable;
      final isOn = await FlutterBluePlus.isOn;
      
      _log('📶 Bluetooth available: $isAvailable, enabled: $isOn');
      
      if (!isAvailable) {
        _log('❌ Bluetooth not available on this device');
        return;
      }
      
      if (!isOn) {
        _log('⚠️ Bluetooth is disabled - please enable it');
        try {
          await FlutterBluePlus.turnOn();
        } catch (e) {
          _log('❌ Cannot auto-enable Bluetooth: $e');
        }
      }

      // Monitor Bluetooth state changes
      FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
        _log('📶 Bluetooth state changed: $state');
        if (mounted) setState(() {});
      });
    } catch (e) {
      _log('❌ Error checking Bluetooth state: $e');
    }
  }

  // ────────────────── Frame Connection Events ────────────────────────────
  @override
  void onConnectionChange() {
    super.onConnectionChange();
    
    if (frame?.isConnected == true) {
      _log('✅ Frame connected: ${frame!.name}');
      setState(() {}); // Refresh UI
    } else {
      _log('❌ Frame disconnected');
      setState(() => _audioStreaming = false);
      
      // Stop Gemini session if Frame disconnects
      if (_geminiConnected) {
        _stopGeminiSession();
      }
    }
  }

  // ────────────────── Audio PCM Setup ────────────────────────────────────
  Future<void> _configurePcm() async {
    const sr = 24000; // Gemini Live expects 24kHz
    await FlutterPcmSound.setup(sampleRate: sr, channelCount: 1);
    FlutterPcmSound.setFeedThreshold(sr ~/ 30);
    FlutterPcmSound.setFeedCallback(_onFeed);
    FlutterPcmSound.start();
  }

  void _audioReady() => _onFeed(0);

  Future<void> _onFeed(int _) async {
    while (_gemini.hasResponseAudio()) {
      final bytes = _gemini.getResponseAudioByteData();
      if (bytes.lengthInBytes == 0) break;

      final samples = bytes.buffer.asInt16List();
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
    }
  }

  // ────────────────── Gemini Session Management ──────────────────────────
  bool get _canStartGemini => frame != null && 
                             frame!.isConnected && 
                             _apiKeyCtrl.text.isNotEmpty && 
                             !_geminiConnected &&
                             !_isStartingSession;

  Future<void> _startGeminiSession() async {
    if (!_canStartGemini) return;
    
    setState(() => _isStartingSession = true);
    
    try {
      _log('🤖 Starting Gemini session...');
      
      final success = await _gemini.connect(
        _apiKeyCtrl.text.trim(),
        GeminiVoiceName.Puck,
        _systemCtrl.text.trim().isEmpty 
          ? 'You are a helpful AI assistant integrated with Frame smart glasses. The user can speak to you through the Frame microphone and send photos from the Frame camera. Respond naturally and concisely.'
          : _systemCtrl.text.trim(),
      );
      
      if (success) {
        setState(() => _geminiConnected = true);
        _log('✅ Gemini session started successfully');
        
        // Save preferences
        await _savePrefs();
        
        // Start Frame streaming
        await run();
        
        // Update Frame display
        await frame!.sendMessage(TxPlainText(
          msgCode: 0x0b, 
          text: 'Gemini Connected!\nVoice & Vision Ready'
        ));
      } else {
        _log('❌ Failed to start Gemini session');
      }
    } catch (e) {
      _log('❌ Error starting Gemini session: $e');
    } finally {
      setState(() => _isStartingSession = false);
    }
  }

  Future<void> _stopGeminiSession() async {
    try {
      _log('🛑 Stopping Gemini session...');
      await cancel(); // Stop Frame streaming first
      await _gemini.disconnect();
      setState(() => _geminiConnected = false);
      _log('✅ Gemini session stopped');
    } catch (e) {
      _log('❌ Error stopping Gemini session: $e');
    }
  }

  // ────────────────── Preferences ────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyCtrl.text = p.getString('api_key') ?? '';
      _systemCtrl.text = p.getString('system_instruction') ?? 
        'You are a helpful AI assistant integrated with Frame smart glasses. The user can speak to you through the Frame microphone and send photos from the Frame camera. Respond naturally and concisely.';
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('api_key', _apiKeyCtrl.text.trim());
    await p.setString('system_instruction', _systemCtrl.text.trim());
  }

  // ────────────────── Logging ─────────────────────────────────────────────
  void _log(String msg) {
    if (mounted) {
      setState(() => _events.add(msg));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    print('[Frame] $msg');
  }

  // ────────────────── UI Build ────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Frame Realtime Assistant'),
            backgroundColor: _geminiConnected ? Colors.green.shade800 : null,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ═══════════════════════════════════════════════════════════
              // FRAME CONNECTION INTERFACE (This was missing!)
              // ═══════════════════════════════════════════════════════════
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.smart_display, color: Colors.blue),
                          const SizedBox(width: 8),
                          Text(
                            'Frame Connection',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      
                      // Connection status indicators
                      _buildStatusIndicator('Bluetooth Available', 
                        frame != null || !isScanning),
                      _buildStatusIndicator('Frame Connected', 
                        frame?.isConnected == true),
                      _buildStatusIndicator('Audio Streaming', _audioStreaming),
                      _buildStatusIndicator('Gemini Session', _geminiConnected),
                      
                      const SizedBox(height: 16),
                      
                      // Frame device info
                      if (frame != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: frame!.isConnected ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: frame!.isConnected ? Colors.green : Colors.orange,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Device: ${frame!.name}', 
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text('ID: ${frame!.id}', 
                                style: const TextStyle(fontSize: 12)),
                              Text('Status: ${frame!.isConnected ? "Connected" : "Disconnected"}',
                                style: TextStyle(
                                  color: frame!.isConnected ? Colors.green : Colors.orange,
                                )),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      
                      // Connection controls
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // Scan button
                          if (!isScanning && (frame == null || !frame!.isConnected))
                            ElevatedButton.icon(
                              onPressed: () {
                                _log('🔍 Scanning for Frame devices...');
                                scan();
                              },
                              icon: const Icon(Icons.bluetooth_searching),
                              label: const Text('Scan for Frame'),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                            ),
                          
                          // Scanning indicator
                          if (isScanning)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(width: 16, height: 16, 
                                    child: CircularProgressIndicator(strokeWidth: 2)),
                                  SizedBox(width: 8),
                                  Text('Scanning for Frame...'),
                                ],
                              ),
                            ),
                          
                          // Disconnect button
                          if (frame?.isConnected == true)
                            ElevatedButton.icon(
                              onPressed: () {
                                _log('🔌 Disconnecting from Frame...');
                                disconnect();
                              },
                              icon: const Icon(Icons.bluetooth_disabled),
                              label: const Text('Disconnect'),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                            ),

                          // Test message button
                          if (frame?.isConnected == true)
                            ElevatedButton.icon(
                              onPressed: () async {
                                try {
                                  final message = 'Test ${DateTime.now().millisecondsSinceEpoch % 1000}';
                                  await frame!.sendMessage(TxPlainText(
                                    msgCode: 0x0b, 
                                    text: 'Hello Frame!\n$message'
                                  ));
                                  _log('📨 Test message sent: $message');
                                } catch (e) {
                                  _log('❌ Test message failed: $e');
                                }
                              },
                              icon: const Icon(Icons.message),
                              label: const Text('Test Display'),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
                            ),
                        ],
                      ),
                      
                      // Available devices list
                      if (availableDevices.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text('Available Frame devices:', 
                          style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ...availableDevices.map((device) => Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: const Icon(Icons.smart_display, color: Colors.blue),
                            title: Text(device.name),
                            subtitle: Text('${device.id} • Ready to connect'),
                            trailing: ElevatedButton(
                              onPressed: () {
                                _log('🔗 Connecting to ${device.name}...');
                                connectToDevice(device);
                              },
                              child: const Text('Connect'),
                            ),
                            dense: true,
                          ),
                        )),
                      ],
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // ═══════════════════════════════════════════════════════════
              // GEMINI CONFIGURATION
              // ═══════════════════════════════════════════════════════════
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.psychology, color: Colors.purple),
                          const SizedBox(width: 8),
                          Text(
                            'Gemini Configuration',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _apiKeyCtrl,
                        decoration: InputDecoration(
                          labelText: 'Gemini API Key',
                          hintText: 'Enter your Google AI API key',
                          prefixIcon: const Icon(Icons.key),
                          border: const OutlineInputBorder(),
                          suffixIcon: _apiKeyCtrl.text.isNotEmpty 
                            ? const Icon(Icons.check, color: Colors.green)
                            : const Icon(Icons.error, color: Colors.red),
                        ),
                        obscureText: true,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _systemCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'System Instruction',
                          hintText: 'Define AI behavior for Frame assistant',
                          prefixIcon: Icon(Icons.psychology),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // ═══════════════════════════════════════════════════════════
              // SESSION CONTROLS
              // ═══════════════════════════════════════════════════════════
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.smart_toy, color: Colors.green),
                          const SizedBox(width: 8),
                          Text(
                            'AI Session Controls',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      
                      // Session status
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _geminiConnected ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _geminiConnected ? Colors.green : Colors.grey,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _geminiConnected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                              color: _geminiConnected ? Colors.green : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _geminiConnected ? 'Gemini Session Active' : 'Gemini Session Inactive',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _geminiConnected ? Colors.green : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 16),
                      
                      // Control buttons
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _canStartGemini ? _startGeminiSession : null,
                              icon: _isStartingSession 
                                ? const SizedBox(
                                    width: 16, 
                                    height: 16, 
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.play_arrow),
                              label: Text(_isStartingSession ? 'Starting...' : 'Start AI Session'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _geminiConnected ? _stopGeminiSession : null,
                              icon: const Icon(Icons.stop),
                              label: const Text('Stop Session'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                      
                      if (!_canStartGemini && !_geminiConnected) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Requirements: Frame connected + API key entered',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // ═══════════════════════════════════════════════════════════
              // EVENTS LOG
              // ═══════════════════════════════════════════════════════════
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.terminal, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(
                            'System Events',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => setState(() => _events.clear()),
                            icon: const Icon(Icons.clear, size: 16),
                            label: const Text('Clear'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey),
                        ),
                        child: _events.isEmpty
                          ? const Center(
                              child: Text(
                                'Ready for Frame connection...',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : Scrollbar(
                              controller: _scroll,
                              child: ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(8),
                                itemCount: _events.length,
                                itemBuilder: (_, i) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 1),
                                  child: Text(
                                    '${DateTime.now().toLocal().toString().substring(11, 19)}: ${_events[i]}',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: Colors.greenAccent,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_events.length} events logged',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ────────────────── Helper Widgets ─────────────────────────────────────
  Widget _buildStatusIndicator(String label, bool status) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            status ? Icons.check_circle : Icons.radio_button_unchecked,
            color: status ? Colors.green : Colors.grey,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(
            status ? 'Ready' : 'Waiting',
            style: TextStyle(
              color: status ? Colors.green : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}