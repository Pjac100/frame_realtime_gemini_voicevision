import 'dart:async';
import 'dart:typed_data';
import 'stream_observer.dart';
import 'timestamp_manager.dart';
import '../services/asr_service.dart';
import '../services/ocr_service.dart';
import '../services/local_llm_service.dart';
import '../services/agent_vector_service.dart';
import '../models/agent_output.dart';

/// Main coordination class for the agent system
/// Manages read-only stream processing, ASR/OCR, and LLM integration
class AgentCore {
  final StreamObserverManager _streamObserver;
  final TimestampManager _timestampManager;
  final ASRService _asrService;
  final OCRService _ocrService;
  final LocalLLMService _llmService;
  final AgentVectorService _vectorService;
  final void Function(String) _logger;
  
  // Agent state
  bool _isEnabled = false;
  bool _isProcessing = false;
  
  // Output tracking
  final List<AgentOutput> _outputs = [];
  final List<TimestampedData<Uint8List>> _recentImages = [];
  static const int _maxRecentImages = 50;
  
  // Statistics
  int _totalAsrOutputs = 0;
  int _totalOcrOutputs = 0;
  int _totalLLMCalls = 0;
  DateTime? _sessionStartTime;
  
  // Stream subscriptions
  StreamSubscription<TimestampedData<Uint8List>>? _audioSubscription;
  StreamSubscription<TimestampedData<Uint8List>>? _photoSubscription;

  AgentCore({
    required void Function(String) logger,
    required AgentVectorService vectorService,
  })  : _logger = logger,
        _streamObserver = StreamObserverManager(logger: logger),
        _timestampManager = TimestampManager(logger: logger),
        _asrService = ASRService(logger: logger),
        _ocrService = OCRService(logger: logger),
        _llmService = LocalLLMService(logger: logger),
        _vectorService = vectorService;

  /// Initialize the agent system (does not start processing)
  Future<bool> initialize() async {
    try {
      _logger('🤖 Initializing agent core...');
      
      // Initialize individual services
      final asrReady = await _asrService.initialize();
      final ocrReady = await _ocrService.initialize();
      final llmReady = await _llmService.initialize();
      final vectorReady = await _vectorService.initialize();
      
      if (!asrReady) _logger('⚠️ ASR service initialization failed');
      if (!ocrReady) _logger('⚠️ OCR service initialization failed');
      if (!llmReady) _logger('⚠️ LLM service initialization failed');
      if (!vectorReady) _logger('⚠️ Vector service initialization failed');
      
      // Agent can work with partial failures (graceful degradation)
      final readyServices = [asrReady, ocrReady, llmReady, vectorReady].where((ready) => ready).length;
      _logger('✅ Agent core initialized with $readyServices/4 services ready');
      
      return true;
    } catch (e) {
      _logger('❌ Agent initialization failed: $e');
      return false;
    }
  }

  /// Enable agent processing on the provided streams
  /// This is non-blocking and will not affect the original streams
  Future<void> enable({
    required Stream<Uint8List> audioStream,
    required Stream<Uint8List> photoStream,
  }) async {
    if (_isEnabled) {
      _logger('⚠️ Agent already enabled');
      return;
    }

    try {
      _logger('🚀 Enabling agent processing...');
      _sessionStartTime = DateTime.now();
      
      // Start observing streams (non-blocking)
      _streamObserver.startObserving(
        audioStream: audioStream,
        photoStream: photoStream,
      );
      
      // Set up processing pipelines
      _setupAudioProcessing();
      _setupPhotoProcessing();
      
      _isEnabled = true;
      _logger('✅ Agent processing enabled');
    } catch (e) {
      _logger('❌ Failed to enable agent: $e');
      rethrow;
    }
  }

  /// Setup audio stream processing pipeline
  void _setupAudioProcessing() {
    _audioSubscription = _streamObserver.audioObserver.observedStream.listen(
      (timestampedAudio) => _processAudio(timestampedAudio),
      onError: (error) => _logger('❌ Audio processing error: $error'),
    );
  }

  /// Setup photo stream processing pipeline
  void _setupPhotoProcessing() {
    _photoSubscription = _streamObserver.photoObserver.observedStream.listen(
      (timestampedPhoto) => _processPhoto(timestampedPhoto),
      onError: (error) => _logger('❌ Photo processing error: $error'),
    );
  }

