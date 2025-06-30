import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frame_msg/rx/audio.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/rx/tap.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/code.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';

import 'audio_upsampler.dart';
import 'gemini_realtime.dart';
import 'services/vector_db_service.dart';
import 'foreground_service.dart';

// --- ObjectBox ---
import 'objectbox.g.dart';               // generated

late Store store;                        // global store handle
// --- End ObjectBox ---

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Needed for two-way comms with TaskHandler
  FlutterForegroundTask.initCommunicationPort();

  // --- ObjectBox initialization ---
  store = await openStore();

  // Configure the foreground-service plugin
  initializeForegroundService();

  // Quieten BLE logs
  fbp.FlutterBluePlus.setLogLevel(fbp.LogLevel.info);

  runApp(const MainApp());
}

final _log = Logger('MainApp');

class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin manages Frame connection lifecycle
class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // Realtime-voice app members
  late final GeminiRealtime _gemini;
  late final VectorDbService _vectorDbService;

  GeminiVoiceName _voiceName = GeminiVoiceName.Puck;

  // FlutterPCMSound / streaming state
  bool _playingAudio = false;
  bool _streaming = false;

  // Subscriptions & helpers
  StreamSubscription? _tapSubs;
  final RxAudio _rxAudio = RxAudio(streaming: true);
  StreamSubscription? _frameAudioSubs;
  Stream<Uint8List>? _frameAudioSampleStream;

  static const resolution = 720;
  static const qualityIndex = 4;
  static const qualityLevel = 'VERY_HIGH';

  final RxPhoto _rxPhoto = RxPhoto(quality: qualityLevel, resolution: resolution);
  StreamSubscription? _photoSubs;
  Stream<Uint8List>? _photoStream;

  static const int photoInterval = 3;
  Timer? _photoTimer;
  Image? _image;

  // UI
  final _apiKeyController = TextEditingController();
  final _systemInstructionController = TextEditingController();
  final List<String> _eventLog = [];
  final _eventLogController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 20);
  String? _errorMsg;

  MainAppState() {
    // Logging filters
    hierarchicalLoggingEnabled = true;
    Logger.root.level   = Level.FINE;
    Logger('Bluetooth').level = Level.FINE;

    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: '
                 '[${record.loggerName}] ${record.time}: ${record.message}');
    });

    _vectorDbService = VectorDbService(_appendEvent);
    _gemini          = GeminiRealtime(_audioReadyCallback, _appendEvent);
  }

  // ----------------- INIT / DISPOSE  ----------------
  @override
  void initState() {
    super.initState();
    _asyncInit();
  }

  Future<void> _asyncInit() async {
    await _loadPrefs();
    await _vectorDbService.initialize();

    // Audio playback (Gemini → 24 kHz mono pcm16)
    const sampleRate = 24000;
    FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    FlutterPcmSound.setFeedThreshold(sampleRate ~/ 30);
    FlutterPcmSound.setFeedCallback(_onFeed);

    // Kick off BLE scan & connect
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  Future<void> dispose() async {
    await _gemini.disconnect();
    await _frameAudioSubs?.cancel();
    await FlutterPcmSound.release();
    _photoTimer?.cancel();
    await _vectorDbService.dispose();
    super.dispose();
  }

  // -------------- SAVE / LOAD PREFS -------------
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text         = prefs.getString('api_key') ?? '';
      _systemInstructionController.text =
          prefs.getString('system_instruction') ?? _defaultSystemPrompt;
      _voiceName = GeminiVoiceName.values.firstWhere(
        (e) => e.name == (prefs.getString('voice_name') ?? 'Puck'),
        orElse: () => GeminiVoiceName.Puck,
      );
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString('system_instruction',
        _systemInstructionController.text);
    await prefs.setString('voice_name', _voiceName.name);
  }

  static const _defaultSystemPrompt =
      '''The stream of images is coming live from the user's smart glasses ...
(omitted here for brevity – unchanged from original)''';

  // ----------------- RUNTIME  ----------------
  // --( all existing run / cancel / streaming helpers unchanged )--
  //           …  keep your full original bodies here …

  // ----------------- UI / BUILD  ----------------
  @override
  Widget build(BuildContext context) {
    // Ensure FG-service is running while UI is up
    startForegroundService();

    return WithForegroundTask(
      child: MaterialApp(
        title: 'Frame Realtime Gemini Voice & Vision',
        theme: ThemeData.dark(),
        home: _buildHome(),
      ),
    );
  }

  /// Builds the main scaffold – exactly the same widgets as the original file,
  /// no functional changes.  (Copy your previous build tree verbatim here.)
  Widget _buildHome() { /* … existing widget tree … */ }

  // ----------------- INTERNAL HELPERS  ----------------
  void _appendEvent(String evt) {
    setState(() => _eventLog.add(evt));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_eventLogController.hasClients) {
        _eventLogController.animateTo(
          _eventLogController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // … keep the rest of the original helper methods unchanged …
}
