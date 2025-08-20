import 'dart:async';
import 'dart:typed_data';

/// Non-blocking stream observer that taps into existing streams without disrupting the main pipeline
/// This is the foundation for read-only agent integration
class StreamObserver<T> {
  late final StreamController<TimestampedData<T>> _controller;
  StreamSubscription<T>? _subscription;
  bool _isActive = false;
  final void Function(String)? _logger;
  
  StreamObserver({void Function(String)? logger}) : _logger = logger {
    _controller = StreamController<TimestampedData<T>>.broadcast();
  }

  /// Observe a stream without affecting it
  /// The original stream continues unchanged while we get a copy of all data
  void observe(Stream<T> originalStream, {String? streamName}) {
    if (_isActive) {
      _logger?.call('⚠️ StreamObserver already active for ${streamName ?? "unknown"}');
      return;
    }
    
    _logger?.call('👁️ Starting stream observation for ${streamName ?? "unknown"}');
    _isActive = true;
    
    // Listen to the original stream and emit timestamped copies
    _subscription = originalStream.listen(
      (data) {
        if (_isActive) {
          final timestampedData = TimestampedData<T>(
            data: data,
            timestamp: DateTime.now(),
          );
          _controller.add(timestampedData);
        }
      },
      onError: (error) {
        _logger?.call('❌ Stream observation error for ${streamName ?? "unknown"}: $error');
        _controller.addError(error);
      },
      onDone: () {
        _logger?.call('✅ Stream observation completed for ${streamName ?? "unknown"}');
        _isActive = false;
      },
    );
  }

  /// Get the observed stream with timestamps
  Stream<TimestampedData<T>> get observedStream => _controller.stream;

  /// Stop observing (won't affect the original stream)
  void stopObserving({String? streamName}) {
    if (!_isActive) return;
    
    _logger?.call('⏹️ Stopping stream observation for ${streamName ?? "unknown"}');
    _isActive = false;
    _subscription?.cancel();
    _subscription = null;
  }

  /// Check if currently observing
  bool get isObserving => _isActive;

  /// Dispose resources
  void dispose() {
    stopObserving();
    _controller.close();
  }
}

/// Data with precise timestamp for correlation
class TimestampedData<T> {
  final T data;
  final DateTime timestamp;
  
  const TimestampedData({
    required this.data,
    required this.timestamp,
  });

  /// Get milliseconds since epoch for precise timing
  int get timestampMs => timestamp.millisecondsSinceEpoch;
  
  /// Check if this data is within a time window of another timestamp
  bool isWithinWindow(DateTime other, Duration window) {
    final difference = timestamp.difference(other).abs();
    return difference <= window;
  }

  @override
  String toString() => 'TimestampedData(timestamp: $timestamp, dataType: ${T.runtimeType})';
}

/// Specialized observer for audio streams (PCM16 data)
class AudioStreamObserver extends StreamObserver<Uint8List> {
  int _totalPacketsObserved = 0;
  int _totalBytesObserved = 0;
  
  AudioStreamObserver({super.logger});

  @override
  void observe(Stream<Uint8List> originalStream, {String? streamName}) {
    super.observe(originalStream, streamName: streamName ?? 'Audio');
    
    // Track audio statistics
    observedStream.listen((timestampedAudio) {
      _totalPacketsObserved++;
      _totalBytesObserved += timestampedAudio.data.length;
      
      // Log statistics periodically (every 100 packets)
      if (_totalPacketsObserved % 100 == 0) {
        final kbObserved = (_totalBytesObserved / 1024).toStringAsFixed(1);
        _logger?.call('📊 Audio observed: $_totalPacketsObserved packets, ${kbObserved}KB');
      }
    });
  }

  /// Get audio observation statistics  
  Map<String, dynamic> get statistics => {
    'totalPackets': _totalPacketsObserved,
    'totalBytes': _totalBytesObserved,
    'isObserving': isObserving,
  };
}

/// Specialized observer for photo streams (JPEG data)
class PhotoStreamObserver extends StreamObserver<Uint8List> {
  int _totalPhotosObserved = 0;
  final List<TimestampedData<Uint8List>> _recentPhotos = [];
  static const int _maxRecentPhotos = 10;
  
  PhotoStreamObserver({super.logger});

  @override
  void observe(Stream<Uint8List> originalStream, {String? streamName}) {
    super.observe(originalStream, streamName: streamName ?? 'Photo');
    
    // Track photo captures
    observedStream.listen((timestampedPhoto) {
      _totalPhotosObserved++;
      
      // Keep recent photos for temporal correlation
      _recentPhotos.add(timestampedPhoto);
      if (_recentPhotos.length > _maxRecentPhotos) {
        _recentPhotos.removeAt(0);
      }
      
      final photoSizeKb = (timestampedPhoto.data.length / 1024).toStringAsFixed(1);
      _logger?.call('📸 Photo observed: ${photoSizeKb}KB at ${timestampedPhoto.timestamp}');
    });
  }

  /// Get photos captured within a time window
  List<TimestampedData<Uint8List>> getPhotosInWindow(DateTime centerTime, Duration window) {
    return _recentPhotos.where((photo) => 
      photo.isWithinWindow(centerTime, window)
    ).toList();
  }

  /// Get the most recent photo
  TimestampedData<Uint8List>? get latestPhoto => 
    _recentPhotos.isNotEmpty ? _recentPhotos.last : null;

  /// Get photo observation statistics
  Map<String, dynamic> get statistics => {
    'totalPhotos': _totalPhotosObserved,
    'recentPhotosCount': _recentPhotos.length,
    'isObserving': isObserving,
  };
}

/// Manager for coordinating multiple stream observers
class StreamObserverManager {
  final AudioStreamObserver audioObserver;
  final PhotoStreamObserver photoObserver;
  final void Function(String)? _logger;
  bool _isActive = false;

  StreamObserverManager({void Function(String)? logger})
    : audioObserver = AudioStreamObserver(logger: logger),
      photoObserver = PhotoStreamObserver(logger: logger),
      _logger = logger;

  /// Start observing both audio and photo streams
  void startObserving({
    required Stream<Uint8List> audioStream,
    required Stream<Uint8List> photoStream,
  }) {
    if (_isActive) {
      _logger?.call('⚠️ StreamObserverManager already active');
      return;
    }
    
    _logger?.call('🚀 Starting multi-stream observation for agent');
    _isActive = true;
    
    audioObserver.observe(audioStream, streamName: 'FrameAudio');
    photoObserver.observe(photoStream, streamName: 'FramePhoto');
    
    _logger?.call('✅ Multi-stream observation started');
  }

  /// Stop all observations
  void stopObserving() {
    if (!_isActive) return;
    
    _logger?.call('⏹️ Stopping multi-stream observation');
    _isActive = false;
    
    audioObserver.stopObserving(streamName: 'FrameAudio');
    photoObserver.stopObserving(streamName: 'FramePhoto');
    
    _logger?.call('✅ Multi-stream observation stopped');
  }

  /// Get combined observation statistics
  Map<String, dynamic> get combinedStatistics => {
    'isActive': _isActive,
    'audio': audioObserver.statistics,
    'photo': photoObserver.statistics,
  };

  /// Check if actively observing
  bool get isObserving => _isActive;

  /// Dispose all resources
  void dispose() {
    stopObserving();
    audioObserver.dispose();
    photoObserver.dispose();
  }
}