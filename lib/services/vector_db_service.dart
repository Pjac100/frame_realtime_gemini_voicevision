import 'dart:math' as math;
import 'dart:typed_data';
import 'package:objectbox/objectbox.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:frame_realtime_gemini_voicevision/model/document_entity.dart';
import 'package:frame_realtime_gemini_voicevision/objectbox.g.dart';
import 'package:frame_realtime_gemini_voicevision/utils/tensor_utils.dart';

class VectorDbService {
  late final Box<Document> _box;
  late final Store _store;
  
  // MobileBERT model components
  Interpreter? _interpreter;
  Map<String, int>? _vocab;
  bool _isModelLoaded = false;
  
  // MobileBERT constants
  static const int maxSequenceLength = 128;
  static const int embeddingSize = 384;
  static const String modelAssetPath = 'assets/mobilebert_embedding.tflite';
  static const String vocabAssetPath = 'assets/vocab.txt';

  VectorDbService([void Function(String msg)? uiLogger])
      : _emit = uiLogger ?? ((_) {});

  final void Function(String) _emit;

  Future<void> initialize(Store store) async {
    try {
      _store = store;
      _box = _store.box<Document>();
      
      await _loadMobileBertModel();
      
      if (_isModelLoaded) {
        final count = _box.count();
        _emit('✅ VectorDB initialized with MobileBERT embeddings (docs: $count)');
      } else {
        final count = _box.count();
        _emit('⚠️ VectorDB initialized without embeddings (docs: $count)');
      }
    } catch (e) {
      _emit('❌ VectorDB initialization failed: $e');
      rethrow;
    }
  }

  Future<void> _loadMobileBertModel() async {
    try {
      _emit('🤖 Loading MobileBERT model...');
      
      _interpreter = await Interpreter.fromAsset(modelAssetPath);
      await _loadVocabulary();
      
      _isModelLoaded = true;
      _emit('✅ MobileBERT model loaded successfully');
      
      if (_interpreter != null) {
        final inputTensors = _interpreter!.getInputTensors();
        final outputTensors = _interpreter!.getOutputTensors();
        
        _emit('📊 Model input shape: ${inputTensors.first.shape}');
        _emit('📊 Model output shape: ${outputTensors.first.shape}');
      }
      
    } catch (e) {
      _emit('❌ Failed to load MobileBERT model: $e');
      _isModelLoaded = false;
    }
  }

  Future<void> _loadVocabulary() async {
    try {
      _emit('📚 Loading vocabulary...');
      
      final vocabContent = await rootBundle.loadString(vocabAssetPath);
      final lines = vocabContent.split('\n');
      
      _vocab = <String, int>{};
      for (int i = 0; i < lines.length; i++) {
        final token = lines[i].trim();
        if (token.isNotEmpty) {
          _vocab![token] = i;
        }
      }
      
      final vocabSize = _vocab!.length;
      _emit('✅ Vocabulary loaded: $vocabSize tokens');
    } catch (e) {
      _emit('❌ Failed to load vocabulary: $e');
      rethrow;
    }
  }

  List<int> _tokenizeText(String text) {
    if (_vocab == null) {
      return [];
    }

    final tokens = <int>[];
    final words = text.toLowerCase().split(RegExp(r'\W+'));
    
    // Add CLS token
    final clsToken = _vocab!['[CLS]'] ?? 0;
    tokens.add(clsToken);
    
    for (final word in words) {
      if (word.isEmpty) continue;
      
      if (_vocab!.containsKey(word)) {
        tokens.add(_vocab![word]!);
      } else {
        final subwords = _wordPieceTokenize(word);
        for (final subword in subwords) {
          final tokenId = _vocab![subword] ?? _vocab!['[UNK]'] ?? 0;
          tokens.add(tokenId);
        }
      }
      
      if (tokens.length >= maxSequenceLength - 1) {
        break;
      }
    }
    
    // Add SEP token
    final sepToken = _vocab!['[SEP]'] ?? 0;
    tokens.add(sepToken);
    
    // Pad or truncate
    while (tokens.length < maxSequenceLength) {
      tokens.add(0);
    }
    
    if (tokens.length > maxSequenceLength) {
      tokens.length = maxSequenceLength;
      tokens[maxSequenceLength - 1] = sepToken;
    }
    
    return tokens;
  }

