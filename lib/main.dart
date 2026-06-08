import 'package:flutter/material.dart';
import 'package:flutter_notifications/core/services/notification_service.dart';
import 'package:flutter_notifications/domain/enums/app_notification_channel.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

final NotificationService _notificationService = NotificationService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _notificationService.init();

  _notificationService.onTap.listen((payload) {
    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => NotificationDetailScreen(payload: payload),
      ),
    );
  });

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      home: HomePage(notificationService: _notificationService),
    );
  }
}

// ── Home Page ──────────────────────────────────────────────────────────────

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.notificationService});

  final NotificationService notificationService;

  Future<void> _scheduleNotification(BuildContext context) async {
    final granted = await notificationService.requestPermissions();

    if (!granted) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Notification permission denied. Enable it in Settings.',
          ),
        ),
      );
      return;
    }

    await notificationService.scheduleReminder(
      id: 1,
      fireAt: DateTime.now().add(const Duration(seconds: 10)),
      title: 'Hello from Flutter! 👋',
      body: 'Your notification is working perfectly.',
      channel: AppNotificationChannel.reminders,
      payload: 'notification_tapped',
    );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Notification scheduled — check back in 10 seconds!'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Demo')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => _scheduleNotification(context),
          child: const Text('Schedule Notification'),
        ),
      ),
    );
  }
}

// ── Notification Detail Screen ─────────────────────────────────────────────

class NotificationDetailScreen extends StatelessWidget {
  const NotificationDetailScreen({super.key, required this.payload});

  final String? payload;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Tapped')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.notifications_active, size: 64),
            const SizedBox(height: 24),
            const Text(
              'You tapped the notification!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            if (payload != null) ...[
              const SizedBox(height: 12),
              Text(
                'Payload: $payload',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
