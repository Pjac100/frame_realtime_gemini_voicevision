import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Frame and App specific imports
import 'package:frame_realtime_gemini_voicevision/audio_upsampler.dart';
import 'package:frame_realtime_gemini_voicevision/gemini_realtime.dart';
import 'package:frame_realtime_gemini_voicevision/services/vector_db_service.dart';
import 'package:frame_msg/rx/audio.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/rx/tap.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/code.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'foreground_service.dart';
import 'model/document_entity.dart';

// ObjectBox
import 'objectbox.g.dart';

// New On-Device AI services
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:frame_realtime_gemini_voicevision/services/local_embedding_service.dart';

/// Provides access to the ObjectBox Store throughout the app.
late Store store;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  store = await openStore();
  initializeForegroundService();
  fbp.FlutterBluePlus.setLogLevel(fbp.LogLevel.info);
  runApp(const MainApp());
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // App Services
  late final GeminiRealtime _gemini;
  late final VectorDbService _vectorDbService;
  late final LocalEmbeddingService _localEmbeddingService;
  late final TextRecognizer _textRecognizer;

  // App State
  GeminiVoiceName _voiceName = GeminiVoiceName.Puck;
  bool _playingAudio = false;
  bool _streaming = false;

  // Frame-related
  StreamSubscription<int>? _tapSubs;
  final RxAudio _rxAudio = RxAudio(streaming: true);
  StreamSubscription<Uint8List>? _frameAudioSubs;
  Stream<Uint8List>? _frameAudioSampleStream;
  static const resolution = 720;
  static const qualityIndex = 4;
  static const qualityLevel = 'VERY_HIGH';
  final RxPhoto _rxPhoto =
      RxPhoto(quality: qualityLevel, resolution: resolution);
  StreamSubscription<Uint8List>? _photoSubs;
  Stream<Uint8List>? _photoStream;
  static const int photoInterval = 3;
  Timer? _photoTimer;

  // UI
  Image? _image;
  final _apiKeyController = TextEditingController();
  final _systemInstructionController = TextEditingController();
  final List<String> _eventLog = List.empty(growable: true);
  final _eventLogController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 20);
  String? _errorMsg;

  MainAppState() {
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.FINE;
    Logger('Bluetooth').level = Level.FINE;
    Logger('RxPhoto').level = Level.FINE;
    Logger('RxAudio').level = Level.FINE;
    Logger('RxTap').level = Level.FINE;

    Logger.root.onRecord.listen((record) {
      debugPrint(
        '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}',
      );
    });

    // Initialize all services
    _localEmbeddingService = LocalEmbeddingService();
    _vectorDbService = VectorDbService(_appendEvent);
    _gemini = GeminiRealtime(_audioReadyCallback, _appendEvent);
  }

  @override
  void initState() {
    super.initState();
    _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _asyncInit();
  }

  Future<void> _asyncInit() async {
    await _loadPrefs();

    // Initialize our new on-device services first
    await _localEmbeddingService.initialize();
    await _vectorDbService.initialize();

    const sampleRate = 24000;
    FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    FlutterPcmSound.setFeedThreshold(sampleRate ~/ 30);
    FlutterPcmSound.setFeedCallback(_onFeed);

    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  Future<void> dispose() async {
    await _gemini.disconnect();
    await _frameAudioSubs?.cancel();
    await FlutterPcmSound.release();
    _photoTimer?.cancel();

    // Close all our services
    _textRecognizer.close();
    _localEmbeddingService.close();
    await _vectorDbService.dispose();

    super.dispose();
  }

  void _handleFramePhoto(Uint8List jpegBytes) async {
    log('photo received from Frame, processing locally first.');

    // --- Local Image Processing & OCR ---
    try {
      img.Image? originalImage = img.decodeImage(jpegBytes);
      if (originalImage != null) {
        img.Image processedImage = img.contrast(originalImage, contrast: 150);
        processedImage = img.sharpen(processedImage, amount: 100);
        final processedJpegBytes =
            Uint8List.fromList(img.encodeJpg(processedImage));

        final inputImage = InputImage.fromBytes(
          bytes: processedJpegBytes,
          metadata: InputImageMetadata(
            size: Size(processedImage.width.toDouble(),
                processedImage.height.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.yuv420,
            bytesPerRow: 0,
          ),
        );

        final RecognizedText recognizedText =
            await _textRecognizer.processImage(inputImage);
        final String ocrText = recognizedText.text.trim();

        if (ocrText.isNotEmpty && _localEmbeddingService.isInitialized) {
          _appendEvent('OCR: "$ocrText"');

          // --- Use the new LocalEmbeddingService ---
          final embedding = await _localEmbeddingService.getEmbedding(ocrText);

          if (embedding != null) {
            final newDocument = Document(
              timestamp: DateTime.now(),
              textContent: ocrText,
              embedding: embedding,
            );
            _vectorDbService.addDocument(newDocument);
          }
        }
      }
    } catch (e) {
      log('Error during local image processing or OCR: $e');
    }

    // --- Deliver to remote AI and Update UI ---
    if (_gemini.isConnected()) {
      _gemini.sendPhoto(jpegBytes);
    }
    if (mounted) {
      setState(() {
        _image = Image.memory(jpegBytes, gaplessPlayback: true);
      });
    }
  }

  // --- No changes to any of the methods below this point ---

  void _onFeed(int remainingFrames) async {
    if (remainingFrames < 2000) {
      if (_gemini.hasResponseAudio()) {
        await FlutterPcmSound.feed(
          PcmArrayInt16(bytes: _gemini.getResponseAudioByteData()),
        );
      } else {
        _log.fine('Response audio ended');
        _playingAudio = false;
      }
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
      _systemInstructionController.text = prefs
              .getString('system_instruction') ??
          'The stream of images are coming live from the user\'s smart glasses, they are not a recorded video. For example, don\'t say "the person in the video", say "the person in front of you" if you are referring to someone you can see in the images. If an image is blurry, don\'t say the image is too blurry, wait for subsequent images that will arrive in the coming few seconds that might stabilize focus and be easier to process.\n\nAfter the user asks a question, never restate the question but instead directly answer it. No need to start responding when the images come in, wait for the user to start talking and only refer to the live images when relevant.\n\nTry not to repeat what the user is asking unless you\'re really unsure.';
      _voiceName = GeminiVoiceName.values.firstWhere(
        (e) =>
            e.toString().split('.').last ==
            (prefs.getString('voice_name') ?? 'Puck'),
        orElse: () => GeminiVoiceName.Puck,
      );
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString(
      'system_instruction',
      _systemInstructionController.text,
    );
    await prefs.setString('voice_name', _voiceName.name);
  }

  @override
  Future<void> run() async {
    _errorMsg = null;
    if (_apiKeyController.text.isEmpty) {
      setState(() {
        _errorMsg = 'Error: Set value for Gemini API Key';
      });
      return;
    }
    await _gemini.connect(
      _apiKeyController.text,
      _voiceName,
      _systemInstructionController.text,
    );
    if (!_gemini.isConnected()) {
      _log.severe('Connection to Gemini failed');
      return;
    }
    setState(() {
      currentState = ApplicationState.running;
    });
    try {
      _tapSubs?.cancel();
      _tapSubs = RxTap().attach(frame!.dataResponse).listen((taps) async {
        _log.info('taps: $taps');
        if (_gemini.isConnected()) {
          if (taps >= 2) {
            if (!_streaming) {
              await _startFrameStreaming();
              await frame!.sendMessage(
                0x0b,
                TxPlainText(text: '\u{F0010}').pack(),
              );
            } else {
              await _stopFrameStreaming();
              await frame!.sendMessage(
                0x0b,
                TxPlainText(text: 'Double-Tap to resume!').pack(),
              );
            }
          }
        } else {
          _appendEvent('Disconnected from Gemini');
          _stopFrameStreaming();
          setState(() {
            currentState = ApplicationState.ready;
          });
        }
      });
      await frame!.sendMessage(0x10, TxCode(value: 1).pack());
      await frame!.sendMessage(
        0x0b,
        TxPlainText(text: 'Double-Tap to begin!').pack(),
      );
    } catch (e) {
      _errorMsg = 'Error executing application logic: $e';
      _log.fine(_errorMsg);
      setState(() {
        currentState = ApplicationState.ready;
      });
    }
  }

  @override
  Future<void> cancel() async {
    setState(() {
      currentState = ApplicationState.canceling;
    });
    _tapSubs?.cancel();
    if (_streaming) _stopFrameStreaming();
    await frame!.sendMessage(0x30, TxCode(value: 0).pack());
    await frame!.sendMessage(0x10, TxCode(value: 0).pack());
    await frame!.sendMessage(0x0b, TxPlainText(text: ' ').pack());
    await _gemini.disconnect();
    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  Future<void> _startFrameStreaming() async {
    _appendEvent('Starting Frame Streaming');
    FlutterPcmSound.start();
    _streaming = true;
    try {
      _frameAudioSampleStream = _rxAudio.attach(frame!.dataResponse);
      _frameAudioSubs?.cancel();
      _frameAudioSubs = _frameAudioSampleStream!.listen(_handleFrameAudio);
      await frame!.sendMessage(0x30, TxCode(value: 1).pack());
      await _requestPhoto();
      _photoTimer = Timer.periodic(const Duration(seconds: photoInterval), (
        timer,
      ) async {
        _log.info('Timer Fired!');
        if (!_streaming) {
          timer.cancel();
          _photoTimer = null;
          _log.info('Streaming ended, stop requesting photos');
          return;
        }
        await _requestPhoto();
      });
    } catch (e) {
      _log.warning(() => 'Error executing application logic: $e');
    }
  }

  Future<void> _stopFrameStreaming() async {
    _streaming = false;
    _gemini.stopResponseAudio();
    _photoTimer?.cancel();
    _photoTimer = null;
    await frame!.sendMessage(0x30, TxCode(value: 0).pack());
    _rxAudio.detach();
    _appendEvent('Ending Frame Streaming');
  }

  Future<void> _requestPhoto() async {
    _log.info('requesting photo from Frame');
    _photoStream = _rxPhoto.attach(frame!.dataResponse);
    _photoSubs?.cancel();
    _photoSubs = _photoStream!.listen(_handleFramePhoto);
    await frame!.sendMessage(
      0x0d,
      TxCaptureSettings(
        resolution: resolution,
        qualityIndex: qualityIndex,
      ).pack(),
    );
  }

  void _handleFrameAudio(Uint8List pcm16x8) {
    if (_gemini.isConnected()) {
      var pcm16x16 = AudioUpsampler.upsample8kTo16k(pcm16x8);
      _gemini.sendAudio(pcm16x16);
    }
  }

  void _audioReadyCallback() {
    if (!_playingAudio) {
      _playingAudio = true;
      _onFeed(0);
      _log.fine('Response audio started');
    }
  }

  void _appendEvent(String evt) {
    if (mounted) {
      setState(() {
        _eventLog.add(evt);
      });
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
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

  @override
  Widget build(BuildContext context) {
    startForegroundService();
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Frame Realtime Gemini Voice and Vision',
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Frame Realtime Gemini Voice and Vision'),
            actions: [getBatteryWidget()],
          ),
          body: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _apiKeyController,
                          decoration: const InputDecoration(
                            hintText: 'Enter Gemini API Key',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      DropdownButton<GeminiVoiceName>(
                        value: _voiceName,
                        onChanged: (GeminiVoiceName? newValue) {
                          setState(() {
                            _voiceName = newValue!;
                          });
                        },
                        items: GeminiVoiceName.values
                            .map<DropdownMenuItem<GeminiVoiceName>>((
                          GeminiVoiceName value,
                        ) {
                          return DropdownMenuItem<GeminiVoiceName>(
                            value: value,
                            child: Text(value.toString().split('.').last),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _systemInstructionController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'System Instruction',
                    ),
                  ),
                  if (_errorMsg != null)
                    Text(
                      _errorMsg!,
                      style: const TextStyle(backgroundColor: Colors.red),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          _appendEvent('Testing addEmbedding...');
                          _vectorDbService.addEmbedding(
                              id: 'test1',
                              embedding: List.filled(384, 0.1),
                              metadata: {'source': 'manual_test'});
                        },
                        child: const Text('Test DB'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _savePrefs,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _image ?? Container(),
                        Expanded(
                          child: ListView.builder(
                            controller: _eventLogController,
                            itemCount: _eventLog.length,
                            itemBuilder: (context, index) {
                              return Text(_eventLog[index], style: _textStyle);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButton: Stack(
            children: [
              if (_eventLog.isNotEmpty)
                Positioned(
                  bottom: 90,
                  right: 20,
                  child: FloatingActionButton(
                    onPressed: () {
                      Share.share(_eventLog.join('\n'));
                    },
                    child: const Icon(Icons.share),
                  ),
                ),
              Positioned(
                bottom: 20,
                right: 20,
                child: getFloatingActionButtonWidget(
                      const Icon(Icons.mic),
                      const Icon(Icons.mic_off),
                    ) ??
                    Container(),
              ),
            ],
          ),
          persistentFooterButtons: getFooterButtonsWidget(),
        ),
      ),
    );
  }
}