  /// Process audio data through ASR pipeline
  Future<void> _processAudio(TimestampedData<Uint8List> timestampedAudio) async {
    if (!_isEnabled || _isProcessing) return;
    
    try {
      // Run ASR on the audio data (non-blocking)
      final asrResult = await _asrService.transcribeAudio(timestampedAudio.data);
      
      if (asrResult != null && asrResult.text.trim().isNotEmpty) {
        _totalAsrOutputs++;
        
        // Find correlated images
        final correlatedImages = _timestampManager.correlateWithPhotos(
          outputTimestamp: timestampedAudio.timestamp,
          availablePhotos: _recentImages,
        );
        
        // Create agent output
        final output = AgentOutput(
          id: 'asr_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: timestampedAudio.timestamp,
          type: AgentOutputType.asr,
          content: asrResult.text,
          confidence: asrResult.confidence,
          associatedImageTimestamps: correlatedImages.map((img) => img.timestamp).toList(),
          metadata: {
            'audioLength': timestampedAudio.data.length,
            'processingTime': DateTime.now().difference(timestampedAudio.timestamp).inMilliseconds,
          },
        );
        
        _outputs.add(output);
        _logger('🗣️ ASR: "${asrResult.text}" (${correlatedImages.length} images)');
        
        // Process with LLM if available
        _processWithLLM(output, correlatedImages);
      }
    } catch (e) {
      _logger('❌ Audio processing error: $e');
    }
  }

  /// Process photo data through OCR pipeline
  Future<void> _processPhoto(TimestampedData<Uint8List> timestampedPhoto) async {
    if (!_isEnabled) return;
    
    // Store image for temporal correlation
    _recentImages.add(timestampedPhoto);
    if (_recentImages.length > _maxRecentImages) {
      _recentImages.removeAt(0);
    }
    
    try {
      // Run OCR on the image data (non-blocking)
      final ocrResult = await _ocrService.extractText(timestampedPhoto.data);
      
      if (ocrResult != null && ocrResult.text.trim().isNotEmpty) {
        _totalOcrOutputs++;
        
        // Create agent output
        final output = AgentOutput(
          id: 'ocr_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: timestampedPhoto.timestamp,
          type: AgentOutputType.ocr,
          content: ocrResult.text,
          confidence: ocrResult.confidence,
          associatedImageTimestamps: [timestampedPhoto.timestamp],
          metadata: {
            'imageSize': timestampedPhoto.data.length,
            'processingTime': DateTime.now().difference(timestampedPhoto.timestamp).inMilliseconds,
          },
        );
        
        _outputs.add(output);
        _logger('👁️ OCR: "${ocrResult.text}"');
        
        // Process with LLM if available
        _processWithLLM(output, [timestampedPhoto]);
      }
    } catch (e) {
      _logger('❌ Photo OCR processing error: $e');
    }
  }

