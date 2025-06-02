import 'dart:typed_data';

class AudioUpsampler {
  /// Upsamples PCM16 audio data from 8kHz to 16kHz using linear interpolation
  /// Input should be a Uint8List containing PCM16 audio data at 8kHz
  /// Returns a Uint8List containing the upsampled PCM16 audio data at 16kHz
  static Uint8List upsample8kTo16k(Uint8List input) {
    // Convert input bytes to Int16List for easier sample manipulation
    Int16List inputSamples = Int16List.view(input.buffer);

    // Calculate output size (2x input since we're going from 8kHz to 16kHz)
    Int16List outputSamples = Int16List(inputSamples.length * 2);

    // Process each sample
    for (int i = 0; i < inputSamples.length - 1; i++) {
      int currentSample = inputSamples[i];
      int nextSample = inputSamples[i + 1];

      // Calculate interpolated values
      outputSamples[i * 2] = currentSample;
      outputSamples[i * 2 + 1] =
          currentSample + ((nextSample - currentSample) ~/ 2);
    }

    // Handle the last sample
    outputSamples[outputSamples.length - 2] = inputSamples.last;
    outputSamples[outputSamples.length - 1] = inputSamples.last;

    // Convert back to Uint8List
    return Uint8List.view(outputSamples.buffer);
  }
}
