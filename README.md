# Walkie Talkie Desktop

A Flutter desktop push-to-talk client for Windows and macOS. It connects to a local Go WebSocket server at:

```text
ws://localhost:8080/ws
```

For LAN testing, point the app at the machine running the Go server:

```sh
WALKIE_SERVER_URI=ws://192.168.2.20:8080/ws flutter run -d macos
```

When using `flutter run`, you can also pass it as a compile-time value:

```sh
flutter run -d macos --dart-define=WALKIE_SERVER_URI=ws://192.168.2.20:8080/ws
```

## Protocol

The app sends text control messages and raw PCM binary audio frames over the same WebSocket.

```text
REQUEST_MIC  sent when the user presses the PTT button or global hotkey
MIC_GRANTED  expected from the server before audio streaming starts
MIC_DENIED   expected from the server when another user owns the line
RELEASE_MIC  sent when the user releases PTT or the hotkey
```

Captured microphone audio is 24 kHz, mono, signed 16-bit PCM from the `record` package. Incoming binary messages are treated as the same PCM format and passed into `media_kit` with minimal app-side buffering.

## Dependencies

Important packages are declared in `pubspec.yaml`:

```yaml
record: ^5.0.5
media_kit: 1.1.5
media_kit_libs_audio: ^1.0.5
hotkey_manager: 0.1.7
supabase_flutter: ^1.10.25
tray_manager: ^0.2.1
url_launcher: ^6.1.11
window_manager: ^0.3.7
```

Run:

```sh
flutter pub get
```

## Google Login

The desktop app uses Supabase Auth with Google OAuth. During desktop development it
finishes the login through a local callback page:

```text
http://localhost:3000/auth/callback
```

The packaged app also supports this custom desktop deep link:

```text
walkie-talkie://login-callback
```

Supabase project:

```text
https://uwkwhyushxepfgpuvbny.supabase.co
```

Google Console should use a Web application OAuth client. Its authorized redirect URI must be the Supabase callback URL:

```text
https://uwkwhyushxepfgpuvbny.supabase.co/auth/v1/callback
```

Supabase Authentication URL Configuration should allow:

```text
http://localhost:3000/auth/callback
http://localhost:3000/**
walkie-talkie://login-callback
```

Only the public anon/client key belongs in the Flutter app. Never place the Supabase `service_role` key in the desktop app.

Run [supabase/schema.sql](supabase/schema.sql) once in the Supabase SQL editor. It creates:

```text
profiles
contact_requests
contacts
```

Those tables power profile creation, add-by-email requests, approval/decline, and online/offline presence.

The same schema also creates:

```text
groups
group_members
pokes
```

and RPC functions for atomic request approval, friend deletion, group admin actions, and poke clearing. Re-run the SQL after pulling app changes that touch Supabase tables or policies.

## Windows Runner Notes

No C++ runner changes are required for the current implementation. The Flutter app uses `window_manager` to intercept close events and hide to the system tray instead of exiting.

The tray icon uses `assets/tray/walkie_tray.ico`. Clicking the tray icon opens a menu with an `Open Desktop App` action.

Global hotkeys are registered with `hotkey_manager`. If Caps Lock is reserved by the OS or another app, Left Ctrl is also registered as a fallback push-to-talk key.

Build or run:

```sh
flutter run -d windows
flutter build windows --release
```

## macOS Runner Notes

The macOS runner is configured with:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Walkie Talkie needs microphone access to transmit push-to-talk audio.</string>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

macOS may require Accessibility/Input Monitoring approval for global hotkeys:

1. Open System Settings.
2. Go to Privacy & Security.
3. Allow the app under Accessibility and Input Monitoring if prompted.

The menu bar icon uses `assets/tray/walkie_tray.png`. Clicking the icon opens the popover menu with `Open Desktop App`, `Login & Add Users`, and `Quit`.

Build or run:

```sh
flutter run -d macos
flutter build macos --release
```

## Local Server Contract

Start the Go WebSocket server before launching the app. The server should:

1. Accept `REQUEST_MIC`.
2. Reply with `MIC_GRANTED` or `MIC_DENIED`.
3. Accept binary PCM frames only after `MIC_GRANTED`.
4. Accept `RELEASE_MIC` and stop associating subsequent frames with that client.
5. Track `HELLO|user_id` identity messages.
6. Accept `REQUEST_MIC|user_id,user_id` for targeted one-to-one or group routing.
7. Broadcast incoming binary PCM frames only to selected recipients.
