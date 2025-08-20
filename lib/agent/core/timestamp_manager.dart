import 'dart:typed_data';
import 'stream_observer.dart';

/// Manages timestamp correlation between ASR/OCR outputs and images
/// This is critical for associating agent outputs with the correct visual context
class TimestampManager {
  final void Function(String)? _logger;
  
  // Correlation windows
  static const Duration defaultCorrelationWindow = Duration(seconds: 2);
  static const Duration extendedCorrelationWindow = Duration(seconds: 5);
  
  TimestampManager({void Function(String)? logger}) : _logger = logger;

  /// Correlate ASR/OCR output timestamp with available photos
  /// Returns all photos that were captured within the correlation window
  List<TimestampedData<Uint8List>> correlateWithPhotos({
    required DateTime outputTimestamp,
    required List<TimestampedData<Uint8List>> availablePhotos,
    Duration? customWindow,
  }) {
    final window = customWindow ?? defaultCorrelationWindow;
    
    final correlatedPhotos = availablePhotos.where((photo) => 
      photo.isWithinWindow(outputTimestamp, window)
    ).toList();
    
    // Sort by proximity to the output timestamp
    correlatedPhotos.sort((a, b) {
      final aDiff = outputTimestamp.difference(a.timestamp).abs();
      final bDiff = outputTimestamp.difference(b.timestamp).abs();
      return aDiff.compareTo(bDiff);
    });
    
    _logger?.call('🔗 Correlated ${correlatedPhotos.length} photos with output at $outputTimestamp');
    
    return correlatedPhotos;
  }

  /// Find the best photo match for a given timestamp
  /// Returns the photo closest in time to the target timestamp within the window
  TimestampedData<Uint8List>? findBestPhotoMatch({
    required DateTime targetTimestamp,
    required List<TimestampedData<Uint8List>> availablePhotos,
    Duration? customWindow,
  }) {
    final correlatedPhotos = correlateWithPhotos(
      outputTimestamp: targetTimestamp,
      availablePhotos: availablePhotos,
      customWindow: customWindow,
    );
    
    return correlatedPhotos.isNotEmpty ? correlatedPhotos.first : null;
  }

  /// Create a temporal window around a center timestamp
  /// Useful for querying data within a specific time range
  TemporalWindow createWindow({
    required DateTime centerTime,
    Duration? windowSize,
  }) {
    final window = windowSize ?? defaultCorrelationWindow;
    final halfWindow = Duration(milliseconds: window.inMilliseconds ~/ 2);
    
    return TemporalWindow(
      startTime: centerTime.subtract(halfWindow),
      endTime: centerTime.add(halfWindow),
      centerTime: centerTime,
    );
  }

  /// Analyze temporal relationships between multiple timestamped events
  /// Useful for understanding the sequence and timing of agent operations
  TemporalAnalysis analyzeTimings(List<DateTime> timestamps) {
    if (timestamps.isEmpty) {
      return TemporalAnalysis.empty();
    }
    
    final sortedTimestamps = List<DateTime>.from(timestamps)..sort();
    
    final intervals = <Duration>[];
    for (int i = 1; i < sortedTimestamps.length; i++) {
      intervals.add(sortedTimestamps[i].difference(sortedTimestamps[i - 1]));
    }
    
    final totalDuration = sortedTimestamps.last.difference(sortedTimestamps.first);
    
    Duration? averageInterval;
    if (intervals.isNotEmpty) {
      final totalMs = intervals.fold<int>(0, (sum, interval) => sum + interval.inMilliseconds);
      averageInterval = Duration(milliseconds: totalMs ~/ intervals.length);
    }
    
    return TemporalAnalysis(
      firstTimestamp: sortedTimestamps.first,
      lastTimestamp: sortedTimestamps.last,
      totalDuration: totalDuration,
      eventCount: timestamps.length,
      averageInterval: averageInterval,
      intervals: intervals,
    );
  }

  /// Generate a correlation report for debugging and monitoring
  CorrelationReport generateCorrelationReport({
    required List<DateTime> asrTimestamps,
    required List<DateTime> ocrTimestamps,
    required List<TimestampedData<Uint8List>> availablePhotos,
  }) {
    final photoTimestamps = availablePhotos.map((p) => p.timestamp).toList();
    
    int asrPhotoCorrelations = 0;
    int ocrPhotoCorrelations = 0;
    
    // Count successful correlations
    for (final asrTime in asrTimestamps) {
      final correlatedPhotos = correlateWithPhotos(
        outputTimestamp: asrTime,
        availablePhotos: availablePhotos,
      );
      if (correlatedPhotos.isNotEmpty) asrPhotoCorrelations++;
    }
    
    for (final ocrTime in ocrTimestamps) {
      final correlatedPhotos = correlateWithPhotos(
        outputTimestamp: ocrTime,
        availablePhotos: availablePhotos,
      );
      if (correlatedPhotos.isNotEmpty) ocrPhotoCorrelations++;
    }
    
    return CorrelationReport(
      asrEventCount: asrTimestamps.length,
      ocrEventCount: ocrTimestamps.length,
      photoCount: availablePhotos.length,
      asrPhotoCorrelations: asrPhotoCorrelations,
      ocrPhotoCorrelations: ocrPhotoCorrelations,
      asrTimingAnalysis: analyzeTimings(asrTimestamps),
      ocrTimingAnalysis: analyzeTimings(ocrTimestamps),
      photoTimingAnalysis: analyzeTimings(photoTimestamps),
      correlationWindow: defaultCorrelationWindow,
    );
  }
}

