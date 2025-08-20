# Frame Agent Integration Documentation

## Overview

This document describes the integration of a local, on-device agentic LLM system into the Frame Realtime Gemini VoiceVision app. The agent system provides ASR, OCR, and LLM capabilities that operate read-only alongside the main streaming pipeline without disrupting existing functionality.

## Integration Architecture

### Core Principles
- **Read-Only Operation**: Agent observes existing streams without modification
- **Zero-Impact Design**: Main streaming process remains completely unaffected
- **Timestamp Correlation**: All agent outputs are precisely timestamped for association
- **Graceful Degradation**: App continues normally when agent is disabled/fails
- **Incremental Capabilities**: Each feature can be enabled/disabled independently

### System Components

```
Main App Stream Pipeline:
RxAudio → Gemini Realtime API → FlutterPcmSound
RxPhoto → Gemini Realtime API → UI Display

Agent System (Parallel):
StreamObserver → [ASR, OCR, LLM] → VectorDB
     ↓
TimestampManager → Correlate outputs with images
```

## File Structure

```
lib/agent/
├── core/
│   ├── agent_core.dart              # Main agent coordinator
│   ├── stream_observer.dart         # Non-blocking stream observation
│   └── timestamp_manager.dart       # Timestamp correlation logic
├── services/
│   ├── local_llm_service.dart       # Local LLM with tool calling
│   ├── asr_service.dart            # Speech recognition
│   ├── ocr_service.dart            # Optical character recognition
│   └── agent_vector_service.dart    # Vector DB operations for agent
├── models/
│   └── agent_output.dart           # Agent output data models
└── ui/
    └── agent_demo_widget.dart      # Demo interface for agent features
```

## Key Features Implemented

### 1. Stream Observation System
- **StreamObserver**: Non-blocking observation of RxAudio and RxPhoto streams
- **TimestampManager**: Correlates ASR/OCR outputs with captured images
- **Isolated Processing**: Agent runs separately from main pipeline

### 2. Agent Services
- **ASRService**: Mock speech-to-text with voice activity detection
- **OCRService**: ML Kit text recognition with fallback mock implementation
- **LocalLLMService**: Mock LLM with tool calling capabilities
- **AgentVectorService**: Wrapper for existing VectorDbService

### 3. Tool Calling System
- **store_memory**: Store information in vector database
- **retrieve_memory**: Query vector database for context
- **update_memory**: Update existing memory entries
- **analyze_content**: Analyze content for insights

### 4. Data Models
- **AgentOutput**: Timestamped outputs with image associations
- **ASRResult/OCRResult**: Service-specific results with confidence scores
- **LLMResponse**: Tool calls and content from local LLM
- **ImageCapture**: Timestamped image data with metadata

## Usage Instructions

### Enabling the Agent Demo

1. **Start the App**: The agent system initializes automatically with graceful degradation
2. **Connect Frame**: Establish connection to Frame smart glasses
3. **Agent UI**: Scroll down to the "Local Agent System" card in the main UI
4. **Monitor Status**: View agent service status and recent outputs

### Demo Features

- **Service Status**: Shows readiness of ASR, OCR, LLM, and Vector DB services
- **Recent Outputs**: Displays timestamped ASR/OCR results with confidence scores
- **Image Association**: Shows how many images are correlated with each output
- **Statistics**: Total outputs, correlation rates, and processing metrics

### Testing Agent Features

```bash
# Run agent-specific tests
flutter test test/agent_test.dart

# Run all tests
flutter test

# Analyze code quality
flutter analyze lib/agent/
```

## Implementation Details

### Stream Tapping Mechanism

The agent uses `StreamObserver` to create read-only mirrors of the main streams:

```dart
// Main stream continues unchanged
Stream<Uint8List> audioStream = rxAudio.attach(frame.dataResponse);

// Agent creates non-blocking observer
streamObserver.observe(audioStream);
streamObserver.observedStream.listen((timestampedAudio) {
  // Process without affecting main stream
});
```

### Timestamp Correlation

The `TimestampManager` associates agent outputs with images captured around the same time:

```dart
final correlatedImages = timestampManager.correlateWithPhotos(
  outputTimestamp: asrResult.timestamp,
  availablePhotos: recentImages,
  customWindow: Duration(seconds: 2),
);
```

### Tool Execution

The local LLM can execute tools to interact with the vector database:

```dart
final llmResponse = await localLLM.processWithTools(
  context: "User said: 'Hello Frame'",
  availableTools: ['store_memory', 'retrieve_memory'],
);

for (final toolCall in llmResponse.toolCalls) {
  await agentVectorService.executeTool(toolCall);
}
```

## Integration Points

### Main App Changes

1. **Imports Added** (main.dart:27-30):
   ```dart
   import 'package:frame_realtime_gemini_voicevision/agent/core/agent_core.dart';
   import 'package:frame_realtime_gemini_voicevision/agent/services/agent_vector_service.dart';
   import 'package:frame_realtime_gemini_voicevision/agent/ui/agent_demo_widget.dart';
   ```

2. **Agent System Fields** (main.dart:135-137):
   ```dart
   AgentCore? _agentCore;
   AgentVectorService? _agentVectorService;
   ```

3. **Initialization** (main.dart:210-211):
   ```dart
   await _initializeAgentSystem();
   ```

4. **UI Integration** (main.dart:782):
   ```dart
   AgentDemoWidget(agentCore: _agentCore),
   ```

### Vector Database Integration

The agent wraps the existing `VectorDbService` without modification:

```dart
_agentVectorService = AgentVectorService(
  vectorDbService: _vectorDb!, // Existing service
  logger: _logEvent,
);
```

## Performance Considerations

- **Memory Usage**: Agent stores recent outputs and images with configurable limits
- **Processing**: All agent operations are async and non-blocking
- **Stream Impact**: Zero impact on main audio/video streams
- **Graceful Failure**: Agent failures don't affect main app functionality

## Future Enhancements

### Production LLM Integration
Replace `LocalLLMService` mock with actual on-device LLM:
- ONNX Runtime integration
- TensorFlow Lite models
- Ollama local deployment

### Advanced ASR/OCR
Enhance recognition services:
- Real-time ASR streaming
- Multi-language support
- Custom OCR models

### Agent Capabilities
Extend tool calling system:
- Frame device control
- External API integration
- Complex reasoning chains

## Testing Coverage

The test suite covers:
- ✅ Stream observation (non-blocking)
- ✅ Timestamp correlation
- ✅ Service initialization
- ✅ Data model serialization
- ✅ Tool call parameter handling
- ✅ Integration scenarios

Run tests with: `flutter test test/agent_test.dart`

## Troubleshooting

### Agent Not Initializing
- Check ObjectBox vector database initialization
- Verify app permissions
- Check event log for specific errors

### No Agent Outputs
- Ensure Frame is connected and streaming
- Check agent service status in demo UI
- Verify audio/image streams are active

### ML Kit Errors (OCR)
- Expected in test environment
- OCR service gracefully falls back to mock implementation
- Production builds should work with actual ML Kit

## Building and Deployment

The agent system is integrated into the existing build process:

```bash
# Build APK with agent system
flutter build apk

# The agent is included automatically
# No additional configuration required
```

## Conclusion

The agent integration successfully adds local AI capabilities to the Frame app while maintaining all existing functionality. The system provides a foundation for advanced on-device AI features with proper isolation, error handling, and performance considerations.