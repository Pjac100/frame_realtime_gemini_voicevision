# Frame Agent Integration Architecture

## Overview
This document outlines the architecture for integrating a local, on-device agentic LLM into the existing Frame Realtime Gemini app while preserving all current functionality.

## Design Principles
1. **Read-Only Stream Access**: Agent observes existing streams without modification
2. **Zero-Impact on Main Pipeline**: Main streaming process remains completely unaffected
3. **Timestamp-Driven Correlation**: All agent outputs are precisely timestamped for association
4. **Graceful Degradation**: App continues normally when agent is disabled/fails
5. **Incremental Integration**: Each capability can be enabled/disabled independently

## Architecture Components

### 1. Stream Observers (Read-Only)
```
RxAudio Stream → [Main Gemini Pipeline] → FlutterPcmSound
                ↓ (non-blocking observer)
                StreamObserver → Agent Audio Processor

RxPhoto Stream → [Main Gemini Pipeline] → UI Display  
                ↓ (non-blocking observer)
                StreamObserver → Agent Image Processor
```

### 2. Agent Core Components
- **AgentStreamObserver**: Mirrors main streams with timestamps
- **LocalLLMService**: Handles tool calling and function execution
- **ASRService**: Speech-to-text from audio stream
- **OCRService**: Text extraction from image stream
- **AgentVectorService**: Wraps existing VectorDbService for agent operations
- **TimestampManager**: Correlates ASR/OCR outputs with images by timestamp

### 3. Data Flow
```
Audio Stream → ASRService → Timestamped Text
Image Stream → OCRService → Timestamped Text
Both → AgentCore → LocalLLM → Tool Calls → VectorDB Updates
```

### 4. Storage Schema
```
AgentOutput {
  id: String
  timestamp: DateTime
  type: 'asr' | 'ocr' | 'tool_call'
  content: String
  confidence: double
  associatedImages: List<ImageRef>
  metadata: Map<String, dynamic>
}

ImageCapture {
  id: String
  timestamp: DateTime
  jpegData: Uint8List
  associatedOutputs: List<String> // References to AgentOutput IDs
}
```

## Implementation Strategy

### Phase 1: Stream Observer Foundation
- Create non-blocking observers for existing RxAudio/RxPhoto streams
- Implement timestamp correlation system
- Add agent enable/disable toggle in UI

### Phase 2: Local LLM Integration
- Add local LLM service with tool calling capabilities
- Implement basic ASR using on-device speech recognition
- Add OCR using existing ML Kit integration

### Phase 3: Vector Database Integration
- Extend existing VectorDbService for agent operations
- Implement memory storage and retrieval patterns
- Add timestamp-based query capabilities

### Phase 4: Full Agent Capabilities
- Complete ASR/OCR pipeline with timestamp correlation
- Implement tool calling for VDB operations
- Add comprehensive logging and debugging

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
│   ├── agent_output.dart           # Agent output data models
│   └── image_capture.dart          # Image capture with metadata
└── ui/
    └── agent_demo_widget.dart      # Demo interface for agent features
```

## Integration Points

### Main App Integration
- Add agent toggle to existing UI
- Insert stream observers into main.dart initialization
- Extend existing vector DB with agent-specific queries

### Non-Disruptive Integration
- Agent components are initialized only when enabled
- Stream observers use weak references to avoid memory leaks  
- All agent operations are async and non-blocking

## Testing Strategy
- Unit tests for each agent component
- Integration tests ensuring main pipeline is unaffected
- Performance tests validating no impact on streaming latency
- End-to-end tests for complete agent workflows