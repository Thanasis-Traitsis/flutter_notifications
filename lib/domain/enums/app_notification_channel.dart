import 'package:flutter_local_notifications/flutter_local_notifications.dart';

enum AppNotificationChannel {
  reminders(
    id: 'reminders',
    name: 'Reminders',
    description: 'Scheduled reminders from the app.',
    importance: Importance.high,
  );

  const AppNotificationChannel({
    required this.id,
    required this.name,
    required this.description,
    required this.importance,
  });

  final String id;
  final String name;
  final String description;
  final Importance importance;
}