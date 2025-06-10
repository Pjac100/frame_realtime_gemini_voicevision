import 'package:flutter/services.dart';

/// A tokenizer for BERT-based models like MobileBERT.
/// It handles loading the vocabulary and converting strings into the format
/// required by the model (input_ids, attention_mask, token_type_ids).
class BertTokenizer {
  final Map<String, int> _vocabulary;
  final int _maxLength;

  BertTokenizer._(this._vocabulary, this._maxLength);

  /// Creates and initializes the tokenizer by loading the vocabulary from assets.
  static Future<BertTokenizer> create(
      {required String vocabPath, required int maxLength}) async {
    final vocabContent = await rootBundle.loadString(vocabPath);
    final vocabList = vocabContent.split('\n');
    final Map<String, int> vocabulary = {};
    for (int i = 0; i < vocabList.length; i++) {
      vocabulary[vocabList[i]] = i;
    }
    return BertTokenizer._(vocabulary, maxLength);
  }

  /// Tokenizes the input text and returns a map of model inputs.
  Map<String, List<int>> tokenize(String text) {
    // Basic text processing
    text = text.toLowerCase();

    // Use WordPiece tokenization
    final tokens = _wordpieceTokenize(text);

    // Truncate if necessary
    if (tokens.length > _maxLength - 2) {
      tokens.removeRange(_maxLength - 2, tokens.length);
    }

    // Add special tokens [CLS] and [SEP]
    final allTokens = ['[CLS]', ...tokens, '[SEP]'];

    // Convert tokens to IDs
    final inputIds = allTokens
        .map((token) => _vocabulary[token] ?? _vocabulary['[UNK]']!)
        .toList();

    // Create attention mask (1 for real tokens, 0 for padding)
    final attentionMask = List<int>.filled(inputIds.length, 1);

    // Pad sequences to max length
    final paddingLength = _maxLength - inputIds.length;
    if (paddingLength > 0) {
      inputIds.addAll(List<int>.filled(paddingLength, 0));
      attentionMask.addAll(List<int>.filled(paddingLength, 0));
    }

    // For single-sentence tasks, token_type_ids are all 0.
    final tokenTypeIds = List<int>.filled(_maxLength, 0);

    return {
      'input_ids': inputIds,
      'attention_mask': attentionMask,
      'token_type_ids': tokenTypeIds,
    };
  }

  /// Implements the WordPiece tokenization algorithm.
  List<String> _wordpieceTokenize(String text) {
    final outputTokens = <String>[];
    final words = text.split(' ');

    for (final word in words) {
      String currentWord = word;
      final wordTokens = <String>[];
      while (currentWord.isNotEmpty) {
        String? bestSubword;
        int bestSubwordLength = 0;
        for (int i = 1; i <= currentWord.length; i++) {
          final subword =
              (wordTokens.isNotEmpty ? '##' : '') + currentWord.substring(0, i);
          if (_vocabulary.containsKey(subword) &&
              subword.length > bestSubwordLength) {
            bestSubword = subword;
            bestSubwordLength = subword.length;
          }
        }

        if (bestSubword == null) {
          wordTokens.add('[UNK]');
          break;
        }

        wordTokens.add(bestSubword);
        currentWord =
            currentWord.substring(bestSubword.replaceAll('##', '').length);
      }
      outputTokens.addAll(wordTokens);
    }
    return outputTokens;
  }
}
