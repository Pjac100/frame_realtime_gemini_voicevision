import 'dart:async';
import '../../services/vector_db_service.dart';

/// Agent wrapper for the existing vector database service
/// Provides agent-specific operations while preserving the main VectorDbService
class AgentVectorService {
  final VectorDbService _vectorDbService;
  final void Function(String)? _logger;
  bool _isReady = false;
  
  AgentVectorService({
    required VectorDbService vectorDbService,
    void Function(String)? logger,
  }) : _vectorDbService = vectorDbService, _logger = logger;

  /// Initialize the agent vector service
  Future<bool> initialize() async {
    try {
      _logger?.call('🔗 Initializing agent vector service...');
      
      // The underlying VectorDbService should already be initialized by the main app
      // We just need to verify it's working
      final stats = await _vectorDbService.getStats();
      
      if (stats.containsKey('error')) {
        _logger?.call('❌ Underlying vector DB has errors: ${stats['error']}');
        return false;
      }
      
      _isReady = true;
      final totalDocs = stats['totalDocuments'] ?? 0;
      _logger?.call('✅ Agent vector service ready ($totalDocs existing docs)');
      
      return true;
    } catch (e) {
      _logger?.call('❌ Agent vector service initialization failed: $e');
      return false;
    }
  }

  /// Check if the service is ready
  bool get isReady => _isReady;

  /// Store memory from agent processing
  Future<void> storeMemory({
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_isReady) {
      _logger?.call('⚠️ Agent vector service not ready');
      return;
    }

    try {
      final agentMetadata = <String, dynamic>{
        'source': 'agent_system',
        'timestamp': DateTime.now().toIso8601String(),
        ...?metadata,
      };

      await _vectorDbService.addTextWithEmbedding(
        content: content,
        metadata: agentMetadata,
      );

      _logger?.call('💾 Stored agent memory: ${_truncateContent(content)}');
    } catch (e) {
      _logger?.call('❌ Failed to store memory: $e');
      rethrow;
    }
  }

  /// Retrieve memory based on query
  Future<List<Map<String, Object?>>> retrieveMemory({
    required String query,
    int limit = 5,
    double threshold = 0.3,
  }) async {
    if (!_isReady) {
      _logger?.call('⚠️ Agent vector service not ready');
      return [];
    }

    try {
      final results = await _vectorDbService.queryText(
        queryText: query,
        topK: limit,
        threshold: threshold,
      );

      _logger?.call('🔍 Retrieved ${results.length} memories for: ${_truncateContent(query)}');
      return results;
    } catch (e) {
      _logger?.call('❌ Failed to retrieve memory: $e');
      return [];
    }
  }

  /// Store ASR output in vector database
  Future<void> storeASROutput({
    required String text,
    required double confidence,
    required DateTime timestamp,
    List<DateTime>? associatedImageTimestamps,
  }) async {
    if (!_isReady || text.trim().isEmpty) return;

    try {
      await storeMemory(
        content: text,
        metadata: {
          'type': 'asr_output',
          'confidence': confidence,
          'timestamp': timestamp.toIso8601String(),
          'associatedImages': associatedImageTimestamps?.length ?? 0,
          'processingSource': 'agent_asr',
        },
      );
    } catch (e) {
      _logger?.call('❌ Failed to store ASR output: $e');
    }
  }

  /// Store OCR output in vector database
  Future<void> storeOCROutput({
    required String text,
    required double confidence,
    required DateTime timestamp,
    List<DateTime>? associatedImageTimestamps,
  }) async {
    if (!_isReady || text.trim().isEmpty) return;

    try {
      await storeMemory(
        content: text,
        metadata: {
          'type': 'ocr_output',
          'confidence': confidence,
          'timestamp': timestamp.toIso8601String(),
          'associatedImages': associatedImageTimestamps?.length ?? 0,
          'processingSource': 'agent_ocr',
        },
      );
    } catch (e) {
      _logger?.call('❌ Failed to store OCR output: $e');
    }
  }

  /// Store LLM analysis result
  Future<void> storeLLMAnalysis({
    required String analysis,
    required String originalContent,
    required DateTime timestamp,
  }) async {
    if (!_isReady || analysis.trim().isEmpty) return;

    try {
      await storeMemory(
        content: analysis,
        metadata: {
          'type': 'llm_analysis',
          'originalContent': _truncateContent(originalContent),
          'timestamp': timestamp.toIso8601String(),
          'processingSource': 'agent_llm',
        },
      );
    } catch (e) {
      _logger?.call('❌ Failed to store LLM analysis: $e');
    }
  }

  /// Query for conversation context
  Future<String> getConversationContext({
    required String currentQuery,
    int maxResults = 3,
    double threshold = 0.4,
  }) async {
    if (!_isReady) return 'Vector service not available.';

    try {
      return await _vectorDbService.getConversationContext(
        currentQuery: currentQuery,
        maxResults: maxResults,
        threshold: threshold,
      );
    } catch (e) {
      _logger?.call('❌ Failed to get conversation context: $e');
      return 'Error retrieving conversation context.';
    }
  }

