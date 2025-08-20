/// Data models for agent outputs with timestamp correlation
library agent_output;

/// These models ensure all agent operations are properly timestamped and associated with relevant images

enum AgentOutputType {
  asr,      // Automatic Speech Recognition
  ocr,      // Optical Character Recognition  
  llm,      // Local LLM processing
  toolCall, // Tool execution result
}

/// Main agent output model with timestamp correlation
class AgentOutput {
  final String id;
  final DateTime timestamp;
  final AgentOutputType type;
  final String content;
  final double confidence;
  final List<DateTime> associatedImageTimestamps;
  final Map<String, dynamic> metadata;
  
  const AgentOutput({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.content,
    required this.confidence,
    required this.associatedImageTimestamps,
    required this.metadata,
  });

  /// Get the number of associated images
  int get associatedImageCount => associatedImageTimestamps.length;
  
  /// Check if this output has associated images
  bool get hasAssociatedImages => associatedImageTimestamps.isNotEmpty;
  
  /// Get a summary for display
  String get summary {
    final contentPreview = content.length > 50 
        ? '${content.substring(0, 50)}...' 
        : content;
    return '${type.name.toUpperCase()}: $contentPreview';
  }
  
  /// Convert to map for serialization
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'type': type.name,
      'content': content,
      'confidence': confidence,
      'associatedImageTimestamps': associatedImageTimestamps.map((t) => t.toIso8601String()).toList(),
      'metadata': metadata,
    };
  }
  
  /// Create from map (for deserialization)
  factory AgentOutput.fromMap(Map<String, dynamic> map) {
    return AgentOutput(
      id: map['id'] ?? '',
      timestamp: DateTime.parse(map['timestamp'] ?? DateTime.now().toIso8601String()),
      type: AgentOutputType.values.firstWhere(
        (type) => type.name == map['type'],
        orElse: () => AgentOutputType.llm,
      ),
      content: map['content'] ?? '',
      confidence: (map['confidence'] ?? 0.0).toDouble(),
      associatedImageTimestamps: (map['associatedImageTimestamps'] as List<dynamic>?)
          ?.map((t) => DateTime.parse(t.toString()))
          .toList() ?? [],
      metadata: Map<String, dynamic>.from(map['metadata'] ?? {}),
    );
  }

  @override
  String toString() {
    return 'AgentOutput(id: $id, type: $type, content: "$content", '
           'confidence: $confidence, images: $associatedImageCount)';
  }
}

/// Result from ASR processing
class ASRResult {
  final String text;
  final double confidence;
  final Duration processingTime;
  final Map<String, dynamic> metadata;
  
  const ASRResult({
    required this.text,
    required this.confidence,
    required this.processingTime,
    this.metadata = const {},
  });
  
  bool get isReliable => confidence > 0.7;
  bool get hasContent => text.trim().isNotEmpty;
  
  @override
  String toString() => 'ASRResult(text: "$text", confidence: $confidence)';
}

/// Result from OCR processing
class OCRResult {
  final String text;
  final double confidence;
  final Duration processingTime;
  final List<TextBlock> textBlocks;
  final Map<String, dynamic> metadata;
  
  const OCRResult({
    required this.text,
    required this.confidence,
    required this.processingTime,
    this.textBlocks = const [],
    this.metadata = const {},
  });
  
  bool get isReliable => confidence > 0.6;
  bool get hasContent => text.trim().isNotEmpty;
  bool get hasStructuredText => textBlocks.isNotEmpty;
  
  @override
  String toString() => 'OCRResult(text: "$text", confidence: $confidence, blocks: ${textBlocks.length})';
}

/// Individual text block from OCR with position information
class TextBlock {
  final String text;
  final double confidence;
  final BoundingBox? bounds;
  final Map<String, dynamic> metadata;
  
  const TextBlock({
    required this.text,
    required this.confidence,
    this.bounds,
    this.metadata = const {},
  });
  
  @override
  String toString() => 'TextBlock(text: "$text", confidence: $confidence)';
}

/// Bounding box for text location in image
class BoundingBox {
  final double left;
  final double top;
  final double width;
  final double height;
  
  const BoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
  
  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;
  double get area => width * height;
  
  @override
  String toString() => 'BoundingBox(x: $left, y: $top, w: $width, h: $height)';
}

/// Response from local LLM with tool calls
class LLMResponse {
  final String content;
  final List<ToolCall> toolCalls;
  final Duration processingTime;
  final Map<String, dynamic> metadata;
  