  /// Process agent output through local LLM with tool calling
  Future<void> _processWithLLM(
    AgentOutput output, 
    List<TimestampedData<Uint8List>> correlatedImages,
  ) async {
    if (!_llmService.isReady) return;
    
    try {
      _isProcessing = true;
      _totalLLMCalls++;
      
      // Prepare context for LLM
      final context = _buildLLMContext(output, correlatedImages);
      
      // Get LLM response with tool calls
      final llmResponse = await _llmService.processWithTools(
        context: context,
        availableTools: _getAvailableTools(),
      );
      
      if (llmResponse != null) {
        // Execute any tool calls
        for (final toolCall in llmResponse.toolCalls) {
          await _executeTool(toolCall, output);
        }
        
        // Store LLM response if significant
        if (llmResponse.content.trim().isNotEmpty) {
          final llmOutput = AgentOutput(
            id: 'llm_${DateTime.now().millisecondsSinceEpoch}',
            timestamp: DateTime.now(),
            type: AgentOutputType.llm,
            content: llmResponse.content,
            confidence: 1.0, // LLM responses are considered reliable
            associatedImageTimestamps: correlatedImages.map((img) => img.timestamp).toList(),
            metadata: {
              'originalOutputId': output.id,
              'toolCallsExecuted': llmResponse.toolCalls.length,
            },
          );
          
          _outputs.add(llmOutput);
          _logger('🧠 LLM: "${llmResponse.content}" (${llmResponse.toolCalls.length} tools)');
        }
      }
    } catch (e) {
      _logger('❌ LLM processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Build context string for LLM processing
  String _buildLLMContext(AgentOutput output, List<TimestampedData<Uint8List>> correlatedImages) {
    final buffer = StringBuffer();
    buffer.writeln('Agent Output Analysis:');
    buffer.writeln('Type: ${output.type.name}');
    buffer.writeln('Content: "${output.content}"');
    buffer.writeln('Confidence: ${output.confidence}');
    buffer.writeln('Timestamp: ${output.timestamp}');
    buffer.writeln('Associated Images: ${correlatedImages.length}');
    
    // Add recent context if available
    final recentOutputs = _getRecentOutputs(maxCount: 5);
    if (recentOutputs.isNotEmpty) {
      buffer.writeln('\nRecent Context:');
      for (final recent in recentOutputs.take(3)) {
        buffer.writeln('- ${recent.type.name}: "${recent.content}"');
      }
    }
    
    return buffer.toString();
  }

  /// Get available tools for LLM
  List<String> _getAvailableTools() {
    return [
      'store_memory',     // Store information in vector DB
      'retrieve_memory',  // Query vector DB for context
      'update_memory',    // Update existing memory entry
      'analyze_content',  // Analyze content for insights
    ];
  }

  /// Execute a tool call from the LLM
  Future<void> _executeTool(ToolCall toolCall, AgentOutput originalOutput) async {
    try {
      switch (toolCall.name) {
        case 'store_memory':
          await _vectorService.storeMemory(
            content: toolCall.parameters['content'] ?? originalOutput.content,
            metadata: {
              'source': 'agent_${originalOutput.type.name}',
              'timestamp': originalOutput.timestamp.toIso8601String(),
              'confidence': originalOutput.confidence,
              'originalOutputId': originalOutput.id,
            },
          );
          _logger('💾 Stored memory: ${toolCall.parameters['content']}');
          break;
          
        case 'retrieve_memory':
          final query = toolCall.parameters['query'] ?? originalOutput.content;
          final results = await _vectorService.retrieveMemory(query: query);
          _logger('🔍 Retrieved ${results.length} memories for: $query');
          break;
          
        case 'update_memory':
          // Implementation would depend on specific update requirements
          _logger('🔄 Memory update requested');
          break;
          
        case 'analyze_content':
          // Store analysis result
          await _vectorService.storeMemory(
            content: 'Analysis: ${originalOutput.content}',
            metadata: {
              'source': 'agent_analysis',
              'timestamp': DateTime.now().toIso8601String(),
              'originalType': originalOutput.type.name,
            },
          );
          _logger('🔍 Content analysis stored');
          break;
          
        default:
          _logger('⚠️ Unknown tool: ${toolCall.name}');
      }
    } catch (e) {
      _logger('❌ Tool execution error (${toolCall.name}): $e');
    }
  }

  /// Get recent agent outputs
  List<AgentOutput> _getRecentOutputs({int maxCount = 10}) {
    final sorted = List<AgentOutput>.from(_outputs)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.take(maxCount).toList();
  }

  /// Disable agent processing
  Future<void> disable() async {
    if (!_isEnabled) return;
    
    try {
      _logger('⏹️ Disabling agent processing...');
      _isEnabled = false;
      
      // Stop observing streams
      _streamObserver.stopObserving();
      
      // Cancel subscriptions
      await _audioSubscription?.cancel();
      await _photoSubscription?.cancel();
      
      // Generate session report
      if (_sessionStartTime != null) {
        final duration = DateTime.now().difference(_sessionStartTime!);
        final correlationReport = _timestampManager.generateCorrelationReport(
          asrTimestamps: _outputs.where((o) => o.type == AgentOutputType.asr).map((o) => o.timestamp).toList(),
          ocrTimestamps: _outputs.where((o) => o.type == AgentOutputType.ocr).map((o) => o.timestamp).toList(),
          availablePhotos: _recentImages,
        );
        
        _logger('📊 Session Report:');
        _logger('Duration: ${duration.inSeconds}s');
        _logger('ASR Outputs: $_totalAsrOutputs');
        _logger('OCR Outputs: $_totalOcrOutputs');
        _logger('LLM Calls: $_totalLLMCalls');
        _logger('Total Outputs: ${_outputs.length}');
        _logger(correlationReport.generateSummary());
      }
      
      _logger('✅ Agent processing disabled');
    } catch (e) {
      _logger('❌ Error disabling agent: $e');
    }
  }

  /// Get current agent status
  Map<String, dynamic> get status => {
    'isEnabled': _isEnabled,
    'isProcessing': _isProcessing,
    'totalOutputs': _outputs.length,
    'asrOutputs': _totalAsrOutputs,
    'ocrOutputs': _totalOcrOutputs,
    'llmCalls': _totalLLMCalls,
    'recentImages': _recentImages.length,
    'streamObserver': _streamObserver.combinedStatistics,
    'services': {
      'asr': _asrService.isReady,
      'ocr': _ocrService.isReady,
      'llm': _llmService.isReady,
      'vector': _vectorService.isReady,
    },
  };

  /// Get recent outputs for UI display
  List<AgentOutput> getRecentOutputs({int limit = 20}) {
    return _getRecentOutputs(maxCount: limit);
  }

  /// Get outputs by type
  List<AgentOutput> getOutputsByType(AgentOutputType type) {
    return _outputs.where((output) => output.type == type).toList();
  }

  /// Clear all stored outputs (useful for testing)
  void clearOutputs() {
    _outputs.clear();
    _totalAsrOutputs = 0;
    _totalOcrOutputs = 0;
    _totalLLMCalls = 0;
    _logger('🧹 Agent outputs cleared');
  }

  /// Dispose all resources
  void dispose() {
    disable();
    _streamObserver.dispose();
    _asrService.dispose();
    _ocrService.dispose();
    _llmService.dispose();
    _vectorService.dispose();
    _logger('🧹 Agent core disposed');
  }
}