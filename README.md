![Banner](https://github.com/Thanasis-Traitsis/flutter_notifications/blob/main/assets/Building%20Local%20Notifications%20%20in%20Flutter...Properly.jpg?raw=true)

Have you ever added local notifications to a Flutter app and felt like you were just... copying lines without really knowing what you were doing? `flutter_local_notifications`, a manifest entry, a permission request, a scheduled call. It works. Sometimes. On some devices. With some Android versions. And when it doesn't, **you have no idea why**.

I've been there too. Recently, while working on a side project of mine called [My Eyes](https://github.com/Thanasis-Traitsis/my_eyes_flutter) (an optical health tracker), I wanted to remind users to replace their contact lenses a few days before expiry. Sounded simple. *Schedule a notification 27 days from now,* done. But the more I dug into it, the more I realized I didn't actually understand any of it. What does the operating system do with that schedule? Why are there three different permissions on Android and they all look similar? What's the difference between a "notification" and a "channel"? Why does the package force me to use `TZDateTime` instead of a normal `DateTime`?

So I went down the rabbit hole. And the deeper I went, the more I realized that most notification tutorials out there don't really teach you how notifications work. They teach you how to copy-paste the API. That's not enough. Because the moment something goes wrong, and trust me, it will, you need the mental model to debug it. This article is the long-form version of everything I learned. We're going to cover the **local notification system in Flutter**, from the very first moment your app says *"hey OS, I want to schedule this"* to the moment the user taps the notification and lands inside your app. We will talk about the native side, the permissions, the channels, the payloads, the architecture, the tests. Everything.

One thing to set straight upfront. **There are two kinds of notifications:** local (scheduled by your app, fired by the device, no internet needed) and remote/push (sent from a server through FCM or APNs). **Today we're only covering local.** Push deserves its own deep dive, and I'll write that one as a part 2. So if you came here for backend-triggered notifications, the foundation we lay today will make that follow-up much easier. But the post itself is 100% local.

Here's everything we're going to cover in this article:

1. [**How Local Notifications Actually Work**](#section-1-how-local-notifications-actually-work) — the mental model every Flutter developer needs before writing a single line
2. [**The Three Packages and Why Each One Exists**](#section-2-the-three-packages-and-why-each-one-exists) — why you need all three, not just one
3. [**Permissions: What Each One Actually Does**](#section-3-permissions-what-each-one-actually-does) — the two gates most tutorials only half-explain
4. [**Channels: Giving Users Control Over What They Hear**](#section-4-channels-giving-users-control-over-what-they-hear) — Android 8+ and what iOS does instead
5. [**Designing the NotificationService**](#section-5-designing-the-notificationservice) — **this is where the code starts. If you're already comfortable with the concepts, jump straight here.**
6. [**Wiring It Up: Inside init()**](#section-6-wiring-it-up-inside-init) — the startup sequence that has to run before anything else
7. [**Scheduling, Payloads, and Cancelling**](#section-7-scheduling-payloads-and-cancelling) — the three methods that make the whole thing work
8. [**The Tap: Where the Stream Earns Its Keep**](#section-8-the-tap-where-the-stream-earns-its-keep) — handling taps across all three app states

You know me by now... we're not just going to make it work. We're going to understand **why** it works **the way** it does. Let's begin.

![Notification GIF](https://github.com/Thanasis-Traitsis/flutter_notifications/blob/main/assets/notification.gif?raw=true)

## Section 1: How Local Notifications Actually Work

Before we touch a single line of code, we need to clear up the biggest misconception most Flutter developers have about notifications. And it's not a small one. It's the kind that, once you understand it, you are truly aware about the code you write. Most developers think the notification system works like a timer running inside their app. You schedule something, your code waits, the time arrives, your code fires the notification. Simple, right?

**That's not what happens at all.**

When you "schedule a notification," your app doesn't keep track of anything. It doesn't wait. It doesn't hold a timer. What it actually does is **hand a piece of paper to the operating system** and walk away. That paper says: *"Hey OS, please show this text, with this title, at this exact moment in time, with this sound, with this icon. Here's an ID in case I need to cancel it later. Thanks."*

![Notification Paper-Note](https://github.com/Thanasis-Traitsis/flutter_notifications/blob/main/assets/paper_note.png?raw=true)

And then your app is done. The OS takes the paper, files it in its own internal scheduler, and your app has zero responsibility from that point on.

#### Wait...so the OS is doing all the work?
Yes. Exactly that. Both Android and iOS have a **system-level service** that runs continuously in the background, owned by the operating system itself, not by any individual app. On Android it's called `AlarmManager`. On iOS it's `UNUserNotificationCenter`. These services are running on your phone right now, holding scheduled notifications for dozens of apps you've installed.

When the scheduled moment arrives, the OS looks at its internal list, sees that something is due to fire, and displays the notification. **Your app doesn't even need to be running.** It can be killed. It can be in the background for hours. The phone can be on airplane mode. None of it matters. The OS is the one with the alarm clock, not your code.

#### So what does our app actually do?
Three things, and only three things:
1. **Tell the OS what to schedule** (the title, body, time, icon, sound, payload, etc.).
2. **Tell the OS to cancel something** previously scheduled, using the ID we gave it.
3. **React to taps** when the user opens a notification and lands inside our app.

#### The bridge between Dart and the OS
Now here's the obvious question: *how does our Dart code talk to a native OS service?*

Dart doesn't speak `AlarmManager`. It doesn't speak `UNUserNotificationCenter`. These are native APIs, written in Kotlin/Java on Android and Swift/Objective-C on iOS. So we need a translator. Something that takes our Dart instructions and turns them into the right native calls. That translator is exactly what the `flutter_local_notifications` package does. But more about packages are on the next section...

## Section 2: The Three Packages and Why Each One Exists
So we agreed that our app is just a thin layer that hands instructions to the OS. Now the question is, what do we actually need on the Dart side to do that?

The honest answer is **three packages.** Not one. Not two. Three. And I know what you're thinking, *"three packages just to show a notification? Really?"* Yes, really. But by the end of this section, you'll understand why each one is non-negotiable. Each one solves a specific problem the other two can't.

#### Package 1: [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications)
This is the one that does the actual work. We already talked about it in Section 1 — it's the bridge between your Dart code and the native OS notification service. When you call something like `_plugin.zonedSchedule(...)` in Dart, this package's native side picks it up and calls `AlarmManager` on Android or `UNUserNotificationCenter` on iOS.

So far so good. This is the package you'd reach for first, and it's the only one you'll directly interact with in your code. You'll call `initialize`, you'll call `zonedSchedule`, you'll call `cancel`. All of it goes through this package. It's the workhorse. But here's the thing. The moment you try to actually schedule a notification, you hit a wall. The package refuses to accept a plain Dart `DateTime`. It demands something called a **`TZDateTime`**. And that's where the second package comes in.

#### Package 2: [timezone](https://pub.dev/packages/timezone)
Wait, why is this even a problem? Why isn't `DateTime` enough? Because `DateTime` **lies to you about time.** That sounds dramatic, but stick with me.

When you write `DateTime(2027, 1, 28, 9, 0)`, what you're actually saying is "9:00 AM on January 28, 2027", in the timezone the device is currently in. But the device's timezone isn't a fixed thing. The user could travel. Daylight Saving Time could shift. The device could be in one zone when you schedule the notification, and in a completely different one when it's supposed to fire 27 days later.

So "9:00 AM" becomes ambiguous. **Is it 9:00 AM in Athens, where the user was when they scheduled it? Or 9:00 AM in Tokyo, where they happen to be a week later?** Without a timezone attached to the time, there's no correct answer.

This is exactly why `flutter_local_notifications` refuses to use plain `DateTime`. It would be a bug waiting to happen, especially around DST changes. So it forces you to use `TZDateTime`, which is a timezone-aware datetime. It carries its zone with it. **"9:00 AM in Europe/Athens"** is unambiguous, no matter where the device is when the alarm fires.

The timezone package provides this `TZDateTime` class, plus the entire [IANA timezone database](https://www.iana.org/time-zones) (every timezone on Earth, with every historical DST rule), compiled into the package. When you initialize it, your app loads that database into memory once, and from then on you can work with any timezone in the world with full precision.

So now we have: the package that talks to the OS (`flutter_local_notifications`), and the package that knows about every timezone in existence (`timezone`). But we're still missing something. **What's the device's current timezone?**

#### Package 3: [flutter_timezone](https://pub.dev/packages/flutter_timezone)
The timezone package knows about Athens. It knows about Tokyo. It knows about every IANA zone ever defined. But it doesn't know **which one your device is currently in.**

To answer that question, we need to ask the OS directly. *"Hey OS, what timezone are you currently set to?"* And that's what `flutter_timezone` does. It's a tiny package that makes one platform-channel call to Android or iOS and returns a string like `"Europe/Athens"`. That's all. That's the whole package. So, to summarize everything, let's look at the three packages side by side:
1. **flutter_local_notifications** → the bridge to the OS
2. **timezone** → the library of every timezone rule in the world
3. **flutter_timezone** → asks the device which timezone it's currently in

Each one solves a problem the others can't. The first one alone is useless because it can't accept naive times. The second one alone is useless because it doesn't know what "local" means. The third one alone is useless because it's just a string-fetcher with no scheduling capability.

## Section 3: Permissions: What Each One Actually Does

This is the section most notification tutorials either skip entirely or get completely wrong. And the consequence is a specific, frustrating bug. Your code is correct. The package is initialized. The schedule call succeeds. And yet, **the notification never appears.** No error. No crash. Nothing.

Almost every time, the answer is permissions.

But here's where people get confused. When they hear "notification permissions," they think of one thing, the dialog that pops up and asks *"Allow My App to send you notifications?"* That dialog is real, and it matters. But it's only **half the story.** There are actually **two completely separate permission gates** standing between your code and a notification that fires at the right moment. And most tutorials only tell you about one of them.

#### POST_NOTIFICATIONS: the visibility gate

The first gate controls a simple question: **can your app show notifications in the user's tray at all?**

This is the permission that controls the visible banner, the sound, the lock screen entry, everything the user actually *sees*. Without it, your notifications are scheduled correctly, they even fire internally, but they are silently discarded before ever reaching the screen.

Now here's where Android's history makes things complicated. The rule has changed depending on which version of Android your user is running:

- **Android 12 and below** → notification display was granted automatically at install. No prompt, no dialog. Your app could show notifications the moment it was installed.
- **Android 13 and above** → `POST_NOTIFICATIONS` became a **runtime permission**. Your app must explicitly ask the user for it. The user sees a dialog. If they tap *"Don't allow"*, the OS won't show the dialog again. The user has to go into Settings manually to re-enable it.

The same notification code behaves completely differently depending on the device. On an old device, it just works. On a modern device, it's blocked until the user explicitly grants it. **If you skip this permission on Android 13+, your notifications will silently fail on the majority of active Android devices today.**

One golden rule about **when** to request this permission: **never ask at app launch.** Ask at the exact moment the feature becomes relevant, when the user takes an action that would benefit from notifications. That moment of context is what turns a cold permission prompt into something the user actually understands and is likely to accept.

#### USE_EXACT_ALARM vs SCHEDULE_EXACT_ALARM: the timing gate

The second gate is completely separate from the first. It doesn't control **whether** a notification appears. It controls **whether it appears at the precise moment you specified.**

Without an exact-alarm permission, Android's battery optimizer is free to batch your alarm with other apps' alarms and fire them all together at a convenient moment. Your *"fire at 9:00 AM"* might fire at 9:47 AM. Or later. On Doze mode (Android's deep sleep state) the delay can be hours.

For a time-sensitive reminder, this is unacceptable. So Android introduced exact-alarm permissions to let apps opt into precise scheduling. But here's the thing: there are **two versions of this permission**, and the difference is not about capability. They do the exact same thing at runtime. The difference is about **how the permission is granted, and whether the user can take it back.**

`SCHEDULE_EXACT_ALARM` is the older one, introduced in Android 12. It's granted automatically at install on most devices, but the user can **revoke it** at any time from *Settings → Apps → Your App → Alarms & Reminders*. If they revoke it and your code tries to schedule an exact alarm, it throws a `SecurityException`. You need to check `canScheduleExactAlarms()` before every scheduling call.

`USE_EXACT_ALARM` is the newer one, introduced in Android 13. It's granted at install and **cannot be revoked**. The user has no toggle for it in Settings. But Google Play enforces a strict policy: this permission is only for apps whose core function is timed reminders, like alarm clocks, calendar apps, medication trackers etc. If you use it for something that doesn't qualify, your listing can be removed.

The cleanest approach is to declare **both** in your `AndroidManifest.xml`, using the `maxSdkVersion` attribute to scope each one to the right Android version:

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<uses-permission
    android:name="android.permission.SCHEDULE_EXACT_ALARM"
    android:maxSdkVersion="32" />

<uses-permission android:name="android.permission.USE_EXACT_ALARM" />
```

`maxSdkVersion="32"` tells Android: *"Only consider this permission on API 32 and below."* On Android 13+ (API 33+), the OS sees `USE_EXACT_ALARM` instead. On Android 12, it falls back to `SCHEDULE_EXACT_ALARM`. One manifest. Both versions covered.

#### RECEIVE_BOOT_COMPLETED: The forgotten one

There's a third permission worth knowing about, and it's the one most developers discover the hard way. It's called `RECEIVE_BOOT_COMPLETED`, and it solves a very specific quirk of Android.

When an Android device reboots, **the OS forgets every alarm that was ever scheduled by every app.** `AlarmManager` is completely wiped. This means a user who restarts their phone will silently stop receiving reminders, with no indication that anything went wrong. Everything looked fine. Then the phone rebooted. And now, nothing.

`RECEIVE_BOOT_COMPLETED` gives your app permission to receive a signal the moment the device finishes booting. `flutter_local_notifications` uses this automatically to reschedule everything it had previously queued. You don't write any special code, you just declare the permission, and the plugin handles the rest:

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

iOS doesn't have this problem. The OS persists scheduled local notifications across reboots automatically. Just another quiet asymmetry between the two platforms.

#### What about iOS?

Compared to Android, iOS is almost refreshingly simple. There is **one permission for local notifications**, and it controls everything, the banner, the sound, the badge count. No exact-alarm distinction, no boot signal, no version fragmentation.

You don't declare anything in `Info.plist`. You don't add any entitlements. **You just ask for permission in code at the right moment**, and the OS shows this prompt:

> *"[Your App] Would Like to Send You Notifications"*

Allow or Don't Allow. That decision sticks. If they tap *Don't Allow*, the OS won't show the prompt again, same as Android 13+, same "ask at the right moment" rule applies.

#### Two gates. Both must be open.

This is the most important takeaway from this entire section:

1. `POST_NOTIFICATIONS` controls whether the notification **appears at all.**
2. The exact-alarm permission controls whether it appears **at the right time.**

These are not alternatives. You don't choose between them. **You need both.** If you only have `POST_NOTIFICATIONS`, your notifications will show, but potentially an hour late. If you only have the exact-alarm permission, your alarms fire precisely but are silently discarded before the user ever sees them.

Think of it like a locked door with two deadbolts. Both must be open. One is not enough.

**Keep that in mind as we move into the next section.** Because before we write a single line of Dart, there's one more native concept we need to understand, and it's the one that gives users control over the notifications they receive.

## Section 4: Channels: Giving Users Control Over What They Hear

If you've ever gone into your phone's settings and turned off notifications for a specific *category* of an app (say, disabling the promotional ones but keeping the important alerts) you just used a `notification channel`. Even if you didn't know it.

Channels are an **Android-only concept**, introduced in Android 8.0. iOS has nothing equivalent, and we'll get to why in a moment. But on Android, every single notification your app shows must belong to a channel. **Without a channel, your notification won't display at all on Android 8 and above.**

#### Why do channels exist?

Before Android 8, notification settings were all-or-nothing. Either your app could send notifications, or it couldn't. There was no middle ground. If you wanted to mute the promotional emails from an app but still receive the security alerts, you had two options: put up with everything, or turn off all notifications and miss the things that actually mattered. **Channels** were Android's solution to that problem. They hand **granular control back to the user.** Instead of one on/off switch per app, the user gets one switch *per category.* Your app declares the categories
1. "Reminders" 
2. "Promotions" 
3. "Security Alerts", 

and the user decides which ones they want to hear from.

#### So what exactly is a channel?

A channel is a named category that carries a set of display settings. When you create one, you define:

- **An ID:** a unique string that identifies this channel internally. `"reminders"`, `"order_updates"`, `"security"`. This is what you reference when scheduling a notification.
- **A name:** the user-facing label. This is what appears in the app's notification settings screen.
- **A description:** a short explanation of what this channel is for. Also visible to the user in Settings.
- **An importance level:** this controls *how prominently* the notification is displayed.

The importance level deserves a closer look, because it's the thing that most directly shapes the user experience:

- `Importance.min` → appears silently in the shade, no icon in the status bar
- `Importance.low` → appears quietly, no sound, status bar icon shows
- `Importance.defaultImportance` → sound plays, status bar icon shows, but no pop-up banner
- `Importance.high` → sound plays, status bar icon shows, **and** a heads-up banner slides down at the top of the screen
- `Importance.max` → same as high, reserved for urgent alerts like incoming calls

For a reminder app, `Importance.high` is the right choice. The user opted into these reminders, they should be hard to miss.

#### The rule nobody tells you about

Here's the part that catches everyone off guard. Once you create a channel and the user has seen it in their settings, **you cannot change its properties.** Not the importance. Not the sound. Not the vibration. Those settings now belong to the user.

> If you create a channel with `Importance.high` and later decide it should be `Importance.low`, calling `createNotificationChannel` again with the same ID does absolutely nothing. The channel already exists, and the OS ignores your updated settings entirely. The only way to change it is to create a *new channel with a different ID*, which leaves the old one as a dead orphan in the user's settings until they clear it manually.

**This is why you need to think about your channels before you ship.** Pick your IDs carefully. Pick your importance carefully. Once your users have the app installed, those decisions are locked.

The good news: creating a channel that already exists is completely safe. It's a no-op. Calling `createNotificationChannel` every time your app starts is fine, and actually the recommended approach.

#### What about iOS?

iOS doesn't have channels because Apple took a completely different philosophy. Instead of letting apps declare categories, **Apple gives users control through Focus modes, per-app notification summaries, and system-level notification management.** When you create channels in your Flutter code, they are completely ignored on iOS. The plugin handles this transparently, the channel creation call simply does nothing on the iOS side. You write the code once, and the platform figures out what to do with it.

What iOS *does* enforce is a hard limit: **you can have at most 64 pending local notifications scheduled at any given time.** Schedule a 65th and the OS quietly drops the oldest one. For most apps this never becomes an issue. But it's worth knowing, if your app ever needs to schedule dozens of reminders per user, you'll need to be deliberate about which ones matter most. Maybe this is `"your useless tip of the day"`...anyway 😅.

#### Channels and your app

For our demo app, we need exactly one channel. Something like:

```dart
const AndroidNotificationChannel channel = AndroidNotificationChannel(
  'reminders',                           // id
  'Reminders',                           // name
  description: 'Scheduled reminders.',
  importance: Importance.high,
);
```

But here's an interesting architectural question. What happens when your app grows and you need three, four, five channels? Do they all live scattered across different files? Do you hardcode their IDs as strings in multiple places and hope nothing ever gets out of sync?

This is exactly the kind of problem that compounds quietly as a codebase grows. And it's what we'll address in the next section, when we design the `NotificationService`, a single class that owns your entire notification system, keeps your channels in one place, and makes sure the rest of your app never needs to know how any of it works.

**That's where we're going next.**

## Section 5: Designing the NotificationService

Let's talk about a mistake that's very easy to make. You just learned about channels, permissions, and the OS scheduler. Now you want to write the scheduling code. And the natural instinct is: *"I have a button. When it's pressed, I schedule a notification. So the scheduling code goes... near the button."*

And just like that, your notification logic is buried inside a widget. Or inside a cubit that happens to need notifications. Or scattered across three different files because three different features all need reminders.

**That's the first thing we're going to get right.**

#### One class, one responsibility

The rule is simple. All notification logic like initialization, channel creation, permission requests, scheduling, cancelling, tap handling, lives in **exactly one class.** We'll call it `NotificationService`.

This class lives in your `core/services/` folder. Not inside any specific feature. Not next to your screens or your cubits. In `core/`, because it's a horizontal capability, something any feature in your app can use without that feature having any ownership over it.

Think about what this means in practice. When you add a second feature that also needs reminders, it doesn't write its own scheduling code. It calls `NotificationService`. When you add a third feature, same thing. The notification system doesn't grow. The *callers* grow. **There's only ever one place in your codebase that knows how to talk to the OS notification service.** That makes it easy to test, easy to update, and impossible to get out of sync with itself.

`NotificationService` is registered as a **singleton** in your dependency injection setup. One instance, created once, alive for the entire lifetime of the app. The plugin it wraps maintains internal state that shouldn't be duplicated. Creating multiple instances would be a bug.

#### The most important design decision: primitives only

Here's the design decision that separates a good notification service from a great one. And it's the one most people get wrong.

*"What if I just pass my whole data object into the service? It already has the title, the date, everything I need."*

Don't. **The `NotificationService` should not know anything about your app's domain.**

It shouldn't know about users, orders, tasks, products, or whatever your app is about. If it did, it would become a service that can only ever serve *that one feature.* The moment a second feature needs notifications, you're stuck, either you bloat the service with another domain type, or you duplicate the scheduling code elsewhere. Neither is good.

The clean solution is to make the service speak in **primitives only:**

- An `id` as an `int`
- A `fireAt` as a plain `DateTime`
- A `title` as a `String`
- A `body` as a `String`
- A `payload` as a `String?`

That's it. The service doesn't know what a "task" is or what an "order" is. It receives a time and some text, and it schedules them. The responsibility of translating *"this order ships on January 28"* into *"schedule an id=42 notification for January 25 at 9:00 AM with this title and body"* belongs to the feature, not the service.

**The translator lives outside the service. The service just executes.**

This is what makes `NotificationService` truly reusable across every feature you'll ever build. Today and in the future.

#### The channels enum

Remember the problem we ended Section 4 with? Channels scattered across files, IDs hardcoded as strings in multiple places, one typo away from a silent bug.

The solution is an enum. One enum, one file, one source of truth for every channel your app will ever declare:

```dart
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
```

Now every channel in your app is a typed value. When you reference `AppNotificationChannel.reminders`, your IDE autocompletes it. If you rename it, every reference updates. If you delete it, the compiler tells you everywhere it was used. **A typo in a channel ID is now a compile error, not a silent runtime failure.**

Adding a new channel in the future is one new enum value. That's it.

Inside `NotificationService`, the `scheduleReminder` method accepts a channel directly from this enum. The service uses the channel's id, name, description, and importance without knowing anything else about where the notification is coming from:

```dart
Future<void> scheduleReminder({
  required int id,
  required DateTime fireAt,
  required String title,
  required String body,
  required AppNotificationChannel channel,
  String? payload,
});
```

The service doesn't decide which channel a notification belongs to. The caller does. The service just uses what it's given.

#### A quick preview: the stream

There's one more thing `NotificationService` owns that we haven't discussed yet: **tap handling.**

When the user taps a notification, something in your app needs to react (navigate to a screen, refresh some data, show a dialog). But taps can happen in any app state: while the app is open, while it's in the background, or when the app was completely closed and the tap is what launched it. Wiring all three of those scenarios into one place requires a mechanism that multiple parts of your app can subscribe to independently.

That mechanism is a `Stream`. The `NotificationService` exposes a `Stream<String?>` called `onTap`. Whenever a notification is tapped, the payload string is pushed into this stream. Any part of your app that cares subscribes to it and reacts.

We'll go deep on how streams work, and why this is the right choice here, in Section 8. For now, just know it exists, and it's one of the most important pieces of the whole system.

#### The skeleton

Here's what `NotificationService` looks like before we fill in any implementation. Read it slowly. Notice what's there and, just as importantly, what *isn't:*

```dart
@singleton
class NotificationService {
  NotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<String?> _tapPayloads =
      StreamController<String?>.broadcast();

  Stream<String?> get onTap => _tapPayloads.stream;

  Future<void> init() async {
    // Timezone setup, plugin initialization,
    // channel registration, cold-start handling.
    // Coming in Section 6.
  }

  Future<bool> requestPermissions() async { ... }

  Future<void> scheduleReminder({
    required int id,
    required DateTime fireAt,
    required String title,
    required String body,
    required AppNotificationChannel channel,
    String? payload,
  }) async { ... }

  Future<void> cancel(int id) async { ... }

  void _onTap(NotificationResponse response) {
    _tapPayloads.add(response.payload);
  }
}
```

Notice what this class does *not* contain. No app-specific logic. No domain knowledge. No hardcoded strings. **It receives instructions, executes them, and reports back.** That's the whole job.

In the next section, we fill in every method. Starting with `init()`, the most important call in the whole system, and the one that has to happen before anything else.

## Section 6: Wiring It Up: Inside init()

We have a skeleton. We understand why it's designed the way it is. Now it's time to make it actually work.

Everything starts with `init()`. This is the method that bootstraps the entire notification system, timezone database, plugin, channels, tap callbacks, cold-start handling. It has to run **once, before anything else in your app tries to schedule or display a notification.** That makes its placement in `main.dart` critical.

#### Where init() belongs in your startup sequence

Your `main()` function is a sequence. Each step depends on the previous one being complete. `NotificationService.init()` slot belongs **after Flutter is initialized, but before your app runs:**

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final notificationService = NotificationService();
  await notificationService.init();

  runApp(MyApp(notificationService: notificationService));
}
```

The `await` is not optional. `init()` opens the timezone database, makes platform-channel calls to native code, and creates the OS notification channel. None of that is instantaneous. If you forget the `await` and call `runApp` while `init()` is still running, the first scheduling attempt will hit an uninitialized plugin and crash.

`WidgetsFlutterBinding.ensureInitialized()` must come first because the plugin uses platform channels, and platform channels require the Flutter engine to be fully bootstrapped before they can fire. If you've ever seen the *"Binding has not yet been initialized"* error, this is what it's protecting against.

#### Step 1: The timezone setup

The first thing `init()` does is set up the timezone database. Three lines, three distinct jobs:

```dart
Future<void> init() async {
  // Step 1 — Timezone setup
  tz.initializeTimeZones();
  final localTimezone = await FlutterTimezone.getLocalTimezone();
  tz.setLocalLocation(tz.getLocation(localTimezone.identifier));
  
  // ...
}
```

`tz.initializeTimeZones()` loads the entire IANA timezone database into memory. Every timezone on Earth. Every historical DST rule. This runs synchronously and needs to happen before anything else touches timezone-related code.

`FlutterTimezone.getLocalTimezone()` makes a platform-channel call to the OS and gets back a `TimezoneInfo` object. We then access its `.identifier` property to get a string like `"Europe/Athens"` or `"America/New_York"`. This is async because it crosses the native bridge, even though the OS answers almost instantly, the hop itself is asynchronous.

`tz.setLocalLocation(tz.getLocation(localTimezone.identifier))` tells the timezone package: *"this is the local zone, treat it as the default when I construct TZDateTime instances."* After this line, every `TZDateTime.now()` call in the app is anchored to the correct local zone.

**The order matters.** Database first, query device second, set local third. Swap any of them and you'll get cryptic null errors that are painful to trace.

#### Step 2: Initializing the plugin

Next, we set up `flutter_local_notifications` with platform-specific settings:

```dart
  // Step 2 — Plugin initialization
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );

  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await _plugin.initialize(
    settings: initSettings,
    onDidReceiveNotificationResponse: _onTap,
  );
```

`AndroidInitializationSettings` takes the name of the notification icon resource. `'@mipmap/ic_launcher'` points to your app's launcher icon as a fallback, it works, but Android renders it as a white silhouette in the status bar. For production, you'd generate a proper monochrome white icon and reference it as `'@drawable/ic_notification'`. For our demo, the launcher icon is fine.

`DarwinInitializationSettings` is the iOS equivalent. Notice all three permission flags are set to **`false`**. This is intentional. By default, calling `initialize()` on iOS would immediately trigger the permission prompt. **We don't want that.** We want to ask at a moment that makes sense to the user, not blindly at app launch. Setting these flags to false defers the prompt entirely until we explicitly call `requestPermissions()`.

`onDidReceiveNotificationResponse: _onTap` is where we register our tap callback. When the user taps a notification while the app is running or in the background, the plugin calls `_onTap`, which pushes the payload into our stream. We'll come back to this in Section 8.

#### Step 3: Registering channels

Remember the channels enum from Section 5? This is where it earns its place:

```dart
  // Step 3 — Register Android channels
  Future<void> _registerChannels() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation
            <AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin == null) return;

    for (final channel in AppNotificationChannel.values) {
      await androidPlugin.createNotificationChannel(
        AndroidNotificationChannel(
          channel.id,
          channel.name,
          description: channel.description,
          importance: channel.importance,
        ),
      );
    }
  }
```

`resolvePlatformSpecificImplementation` returns the Android-specific plugin on Android, and `null` on iOS. The `null` check is our platform guard, if we're on iOS, we return immediately. iOS has no channels, so there's nothing to create.

On Android, we iterate every value in `AppNotificationChannel` and create each one. Adding a new channel in the future means adding one enum value. The registration loop handles it automatically. **No code change needed here, ever.**

As we noted in Section 4, `createNotificationChannel` is idempotent. Calling it with an ID that already exists does nothing. So running this on every app launch is completely safe, and it means channels are always in sync with whatever the enum declares.

#### Step 4: The cold-start scenario

This is the one most tutorials miss entirely, and it's the source of a very specific bug: *"I tapped the notification and the app opened, but nothing happened."*

Here's what's going on. When the app is **completely terminated** and the user taps a notification, the OS launches the app fresh. The notification tap happened before our `onDidReceiveNotificationResponse` callback was even registered, so the plugin catches it separately, holding it for us to retrieve:

```dart
  Future<void> _handleLaunchPayload() async {
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();

    if (launchDetails?.didNotificationLaunchApp == true) {
      final payload = launchDetails?.notificationResponse?.payload;
      if (payload != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _tapPayloads.add(payload);
        });
      }
    }
  }
```

`getNotificationAppLaunchDetails()` asks the plugin: *"was this app launched by a notification tap?"* If yes, we get the payload from the launch details and push it into our stream.

But notice the `addPostFrameCallback` wrapper. **We can't push the payload immediately.** At the moment `init()` runs, the widget tree hasn't been built yet, which means whoever is subscribed to `onTap` for navigation purposes might not exist yet. By deferring the push to after the first frame is rendered, we guarantee that subscribers are ready to receive the event by the time it arrives.

Without this, cold-start taps would arrive before anything could handle them. The stream would fire into the void. The user would land on the home screen with no indication that the notification wanted to take them somewhere specific.

#### Putting it all together

Here's the complete `init()`:

```dart
Future<void> init() async {
  // 1. Timezone setup
  tz.initializeTimeZones();
  final localTimezone = await FlutterTimezone.getLocalTimezone();
  tz.setLocalLocation(tz.getLocation(localTimezone.identifier));

  // 2. Plugin initialization
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );
  await _plugin.initialize(
    settings: initSettings,
    onDidReceiveNotificationResponse: _onTap,
  );

  // 3. Register channels
  await _registerChannels();

  // 4. Handle cold-start tap
  await _handleLaunchPayload();
}

void _onTap(NotificationResponse response) {
  _tapPayloads.add(response.payload);
}
```

Read it top to bottom. It flows like a script: prepare the timezone context, wake up the plugin, declare the channels, check if we were launched by a tap. Each step depends only on what came before it. Each step is named clearly enough that you don't need to read the implementation to understand what it does.

**That's what good initialization code looks like.**

Now the foundation is in place. In the next section, we finally schedule something, and that's where `TZDateTime`, notification IDs, payloads, and the actual scheduling call all come together.

## Section 7: Scheduling, Payloads, and Cancelling

The foundation is in place. Now we write the three methods that make the whole thing actually useful.

#### Requesting permissions

We covered *what* these permissions are in Section 3. Here's *how* you request them at the right moment — when the user takes an action that benefits from notifications, not at app launch:

```dart
Future<bool> requestPermissions() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      return granted ?? false;
    }

    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

    if (iosPlugin != null) {
      final granted = await iosPlugin.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    return false;
}
```

The `?? false` is important. Some edge cases return `null`, we treat any non-explicit grant as a denial to be safe. The method returns a `bool` so the caller can decide what to do next: show an explanation, open Settings, or proceed quietly.

#### Scheduling a notification

```dart
Future<void> scheduleReminder({
  required int id,
  required DateTime fireAt,
  required String title,
  required String body,
  required AppNotificationChannel channel,
  String? payload,
}) async {
  final tzFireAt = tz.TZDateTime.from(fireAt, tz.local);

  final androidDetails = AndroidNotificationDetails(
    channel.id,
    channel.name,
    channelDescription: channel.description,
    importance: channel.importance,
    priority: Priority.high,
  );

  const iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );

  await _plugin.zonedSchedule(
    id: id,
    title: title,
    body: body,
    scheduledDate: tzFireAt,
    notificationDetails: NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    ),
    payload: payload,
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
  );
}
```

A few things worth highlighting.

`tz.TZDateTime.from(fireAt, tz.local)` is the conversion we talked about in Section 2. The caller passes a plain `DateTime`. We convert it internally to a timezone-aware `TZDateTime` anchored to the device's local zone. The caller never needs to know this happened.

`androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle` is the line that connects to `USE_EXACT_ALARM` from Section 3. It tells Android: fire this alarm at the exact moment specified, even if the device is in deep sleep. Without it, the exact-alarm permission you declared is essentially unused, the alarm would still be inexact.

`presentAlert: true` on iOS ensures the notification appears as a banner even when the app is in the foreground. Without it, iOS silently suppresses foreground notifications.

One behaviour worth knowing: if you call `scheduleReminder` with an `id` that already has a pending notification, **the old one is replaced.** No duplicates. This makes reschedules effortless, cancel-then-reschedule becomes just reschedule.

#### The payload and its limits

The `payload` is a single `String?` that travels with the notification and comes back to you when the user taps it. It's opaque to the service. We don't open it, we just carry it.

If you need to pass structured data (a screen to navigate to, an item ID, a notification type), encode it as JSON:

```dart
final payload = jsonEncode({'route': '/reminder', 'id': '123'});
```

And decode it when the tap arrives:

```dart
final data = jsonDecode(payload) as Map<String, dynamic>;
```

>**The hard limit is 4KB for the entire notification payload.** That's roughly 4,000 characters, plenty for routing data and IDs, not nearly enough for full objects or images. The right pattern is: send the ID, fetch the data when the user taps. Never try to fit your entire model into a notification payload.

#### Notification IDs

Every notification needs an `int` ID. You use it to cancel or replace a specific notification later. The simplest reliable strategy: derive it deterministically from the data you already have.

```dart
final id = 'some-unique-key'.hashCode.abs() % 100000;
```

`hashCode` gives you a stable integer for any string. `abs()` removes the possibility of a negative value. `% 100000` keeps it in a safe range. **The same key always produces the same ID**, which means you can always cancel or replace a notification without having stored the ID separately.

#### Cancelling

```dart
Future<void> cancel(int id) async {
  await _plugin.cancel(id: id);
}
```

Pass the same ID you scheduled with, and the notification disappears from the OS queue. If no notification with that ID exists, this is a no-op. **It never throws.** Cancel freely.

Next up: the tap. What happens when the user actually presses the notification, and how the stream handles every possible app state.

## Section 8: The Tap: Where the Stream Earns Its Keep

We've built the scheduler. Now we need to handle what happens on the other end: the user taps a notification, and your app needs to react. Navigate somewhere. Refresh some data. Show a dialog.

Sounds simple. **It isn't.** Because the tap can arrive in three completely different situations.

#### The three app states

**The app is open (foreground).** The user taps the notification banner. The plugin fires `onDidReceiveNotificationResponse` immediately. Our `_onTap` callback picks it up and pushes the payload into the stream.

**The app is in the background.** Same as foreground. The user taps, the OS brings the app forward, the plugin fires the callback, the stream gets the payload.

**The app was completely closed (terminated).** The user taps the notification. The OS launches the app fresh. But this time, `onDidReceiveNotificationResponse` never fires, the callback wasn't registered yet when the tap happened. Instead, the plugin holds the launch payload, and `_handleLaunchPayload()` (from Section 6) retrieves it after the first frame is rendered and pushes it into the stream.

Three states. Three different paths. **One stream that handles all of them the same way.**

This is exactly why the stream exists. Without it, you'd need three separate wiring points in your app, each handling the tap slightly differently, each easy to forget. With it, any part of your app subscribes once and receives taps from every state automatically.

#### How the stream works

A `StreamController` is a pipe with two ends. The **write end** is private, only `NotificationService` can push events into it. The **read end** is what we expose publicly via the `onTap` getter:

```dart
final StreamController<String?> _tapPayloads =
    StreamController<String?>.broadcast();

Stream<String?> get onTap => _tapPayloads.stream;
```

The `.broadcast()` part means multiple listeners can subscribe simultaneously without conflict. Your router subscribes. Your analytics service subscribes. Neither knows the other exists. **Both receive the event when a tap arrives.**

When `_onTap` fires (foreground/background) or `_handleLaunchPayload` runs (terminated), they both do the same thing:

```dart
_tapPayloads.add(payload);
```

One line. The event travels down the stream to every active subscriber.

#### Subscribing: where and when

Subscribe as early as possible in your app's lifecycle — before any notification could realistically be tapped. `main.dart`, right after `init()`, is the right place:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final notificationService = NotificationService();
  await notificationService.init();

  notificationService.onTap.listen((payload) {
    if (payload == null) return;

    final data = jsonDecode(payload) as Map<String, dynamic>;
    final route = data['route'] as String?;

    if (route != null) {
      // Navigate to the right screen based on the route.
      debugPrint('Navigating to: $route');
    }
  });

  runApp(MyApp(notificationService: notificationService));
}
```

The `listen` call returns a `StreamSubscription`. In a real app you'd store this and cancel it on cleanup. In our demo, the service is alive for the app's entire lifetime, so it's fine to let it run.

Notice the `addPostFrameCallback` from Section 6 handling the terminated case. By the time the post-frame callback fires, `main()` has already returned, `runApp` has already built the widget tree, and your `listen` is already active. The payload arrives to a ready subscriber. **The timing is what makes it work.**

#### The full picture

Let's trace a complete notification lifecycle one final time, from scheduling to tap:

1. User presses the button → `scheduleReminder()` hands instructions to the OS
2. 10 seconds pass → OS fires the alarm, `AlarmManager` / `UNUserNotificationCenter` displays the notification
3. User taps it → OS invokes the plugin's native callback
4. Plugin crosses the platform channel back to Dart → `_onTap()` fires
5. `_onTap()` calls `_tapPayloads.add(payload)` → the stream emits an event
6. Your `listen` handler receives the payload → decodes it → navigates

**Six steps. Your code only owns steps 1, 4, 5, and 6.** Steps 2 and 3 belong entirely to the OS, which is exactly what Section 1 told us from the very beginning.

That's the whole system. From a button press to a tap handler, built on three packages, two platform permissions, one service, and one stream.

## Conclusion

And there you have it! What started as a simple *"schedule a notification"* turned into a full expedition through operating system schedulers, permission layers, notification channels, timezone databases, and stream controllers. I know that's a lot. But every single piece earned its place.

Let's recap what we actually learned. The **OS owns the schedule**. Your app just hands instructions over and walks away. There are **two completely separate permission gates**, one that controls whether notifications appear at all, and one that controls whether they appear at the right time. Mixing them up is the root cause of half the notification bugs you'll ever see. A **`NotificationService` that speaks in primitives** keeps your notification system reusable across every feature you'll ever build, not just the one that needed reminders today. And a **broadcast stream** gives every part of your app a unified way to react to taps, regardless of which state the app was in when the user pressed it.

Here's the bigger picture though. Notifications are not a feature. They're infrastructure. And like any infrastructure, the cost of getting them wrong is subtle, a reminder that fires an hour late, a tap that opens the wrong screen, a permission that silently blocks everything on a new Android device. Getting them right doesn't take magic. It just takes understanding what's actually happening underneath the code you write.

The companion repository for this article is available on [GitHub](https://github.com/Thanasis-Traitsis/flutter_notifications). Clone it, run it, and use it as a reference as you build your own implementation.

This was Part 1, local notifications only. Part 2 will cover remote push notifications: how FCM and APNs work, how a server triggers a notification on a user's device, and how you handle the payload when the notification arrives. Everything we built today is the foundation for that. When you understand the local side, the remote side becomes much easier to reason about.

If you enjoyed this article and want to stay connected, feel free to connect with me on [LinkedIn](https://www.linkedin.com/in/thanasis-traitsis/).

Was this guide helpful? Consider buying me a coffee! ☕️ Your contribution goes a long way in fuelling future content and projects. [Buy Me a Coffee](https://www.buymeacoffee.com/thanasis_traitsis).

As always, go ahead and experiment, dig into the source, and don't be afraid to follow the code wherever it leads. Happy coding, Flutter friends!
