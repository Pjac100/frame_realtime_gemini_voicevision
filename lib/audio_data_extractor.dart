import 'dart:convert';
import 'dart:typed_data';

class AudioDataExtractor {
  /// Extracts base64-encoded audio data from the JSON message and returns it as a List of Uint8List
  /// Returns null if the message is invalid or contains no audio data
  static List<Uint8List>? extractAudioData(Map<String, dynamic> json) {
    try {
      // Navigate through the JSON structure
      final modelTurn = json['serverContent']?['modelTurn'];
      if (modelTurn == null) return null;

      final parts = modelTurn['parts'] as List?;
      if (parts == null) return null;

      // Extract and decode audio data
      List<Uint8List> audioDataList = [];

      for (var part in parts) {
        if (part is Map<String, dynamic> &&
            part['inlineData'] is Map<String, dynamic>) {
          final inlineData = part['inlineData'] as Map<String, dynamic>;

          if (inlineData['mimeType']?.toString().startsWith('audio/') == true &&
              inlineData['data'] != null) {
            try {
              final Uint8List decoded = base64Decode(inlineData['data']);
              audioDataList.add(decoded);
            } catch (e) {
              print('Error decoding base64 data: $e');
              // Continue to next part if this one fails
              continue;
            }
          }
        }
      }

      return audioDataList.isEmpty ? null : audioDataList;
    } catch (e) {
      print('Error parsing message: $e');
      return null;
    }
  }
}
