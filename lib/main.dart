import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'screens/home_screen.dart';
import 'services/proxy_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Request POST_NOTIFICATIONS permission for Android 13+ (API 33+).
  // Must be called after engine init but while Activity is in foreground.
  await _requestNotificationPermission();

  try {
    await initializeBackgroundService();
  } catch (e) {
    debugPrint('Background service init failed: $e');
    // Don't crash the app if the background service fails to initialize.
    // The app is still functional without it — tunnels work, just no
    // persistent notification / boot auto-start.
  }
  runApp(
    ChangeNotifierProvider(
      create: (_) {
        // API server lives in the background service isolate so it
        // survives when Android kills the UI (e.g. user switches to Termux).
        final svc = ProxyService(startApi: false);
        final bgService = FlutterBackgroundService();

        // Wire up notification updates when tunnel count changes
        svc.onTunnelCountChanged = (count) {
          bgService.invoke('updateNotification', {
            'content': count > 0
                ? '$count tunnel${count == 1 ? '' : 's'} active'
                : 'No active tunnels — API ready',
          });
        };

        // Wire up notification updates for API server readiness
        svc.onNotificationUpdate = (content) {
          bgService.invoke('updateNotification', {
            'content': content,
          });
        };

        return svc;
      },
      child: const MyApp(),
    ),
  );
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundServiceStart,
      autoStart: false,
      isForegroundMode: true,
      // The notification channel 'ssh_proxy_channel' is created natively
      // in MainActivity.kt before Flutter starts. This is required because
      // flutter_background_service does NOT auto-create custom channels —
      // only its default 'FOREGROUND_DEFAULT' channel is auto-created.
      // Without pre-creating the channel → crash on Android 8+ (API 26+).
      notificationChannelId: 'ssh_proxy_channel',
      initialNotificationTitle: 'SSH Proxy Manager',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
      autoStartOnBoot: true,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onBackgroundServiceStart,
      onBackground: onIosBackground,
    ),
  );
  await service.startService();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onBackgroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();

    service.on('updateNotification').listen((data) {
      if (data != null) {
        service.setForegroundNotificationInfo(
          title: 'SSH Proxy Manager',
          content: data['content'] ?? 'Running',
        );
      }
    });
  }

  service.on('stop').listen((_) {
    service.stopSelf();
  });

  // Start ProxyService WITH the API server in the background isolate.
  // This isolate survives when Android kills the UI activity (e.g. user
  // switches to Termux), so the HTTP API remains reachable.
  final bgProxyService = ProxyService(startApi: true);

  // Wire up notification updates from the background ProxyService
  bgProxyService.onTunnelCountChanged = (count) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'SSH Proxy Manager',
        content: count > 0
            ? '$count tunnel${count == 1 ? '' : 's'} active'
            : 'No active tunnels — API ready',
      );
    }
  };

  bgProxyService.onNotificationUpdate = (content) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'SSH Proxy Manager',
        content: content,
      );
    }
  };

  // Keep alive timer — periodically signal that service is alive
  Timer.periodic(const Duration(seconds: 30), (timer) {
    service.invoke('healthCheck');
  });
}

/// Request POST_NOTIFICATIONS permission via platform channel.
/// On Android <13 or non-Android platforms, this is a no-op.
Future<void> _requestNotificationPermission() async {
  try {
    const platform = MethodChannel('com.clawd.sshproxy/permissions');
    await platform.invokeMethod('requestNotificationPermission');
  } catch (e) {
    // Expected to fail on iOS, desktop, or when running in background isolate.
    debugPrint('Notification permission request: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH Proxy Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