  const LLMResponse({
    required this.content,
    required this.toolCalls,
    required this.processingTime,
    this.metadata = const {},
  });
  
  bool get hasContent => content.trim().isNotEmpty;
  bool get hasToolCalls => toolCalls.isNotEmpty;
  
  @override
  String toString() => 'LLMResponse(content: "$content", tools: ${toolCalls.length})';
}

/// Tool call from LLM
class ToolCall {
  final String name;
  final Map<String, dynamic> parameters;
  final String? id;
  
  const ToolCall({
    required this.name,
    required this.parameters,
    this.id,
  });
  
  /// Get a parameter value with type checking
  T? getParameter<T>(String key) {
    final value = parameters[key];
    return value is T ? value : null;
  }
  
  /// Get parameter as string
  String getStringParameter(String key, {String defaultValue = ''}) {
    return getParameter<String>(key) ?? defaultValue;
  }
  
  /// Get parameter as double
  double getDoubleParameter(String key, {double defaultValue = 0.0}) {
    final value = parameters[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? defaultValue;
    return defaultValue;
  }
  
  /// Get parameter as int
  int getIntParameter(String key, {int defaultValue = 0}) {
    final value = parameters[key];
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value) ?? defaultValue;
    return defaultValue;
  }
  
  /// Get parameter as bool
  bool getBoolParameter(String key, {bool defaultValue = false}) {
    final value = parameters[key];
    if (value is bool) return value;
    if (value is String) {
      return value.toLowerCase() == 'true' || value == '1';
    }
    return defaultValue;
  }
  
  @override
  String toString() => 'ToolCall(name: $name, params: ${parameters.keys.join(", ")})';
}

/// Image capture with metadata for temporal correlation
class ImageCapture {
  final String id;
  final DateTime timestamp;
  final List<int> jpegData; // Using List<int> for JSON serialization
  final List<String> associatedOutputIds;
  final Map<String, dynamic> metadata;
  
  const ImageCapture({
    required this.id,
    required this.timestamp,
    required this.jpegData,
    required this.associatedOutputIds,
    required this.metadata,
  });
  
  /// Get image size in bytes
  int get sizeBytes => jpegData.length;
  
  /// Get image size in KB
  double get sizeKB => sizeBytes / 1024.0;
  
  /// Check if this image has associated agent outputs
  bool get hasAssociatedOutputs => associatedOutputIds.isNotEmpty;
  
  /// Convert to map for serialization
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'jpegData': jpegData,
      'associatedOutputIds': associatedOutputIds,
      'metadata': metadata,
    };
  }
  
  /// Create from map (for deserialization)
  factory ImageCapture.fromMap(Map<String, dynamic> map) {
    return ImageCapture(
      id: map['id'] ?? '',
      timestamp: DateTime.parse(map['timestamp'] ?? DateTime.now().toIso8601String()),
      jpegData: List<int>.from(map['jpegData'] ?? []),
      associatedOutputIds: List<String>.from(map['associatedOutputIds'] ?? []),
      metadata: Map<String, dynamic>.from(map['metadata'] ?? {}),
    );
  }
  
  @override
  String toString() {
    return 'ImageCapture(id: $id, timestamp: $timestamp, '
           'size: ${sizeKB.toStringAsFixed(1)}KB, outputs: ${associatedOutputIds.length})';
  }
}

/// Statistics for agent operations
class AgentStatistics {
  final int totalOutputs;
  final int asrOutputs;
  final int ocrOutputs;
  final int llmOutputs;
  final int imagesCaptured;
  final int correlatedOutputs;
  final double correlationRate;
  final Duration sessionDuration;
  final DateTime sessionStart;
  final Map<String, dynamic> metadata;
  
  const AgentStatistics({
    required this.totalOutputs,
    required this.asrOutputs,
    required this.ocrOutputs,
    required this.llmOutputs,
    required this.imagesCaptured,
    required this.correlatedOutputs,
    required this.correlationRate,
    required this.sessionDuration,
    required this.sessionStart,
    this.metadata = const {},
  });
  
  /// Calculate outputs per minute
  double get outputsPerMinute {
    final minutes = sessionDuration.inSeconds / 60.0;
    return minutes > 0 ? totalOutputs / minutes : 0.0;
  }
  
  /// Get correlation percentage
  double get correlationPercentage => correlationRate * 100;
  
  @override
  String toString() {
    return 'AgentStatistics(outputs: $totalOutputs, correlation: ${correlationPercentage.toStringAsFixed(1)}%, '
           'duration: ${sessionDuration.inSeconds}s)';
  }
}