/// Represents a temporal window for correlation queries
class TemporalWindow {
  final DateTime startTime;
  final DateTime endTime;
  final DateTime centerTime;
  
  const TemporalWindow({
    required this.startTime,
    required this.endTime,
    required this.centerTime,
  });

  /// Check if a timestamp falls within this window
  bool contains(DateTime timestamp) {
    return timestamp.isAfter(startTime) && timestamp.isBefore(endTime);
  }

  /// Get the duration of this window
  Duration get duration => endTime.difference(startTime);

  @override
  String toString() => 'TemporalWindow(${startTime} - ${endTime}, center: ${centerTime})';
}

/// Analysis of temporal relationships between timestamped events
class TemporalAnalysis {
  final DateTime? firstTimestamp;
  final DateTime? lastTimestamp;
  final Duration totalDuration;
  final int eventCount;
  final Duration? averageInterval;
  final List<Duration> intervals;
  
  const TemporalAnalysis({
    required this.firstTimestamp,
    required this.lastTimestamp,
    required this.totalDuration,
    required this.eventCount,
    required this.averageInterval,
    required this.intervals,
  });
  
  factory TemporalAnalysis.empty() {
    return const TemporalAnalysis(
      firstTimestamp: null,
      lastTimestamp: null,
      totalDuration: Duration.zero,
      eventCount: 0,
      averageInterval: null,
      intervals: [],
    );
  }

  /// Get the frequency of events (events per second)
  double? get frequency {
    if (eventCount <= 1 || totalDuration.inMilliseconds == 0) return null;
    return (eventCount - 1) / (totalDuration.inMilliseconds / 1000.0);
  }

  @override
  String toString() {
    final freqStr = frequency?.toStringAsFixed(2) ?? 'N/A';
    final avgStr = averageInterval?.inMilliseconds.toString() ?? 'N/A';
    return 'TemporalAnalysis(events: $eventCount, duration: ${totalDuration.inSeconds}s, '
           'frequency: $freqStr Hz, avgInterval: $avgStr ms)';
  }
}

/// Comprehensive report on timestamp correlations
class CorrelationReport {
  final int asrEventCount;
  final int ocrEventCount;
  final int photoCount;
  final int asrPhotoCorrelations;
  final int ocrPhotoCorrelations;
  final TemporalAnalysis asrTimingAnalysis;
  final TemporalAnalysis ocrTimingAnalysis;
  final TemporalAnalysis photoTimingAnalysis;
  final Duration correlationWindow;
  
  const CorrelationReport({
    required this.asrEventCount,
    required this.ocrEventCount,
    required this.photoCount,
    required this.asrPhotoCorrelations,
    required this.ocrPhotoCorrelations,
    required this.asrTimingAnalysis,
    required this.ocrTimingAnalysis,
    required this.photoTimingAnalysis,
    required this.correlationWindow,
  });

  /// Calculate correlation success rates
  double get asrCorrelationRate {
    return asrEventCount > 0 ? asrPhotoCorrelations / asrEventCount : 0.0;
  }
  
  double get ocrCorrelationRate {
    return ocrEventCount > 0 ? ocrPhotoCorrelations / ocrEventCount : 0.0;
  }
  
  double get overallCorrelationRate {
    final totalEvents = asrEventCount + ocrEventCount;
    final totalCorrelations = asrPhotoCorrelations + ocrPhotoCorrelations;
    return totalEvents > 0 ? totalCorrelations / totalEvents : 0.0;
  }

  /// Generate a summary string for logging
  String generateSummary() {
    final asrRate = (asrCorrelationRate * 100).toStringAsFixed(1);
    final ocrRate = (ocrCorrelationRate * 100).toStringAsFixed(1);
    final overallRate = (overallCorrelationRate * 100).toStringAsFixed(1);
    
    return 'Correlation Report:\n'
           '  ASR: $asrEventCount events, $asrPhotoCorrelations correlated ($asrRate%)\n'
           '  OCR: $ocrEventCount events, $ocrPhotoCorrelations correlated ($ocrRate%)\n'
           '  Photos: $photoCount available\n'
           '  Overall: $overallRate% correlation rate\n'
           '  Window: ${correlationWindow.inMilliseconds}ms\n'
           '  ASR Timing: $asrTimingAnalysis\n'
           '  OCR Timing: $ocrTimingAnalysis\n'
           '  Photo Timing: $photoTimingAnalysis';
  }
}