  List<String> _wordPieceTokenize(String word) {
    if (_vocab == null) return ['[UNK]'];
    
    final subwords = <String>[];
    String remaining = word;
    
    while (remaining.isNotEmpty) {
      String? longestSubword;
      
      for (int i = remaining.length; i > 0; i--) {
        final prefix = subwords.isEmpty ? '' : '##';
        final candidate = prefix + remaining.substring(0, i);
        if (_vocab!.containsKey(candidate)) {
          longestSubword = candidate;
          break;
        }
      }
      
      if (longestSubword != null) {
        subwords.add(longestSubword);
        final prefixLength = longestSubword.startsWith('##') 
            ? longestSubword.length - 2 
            : longestSubword.length;
        remaining = remaining.substring(prefixLength);
      } else {
        subwords.add('[UNK]');
        break;
      }
    }
    
    return subwords;
  }

  Future<List<double>> generateEmbedding(String text) async {
    if (!_isModelLoaded || _interpreter == null) {
      _emit('⚠️ Using fallback embedding - MobileBERT not available');
      return _generateFallbackEmbedding(text);
    }

    try {
      final tokens = _tokenizeText(text);
      
      final inputIds = Int32List.fromList(tokens);
      final attentionMask = Int32List.fromList(
        tokens.map((token) => token != 0 ? 1 : 0).toList()
      );
      final tokenTypeIds = Int32List.fromList(
        List.filled(maxSequenceLength, 0)
      );
      
      final inputs = [
        TensorUtils.reshape2DInt32(inputIds, 1, maxSequenceLength),
        TensorUtils.reshape2DInt32(attentionMask, 1, maxSequenceLength),
        TensorUtils.reshape2DInt32(tokenTypeIds, 1, maxSequenceLength),
      ];
      
      final outputData = Float32List(embeddingSize);
      final outputs = <int, Object>{
        0: TensorUtils.reshape2DFloat32(outputData, 1, embeddingSize),
      };
      
      _interpreter!.runForMultipleInputs(inputs, outputs);
      
      final outputTensor = outputs[0] as List<List<double>>;
      final embedding = TensorUtils.flatten<double>(outputTensor);
      
      final embeddingLength = embedding.length;
      _emit('🧠 Generated MobileBERT embedding ($embeddingLength dims)');
      return embedding;
      
    } catch (e) {
      _emit('❌ MobileBERT embedding failed: $e, using fallback');
      return _generateFallbackEmbedding(text);
    }
  }

  List<double> _generateFallbackEmbedding(String text) {
    final words = text.toLowerCase().split(RegExp(r'\W+'));
    final embedding = List<double>.filled(embeddingSize, 0.0);
    
    for (int i = 0; i < words.length && i < 50; i++) {
      final word = words[i];
      final hash = word.hashCode;
      
      for (int j = 0; j < embeddingSize; j++) {
        final value = (hash + i + j) / 1000.0;
        embedding[j] += math.sin(value) * 0.1;
      }
    }
    
    final norm = math.sqrt(embedding.map((x) => x * x).reduce((a, b) => a + b));
    if (norm > 0) {
      for (int i = 0; i < embedding.length; i++) {
        embedding[i] /= norm;
      }
    }
    
    return embedding;
  }

  Future<void> dispose() async {
    _interpreter?.close();
    _interpreter = null;
    _vocab?.clear();
    _isModelLoaded = false;
  }

  Future<void> addEmbedding({
    required String id,
    required List<double> embedding,
    required Map<String, dynamic> metadata,
  }) async {
    try {
      final content = metadata['content']?.toString() ?? 
                      metadata['source']?.toString() ?? 
                      id;
      
      final metadataEntries = metadata.entries.map((e) => '${e.key}=${e.value}');
      final metadataStr = metadataEntries.join('|');
      
      final fullContent = '$content||META:$metadataStr';
      
      final doc = Document(
        textContent: fullContent,
        embedding: embedding,
        createdAt: DateTime.now(),
        metadata: metadataStr,
      );
      
      final docId = _box.put(doc);
      final embeddingLength = embedding.length;
      _emit('📝 Added embedding for "$content" (ID: $docId, dims: $embeddingLength)');
    } catch (e) {
      _emit('❌ Failed to add embedding: $e');
      rethrow;
    }
  }