  /// Query for similar agent outputs
  Future<List<Map<String, Object?>>> findSimilarAgentOutputs({
    required String query,
    String? outputType, // 'asr', 'ocr', 'llm'
    int limit = 5,
    double threshold = 0.3,
  }) async {
    if (!_isReady) return [];

    try {
      final results = await retrieveMemory(
        query: query,
        limit: limit * 2, // Get more results to filter
        threshold: threshold,
      );

      // Filter by output type if specified
      if (outputType != null) {
        return results.where((result) {
          final metadata = result['metadata'] as Map<String, String>?;
          return metadata?['type'] == '${outputType}_output';
        }).take(limit).toList();
      }

      return results.take(limit).toList();
    } catch (e) {
      _logger?.call('❌ Failed to find similar outputs: $e');
      return [];
    }
  }

  /// Get memory statistics for the agent
  Future<Map<String, dynamic>> getAgentMemoryStats() async {
    if (!_isReady) {
      return {'error': 'Service not ready'};
    }

    try {
      final stats = await _vectorDbService.getStats();
      
      // Count agent-specific entries
      final allDocs = await _vectorDbService.getAllDocuments();
      int agentDocs = 0;
      int asrDocs = 0;
      int ocrDocs = 0;
      int llmDocs = 0;

      for (final doc in allDocs) {
        if (doc.metadata?.contains('agent_system') == true) {
          agentDocs++;
          
          if (doc.metadata?.contains('asr_output') == true) asrDocs++;
          if (doc.metadata?.contains('ocr_output') == true) ocrDocs++;
          if (doc.metadata?.contains('llm_analysis') == true) llmDocs++;
        }
      }

      return {
        ...stats,
        'agentDocuments': agentDocs,
        'asrOutputs': asrDocs,
        'ocrOutputs': ocrDocs,
        'llmAnalyses': llmDocs,
      };
    } catch (e) {
      _logger?.call('❌ Failed to get memory stats: $e');
      return {'error': e.toString()};
    }
  }

  /// Clear agent-specific memories (useful for testing)
  Future<void> clearAgentMemories() async {
    if (!_isReady) return;

    try {
      // Note: This is a simple implementation
      // A more sophisticated version would selectively remove only agent docs
      _logger?.call('⚠️ Cannot selectively clear agent memories with current implementation');
      _logger?.call('Use main vector service clearAll() if needed');
    } catch (e) {
      _logger?.call('❌ Failed to clear memories: $e');
    }
  }

  /// Search for memories by time range
  Future<List<Map<String, Object?>>> searchMemoriesByTimeRange({
    required DateTime startTime,
    required DateTime endTime,
    int limit = 10,
  }) async {
    if (!_isReady) return [];

    try {
      // Get all agent documents and filter by time
      final allResults = await retrieveMemory(
        query: 'agent memory',
        limit: 100, // Get many results for filtering
        threshold: 0.1, // Low threshold to get more results
      );

      final filteredResults = <Map<String, Object?>>[];
      
      for (final result in allResults) {
        final metadata = result['metadata'] as Map<String, String>?;
        final timestampStr = metadata?['timestamp'];
        
        if (timestampStr != null) {
          try {
            final timestamp = DateTime.parse(timestampStr);
            if (timestamp.isAfter(startTime) && timestamp.isBefore(endTime)) {
              filteredResults.add(result);
            }
          } catch (e) {
            // Skip entries with invalid timestamps
          }
        }
      }

      // Sort by timestamp (newest first)
      filteredResults.sort((a, b) {
        final aMetadata = a['metadata'] as Map<String, String>?;
        final bMetadata = b['metadata'] as Map<String, String>?;
        final aTime = aMetadata?['timestamp'];
        final bTime = bMetadata?['timestamp'];
        if (aTime == null || bTime == null) return 0;
        return DateTime.parse(bTime).compareTo(DateTime.parse(aTime));
      });

      final limitedResults = filteredResults.take(limit).toList();
      _logger?.call('🕐 Found ${limitedResults.length} memories in time range');
      
      return limitedResults;
    } catch (e) {
      _logger?.call('❌ Failed to search by time range: $e');
      return [];
    }
  }

  /// Get the underlying vector service (for advanced operations)
  VectorDbService get underlyingService => _vectorDbService;

  /// Truncate content for logging
  String _truncateContent(String content, {int maxLength = 50}) {
    if (content.length <= maxLength) return content;
    return '${content.substring(0, maxLength)}...';
  }

  /// Get service configuration
  Map<String, dynamic> getConfiguration() {
    return {
      'isReady': _isReady,
      'underlyingService': 'VectorDbService',
      'supportedOperations': [
        'store_memory',
        'retrieve_memory',
        'store_asr_output',
        'store_ocr_output',
        'store_llm_analysis',
        'get_conversation_context',
        'find_similar_outputs',
        'search_by_time_range',
      ],
    };
  }

  /// Dispose resources
  void dispose() {
    _isReady = false;
    _logger?.call('🧹 Agent vector service disposed');
    // Note: We don't dispose the underlying service as it's owned by the main app
  }
}