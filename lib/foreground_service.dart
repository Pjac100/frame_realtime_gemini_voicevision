import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';

final _log = Logger('ForegroundService');

/// One-time plugin setup – call from `main()` **before** runApp().
void initializeForegroundService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'Frame Service',
      channelDescription:
          'Keeps Frame connected while streaming voice & vision data.',
      channelImportance: NotificationChannelImportance.MIN,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    // `isOnceEvent` was removed → use the *once* helper.
    foregroundTaskOptions: const ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.once(),
    ),
  );
}

/// Start (or restart) the Android foreground service.
Future<ServiceRequestResult> startForegroundService() async {
  if (await FlutterForegroundTask.isRunningService) {
    return FlutterForegroundTask.restartService();
  }

  return FlutterForegroundTask.startService(
    serviceId: 256,
    serviceTypes: [
      ForegroundServiceTypes.dataSync,
      ForegroundServiceTypes.remoteMessaging,
    ],
    notificationTitle: 'Frame realtime assistant',
    notificationText: 'Processing voice & vision data',
    notificationIcon: null,
    notificationButtons: [
      const NotificationButton(id: 'stop', text: 'Stop'),
    ],
    callback: _startForegroundCallback,
  );
}

@pragma('vm:entry-point')
void _startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_FrameTaskHandler());
}

class _FrameTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log.info(
        'FG-service started ${timestamp.toLocal()} (starter: ${starter.name})');
  }

  // With `eventAction.once()` this is not used, but keep for future updates.
  @override
  void onRepeatEvent(DateTime timestamp) =>
      _log.fine('FG repeat @ ${timestamp.toLocal()}');

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log.info('FG-service destroyed (timeout=$isTimeout)');
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') FlutterForegroundTask.stopService();
  }
}