  Future<void> addTextWithEmbedding({
    required String content,
    required Map<String, dynamic> metadata,
  }) async {
    try {
      final maxLength = math.min(50, content.length);
      final preview = content.substring(0, maxLength);
      _emit('🧠 Generating embedding for: "$preview..."');
      
      final embedding = await generateEmbedding(content);
      
      final updatedMetadata = Map<String, dynamic>.from(metadata);
      updatedMetadata['content'] = content;
      
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await addEmbedding(
        id: 'auto_$timestamp',
        embedding: embedding,
        metadata: updatedMetadata,
      );
      
    } catch (e) {
      _emit('❌ Failed to add text with embedding: $e');
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> querySimilarEmbeddings({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.3,
  }) async {
    try {
      final query = _box.query().build();
      final docs = query.find();
      query.close();

      final docsLength = docs.length;
      _emit('🔍 Found $docsLength documents, calculating similarity');
      
      final results = <Map<String, Object?>>[];
      
      for (final doc in docs) {
        final parts = doc.textContent.split('||META:');
        final content = parts.isNotEmpty ? parts[0] : doc.textContent;
        final metadataStr = parts.length > 1 ? parts[1] : '';
        
        final metadata = <String, String>{};
        if (metadataStr.isNotEmpty) {
          final pairs = metadataStr.split('|');
          for (final pair in pairs) {
            final keyValue = pair.split('=');
            if (keyValue.length == 2) {
              metadata[keyValue[0]] = keyValue[1];
            }
          }
        }
        
        double score = 0.0;
        if (doc.embedding != null && doc.embedding!.isNotEmpty) {
          score = _cosineSimilarity(queryEmbedding, doc.embedding!);
        }
        
        if (score >= threshold) {
          final result = <String, Object?>{
            'id': doc.id,
            'document': content,
            'score': score,
            'metadata': metadata,
          };
          
          if (doc.createdAt != null) {
            result['created_at'] = doc.createdAt!.toIso8601String();
          }
          
          results.add(result);
        }
      }
      
      results.sort((a, b) {
        final scoreA = a['score'] as double;
        final scoreB = b['score'] as double;
        return scoreB.compareTo(scoreA);
      });
      
      final topResults = results.take(topK).toList();
      final resultCount = topResults.length;
      _emit('✅ Found $resultCount similar documents (threshold: $threshold)');
      return topResults;
    } catch (e) {
      _emit('❌ Vector search failed: $e');
      return [];
    }
  }

  Future<List<Map<String, Object?>>> queryText({
    required String queryText,
    required int topK,
    double threshold = 0.3,
  }) async {
    try {
      final maxLength = math.min(30, queryText.length);
      final preview = queryText.substring(0, maxLength);
      _emit('🔍 Searching for: "$preview..."');
      
      final queryEmbedding = await generateEmbedding(queryText);
      
      return await querySimilarEmbeddings(
        queryEmbedding: queryEmbedding,
        topK: topK,
        threshold: threshold,
      );
    } catch (e) {
      _emit('❌ Text query failed: $e');
      return [];
    }
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    
    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    
    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    
    if (normA == 0.0 || normB == 0.0) return 0.0;
    
    final norm = math.sqrt(normA) * math.sqrt(normB);
    return dotProduct / norm;
  }

  Future<List<Document>> getAllDocuments() async {
    try {
      final docs = _box.getAll();
      final docsLength = docs.length;
      _emit('📚 Retrieved $docsLength total documents');
      return docs;
    } catch (e) {
      _emit('❌ Failed to get documents: $e');
      return [];
    }
  }

  Future<void> clearAll() async {
    try {
      final count = _box.count();
      _box.removeAll();
      _emit('🗑️ Cleared $count documents from database');
    } catch (e) {
      _emit('❌ Failed to clear database: $e');
      rethrow;
    }
  }

  int getDocumentCount() {
    try {
      return _box.count();
    } catch (e) {
      return 0;
    }
  }

  Future<Map<String, dynamic>> getStats() async {
    try {
      final totalDocs = getDocumentCount();
      final allDocs = await getAllDocuments();
      
      final typeGroups = <String, int>{};
      int docsWithEmbeddings = 0;
      double averageEmbeddingDimensions = 0;
      
      for (final doc in allDocs) {
        if (doc.embedding != null && doc.embedding!.isNotEmpty) {
          docsWithEmbeddings++;
          averageEmbeddingDimensions += doc.embedding!.length;
        }
        
        final parts = doc.textContent.split('||META:');
        if (parts.length > 1) {
          final metadataStr = parts[1];
          String? type;
          final pairs = metadataStr.split('|');
          for (final pair in pairs) {
            final keyValue = pair.split('=');
            if (keyValue.length == 2 && keyValue[0] == 'type') {
              type = keyValue[1];
              break;
            }
          }
          final docType = type ?? 'unknown';
          final currentCount = typeGroups[docType] ?? 0;
          typeGroups[docType] = currentCount + 1;
        } else {
          final currentCount = typeGroups['unknown'] ?? 0;
          typeGroups['unknown'] = currentCount + 1;
        }
      }
      
      if (docsWithEmbeddings > 0) {
        averageEmbeddingDimensions /= docsWithEmbeddings;
      }
      
      final embeddingModel = _isModelLoaded ? 'mobilebert' : 'fallback';
      final vocabularySize = _vocab?.length ?? 0;
      
      return {
        'totalDocuments': totalDocs,
        'documentsWithEmbeddings': docsWithEmbeddings,
        'typeDistribution': typeGroups,
        'averageEmbeddingDimensions': averageEmbeddingDimensions.round(),
        'embeddingModel': embeddingModel,
        'vocabularySize': vocabularySize,
        'maxSequenceLength': maxSequenceLength,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<String> getConversationContext({
    required String currentQuery,
    int maxResults = 3,
    double threshold = 0.4,
  }) async {
    try {
      final results = await queryText(
        queryText: currentQuery,
        topK: maxResults,
        threshold: threshold,
      );
      
      if (results.isEmpty) {
        return 'No relevant conversation history found.';
      }
      
      final contextParts = <String>[];
      for (final result in results) {
        final score = result['score'] as double;
        final scorePercent = (score * 100).round();
        final content = result['document']?.toString() ?? '';
        
        contextParts.add('[$scorePercent% match] $content');
      }
      
      final context = contextParts.join('\n');
      return 'Recent conversation context:\n$context';
    } catch (e) {
      _emit('❌ Failed to get conversation context: $e');
      return 'Error retrieving conversation context.';
    }
  }

  Future<void> addSampleData() async {
    final sampleTexts = [
      'I am wearing Frame smart glasses and looking at a beautiful sunset',
      'The weather today is very nice and sunny',
      'I need help with understanding machine learning concepts',
      'Frame glasses are amazing for augmented reality applications',
      'MobileBERT is very helpful for generating text embeddings locally',
      'I am learning about vector databases and similarity search',
      'Computer vision and natural language processing are fascinating',
      'Offline AI models provide better privacy and faster response times',
    ];
    
    for (int i = 0; i < sampleTexts.length; i++) {
      final timestamp = DateTime.now().toIso8601String();
      await addTextWithEmbedding(
        content: sampleTexts[i],
        metadata: {
          'type': 'sample',
          'index': i.toString(),
          'timestamp': timestamp,
          'source': 'sample_data_generator',
        },
      );
      
      await Future.delayed(const Duration(milliseconds: 200));
    }
    
    final sampleCount = sampleTexts.length;
    _emit('📝 Added $sampleCount sample documents with MobileBERT embeddings');
  }

  Future<void> testModel() async {
    try {
      _emit('🧪 Testing MobileBERT model...');
      
      final testText = 'This is a test sentence for MobileBERT embedding generation.';
      final embedding = await generateEmbedding(testText);
      
      final embeddingLength = embedding.length;
      _emit('✅ Model test successful: $embeddingLength dimensions');
      
      final sampleValues = embedding.take(5).map((v) => v.toStringAsFixed(4)).join(', ');
      _emit('📊 Sample embedding values: [$sampleValues...]');
      
    } catch (e) {
      _emit('❌ Model test failed: $e');
    }
  }
}