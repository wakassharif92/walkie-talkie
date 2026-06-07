import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import 'protocol_registration.dart';

const _serverUri = 'ws://localhost:8080/ws';
const _supabaseUrl = 'https://uwkwhyushxepfgpuvbny.supabase.co';
const _supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
    'eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV3a3doeXVzaHhlcGZncHV2Ym55Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA3NDIxNTcsImV4cCI6MjA5NjMxODE1N30.'
    'IoMfLh8AVWE_CQixqFXkwN4JsyNmduWLo7k_OpFC4YY';
const _authRedirectUri = 'walkie-talkie://login-callback';
const _localAuthCallbackPort = 3000;
const _localAuthRedirectUri = 'http://localhost:3000/auth/callback';
const _sampleRate = 24000;
const _channels = 1;
const _bitsPerSample = 16;
const _windowsAuthStorageDirName = 'WalkieTalkie';
const _authSessionFileName = 'supabase_session.txt';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Supabase.initialize(
    url: _supabaseUrl,
    anonKey: _supabaseAnonKey,
    authFlowType: AuthFlowType.pkce,
    authCallbackUrlHostname: 'login-callback',
    localStorage: _supabaseLocalStorage(),
  );
  await registerAppProtocol('walkie-talkie');

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(760, 560),
      minimumSize: Size(560, 460),
      center: true,
      title: 'Walkie Talkie',
      backgroundColor: Color(0xFF101216),
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setPreventClose(true);
    },
  );

  if (!Platform.isWindows) {
    await hotKeyManager.unregisterAll();
  }
  runApp(const WalkieTalkieApp());
}

LocalStorage? _supabaseLocalStorage() {
  if (!Platform.isWindows) return null;

  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) return null;

  return FileLocalStorage(
    [
      localAppData,
      _windowsAuthStorageDirName,
      'auth',
    ].join(Platform.pathSeparator),
  );
}

class FileLocalStorage extends LocalStorage {
  FileLocalStorage(String directoryPath)
      : super(
          initialize: () async {
            await Directory(directoryPath).create(recursive: true);
          },
          hasAccessToken: () async {
            final file = File(_sessionFilePath(directoryPath));
            return file.existsSync() && file.lengthSync() > 0;
          },
          accessToken: () async {
            final file = File(_sessionFilePath(directoryPath));
            if (!file.existsSync()) return null;
            final value = await file.readAsString();
            return value.isEmpty ? null : value;
          },
          removePersistedSession: () async {
            final file = File(_sessionFilePath(directoryPath));
            if (file.existsSync()) {
              await file.delete();
            }
          },
          persistSession: (session) async {
            final file = File(_sessionFilePath(directoryPath));
            await file.parent.create(recursive: true);
            await file.writeAsString(session, flush: true);
          },
        );

  static String _sessionFilePath(String directoryPath) {
    return [
      directoryPath,
      _authSessionFileName,
    ].join(Platform.pathSeparator);
  }
}

enum TalkState { idle, requesting, transmitting, busy, disconnected }

class WalkieTalkieApp extends StatefulWidget {
  const WalkieTalkieApp({super.key});

  @override
  State<WalkieTalkieApp> createState() => _WalkieTalkieAppState();
}

class _WalkieTalkieAppState extends State<WalkieTalkieApp>
    with WindowListener, tray.TrayListener {
  late final WalkieTalkieController _controller;
  late final AuthController _authController;
  late final ContactsController _contactsController;

  @override
  void initState() {
    super.initState();
    _controller = WalkieTalkieController()..start();
    _authController = AuthController()..start();
    _contactsController = ContactsController(_authController)..start();
    _authController.addListener(_refreshTrayMenu);
    _contactsController.addListener(_refreshTrayMenu);
    _authController.addListener(_syncAudioRouting);
    _contactsController.addListener(_syncAudioRouting);
    _syncAudioRouting();
    _configureTray();
    if (!Platform.isWindows) {
      _registerHotKeys();
    }
    windowManager.addListener(this);
    tray.trayManager.addListener(this);
  }

  Future<void> _configureTray() async {
    await tray.trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/walkie_tray.ico'
          : 'assets/tray/walkie_tray.png',
      isTemplate: false,
    );
    await tray.trayManager.setToolTip('Walkie Talkie');
    final menuItems = <tray.MenuItem>[
      tray.MenuItem(key: 'open_app', label: 'Open Desktop App'),
    ];

    if (_authController.isSignedIn) {
      menuItems.add(
        tray.MenuItem.checkbox(
          key: 'toggle_presence',
          label: _contactsController.online ? 'Online' : 'Offline',
          checked: _contactsController.online,
        ),
      );
      menuItems.add(tray.MenuItem.separator());
      if (_contactsController.contacts.isEmpty) {
        menuItems.add(
          tray.MenuItem(
            key: 'manage_users',
            label: 'Add Users',
          ),
        );
      } else {
        for (final contact in _contactsController.contacts) {
          menuItems.add(
            tray.MenuItem(
              key: 'contact:${contact.id}',
              label:
                  '${contact.isOnline ? '●' : '●'} ${_contactsController.hasPokeFrom(contact.id) ? '📣 ' : ''}${contact.label}',
              disabled: !contact.isOnline || !_contactsController.online,
            ),
          );
        }
      }
      if (_contactsController.groups.isNotEmpty) {
        menuItems.add(tray.MenuItem.separator());
        for (final group in _contactsController.groups) {
          menuItems.add(
            tray.MenuItem(
              key: 'group:${group.id}',
              label: '👥 ${group.name}',
              disabled: !_contactsController.online,
            ),
          );
        }
      }
    } else {
      menuItems.add(
        tray.MenuItem(key: 'manage_users', label: 'Login'),
      );
    }

    menuItems.add(tray.MenuItem.separator());
    menuItems.add(tray.MenuItem(key: 'quit', label: 'Quit'));

    await tray.trayManager.setContextMenu(
      tray.Menu(
        items: menuItems,
      ),
    );
  }

  void _refreshTrayMenu() {
    _configureTray();
  }

  void _syncAudioRouting() {
    _controller.setIdentity(_authController.user?.id);
    final contact = _contactsController.selectedContact;
    final group = _contactsController.selectedGroup;
    if (contact != null) {
      _controller.setRecipients([contact.id]);
      return;
    }
    if (group != null) {
      final myId = _authController.user?.id;
      _controller.setRecipients(
        _contactsController.selectedGroupMembers
            .map((member) => member.profile.id)
            .where((id) => id != myId)
            .toList(),
      );
      return;
    }
    _controller.setRecipients([]);
  }

  Future<void> _registerHotKeys() async {
    Future<void> register(PhysicalKeyboardKey key) async {
      final hotKey = HotKey(key: key, scope: HotKeyScope.system);
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) {
          if (_canUseMicForSelectedContact) {
            _startSelectedTalk();
          }
        },
        keyUpHandler: (_) => _controller.releaseMic(),
      );
    }

    final keys = Platform.isWindows
        ? const [PhysicalKeyboardKey.capsLock]
        : const [
            PhysicalKeyboardKey.capsLock,
            PhysicalKeyboardKey.controlLeft,
          ];

    for (final key in keys) {
      try {
        await register(key);
      } catch (error) {
        _controller.setNotice('Could not register ${key.debugName}: $error');
      }
    }
  }

  bool get _canUseMicForSelectedContact {
    final contact = _contactsController.selectedContact;
    final group = _contactsController.selectedGroup;
    return _authController.isSignedIn &&
        _contactsController.online &&
        ((contact != null && contact.isOnline) || group != null);
  }

  Future<void> _startSelectedTalk() async {
    final contact = _contactsController.selectedContact;
    if (contact != null) {
      await _contactsController.clearPokeFrom(contact.id);
    }
    await _controller.requestMic();
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    tray.trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    tray.trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    final key = menuItem.key;
    if (key != null && key.startsWith('contact:')) {
      final contactId = key.substring('contact:'.length);
      final contact = _contactsController.contacts
          .where((item) => item.id == contactId)
          .cast<UserProfile?>()
          .firstWhere((item) => item != null, orElse: () => null);
      if (contact != null) {
        _contactsController.selectContact(contact);
        _showWindow();
      }
      return;
    }
    if (key != null && key.startsWith('group:')) {
      final groupId = key.substring('group:'.length);
      final group = _contactsController.groups
          .where((item) => item.id == groupId)
          .cast<TalkGroup?>()
          .firstWhere((item) => item != null, orElse: () => null);
      if (group != null) {
        _contactsController.selectGroup(group);
        _showWindow();
      }
      return;
    }

    switch (key) {
      case 'open_app':
      case 'manage_users':
        _showWindow();
        break;
      case 'toggle_presence':
        _contactsController.setOnline(!_contactsController.online);
        break;
      case 'quit':
        _quit();
        break;
    }
  }

  Future<void> _quit() async {
    await _contactsController.goOffline();
    await _controller.dispose();
    if (!Platform.isWindows) {
      await hotKeyManager.unregisterAll();
    }
    await tray.trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    tray.trayManager.removeListener(this);
    _authController.removeListener(_refreshTrayMenu);
    _contactsController.removeListener(_refreshTrayMenu);
    _authController.removeListener(_syncAudioRouting);
    _contactsController.removeListener(_syncAudioRouting);
    _contactsController.dispose();
    _authController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Walkie Talkie',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF101216),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF38E07B),
          brightness: Brightness.dark,
          surface: const Color(0xFF181B21),
        ),
        fontFamily: Platform.isMacOS ? 'SF Pro Display' : 'Segoe UI',
        useMaterial3: true,
      ),
      home: DesktopShell(
        authController: _authController,
        contactsController: _contactsController,
        talkController: _controller,
      ),
    );
  }
}

class AuthController extends ChangeNotifier {
  final SupabaseClient _client = Supabase.instance.client;
  final AppLinks _appLinks = AppLinks();

  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<Uri>? _linkSubscription;
  HttpServer? _callbackServer;

  User? user;
  bool signingIn = false;
  String authMessage = 'Sign in to manage contacts and presence.';

  bool get isSignedIn => user != null;

  void start() {
    user = _client.auth.currentUser;
    authMessage = user == null ? authMessage : 'Signed in as ${user!.email}';
    _listenForDeepLinks();
    _authSubscription = _client.auth.onAuthStateChange.listen((data) {
      user = data.session?.user;
      signingIn = false;
      authMessage = user == null
          ? 'Signed out'
          : 'Signed in as ${user!.email ?? 'Google user'}';
      notifyListeners();
    });
  }

  Future<void> _listenForDeepLinks() async {
    try {
      final initialLink = await _appLinks.getInitialAppLink();
      if (initialLink != null) {
        await _handleAuthLink(initialLink);
      }
    } catch (error) {
      authMessage = 'Could not read startup login link: $error';
      notifyListeners();
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleAuthLink,
      onError: (Object error) {
        signingIn = false;
        authMessage = 'Could not read login link: $error';
        notifyListeners();
      },
    );
  }

  Future<void> signInWithGoogle() async {
    if (signingIn) return;
    signingIn = true;
    authMessage = 'Opening Google sign in...';
    notifyListeners();

    try {
      await _startLocalCallbackServer();
      final opened = await _client.auth.signInWithOAuth(
        Provider.google,
        redirectTo: _localAuthRedirectUri,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!opened) {
        signingIn = false;
        authMessage = 'Could not open browser for Google sign in.';
        await _stopLocalCallbackServer();
        notifyListeners();
      }
    } catch (error) {
      signingIn = false;
      authMessage = 'Google sign in failed: $error';
      await _stopLocalCallbackServer();
      notifyListeners();
    }
  }

  Future<void> _startLocalCallbackServer() async {
    if (_callbackServer != null) return;

    _callbackServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      _localAuthCallbackPort,
      shared: true,
    );
    _callbackServer!.listen(
      _handleLocalCallbackRequest,
      onError: (Object error) {
        signingIn = false;
        authMessage = 'Login callback server failed: $error';
        notifyListeners();
      },
    );
  }

  Future<void> _handleLocalCallbackRequest(HttpRequest request) async {
    if (request.uri.path != '/auth/callback') {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found');
      await request.response.close();
      return;
    }

    try {
      final callbackUri = Uri(
        scheme: 'http',
        host: 'localhost',
        port: _localAuthCallbackPort,
        path: request.uri.path,
        query: request.uri.query,
        fragment: request.uri.fragment,
      );
      await _client.auth.getSessionFromUrl(callbackUri);
      request.response
        ..headers.contentType = ContentType.html
        ..write('''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Walkie Talkie signed in</title>
    <style>
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        background: #101216;
        color: #f5f7fa;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      main {
        text-align: center;
      }
      h1 {
        margin: 0 0 12px;
        font-size: 28px;
      }
      p {
        margin: 0;
        color: #aeb5bf;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>Signed in</h1>
      <p>You can return to Walkie Talkie now.</p>
    </main>
  </body>
</html>
''');
      await request.response.close();
      await _stopLocalCallbackServer();
    } catch (error) {
      signingIn = false;
      authMessage = 'Could not complete sign in: $error';
      notifyListeners();
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Could not complete sign in. Return to Walkie Talkie.');
      await request.response.close();
      await _stopLocalCallbackServer();
    }
  }

  Future<void> _stopLocalCallbackServer() async {
    final server = _callbackServer;
    _callbackServer = null;
    await server?.close(force: true);
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    user = null;
    authMessage = 'Signed out';
    notifyListeners();
  }

  Future<void> _handleAuthLink(Uri uri) async {
    final authRedirectUri = Uri.parse(_authRedirectUri);
    if (uri.scheme != authRedirectUri.scheme ||
        uri.host != authRedirectUri.host) {
      return;
    }

    try {
      await _client.auth.getSessionFromUrl(uri);
    } catch (error) {
      signingIn = false;
      authMessage = 'Could not complete sign in: $error';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _linkSubscription?.cancel();
    _callbackServer?.close(force: true);
    super.dispose();
  }
}

class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.authController,
    required this.contactsController,
    required this.talkController,
  });

  final AuthController authController;
  final ContactsController contactsController;
  final WalkieTalkieController talkController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: authController,
      builder: (context, _) {
        if (!authController.isSignedIn) {
          return LoginView(authController: authController);
        }

        return ContactsDashboard(
          authController: authController,
          contactsController: contactsController,
          talkController: talkController,
        );
      },
    );
  }
}

class ContactsDashboard extends StatelessWidget {
  const ContactsDashboard({
    super.key,
    required this.authController,
    required this.contactsController,
    required this.talkController,
  });

  final AuthController authController;
  final ContactsController contactsController;
  final WalkieTalkieController talkController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([contactsController, talkController]),
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 320,
                    maxWidth: 380,
                  ),
                  child: _ContactsPanel(
                    authController: authController,
                    contactsController: contactsController,
                  ),
                ),
                const VerticalDivider(width: 1, color: Colors.white10),
                Expanded(
                  child: WalkieTalkieHome(
                    controller: talkController,
                    authController: authController,
                    contactsController: contactsController,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ContactsPanel extends StatelessWidget {
  const _ContactsPanel({
    required this.authController,
    required this.contactsController,
  });

  final AuthController authController;
  final ContactsController contactsController;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF12151A),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AccountStrip(authController: authController),
            const SizedBox(height: 14),
            _PresenceSwitch(contactsController: contactsController),
            const SizedBox(height: 14),
            _AddContactForm(contactsController: contactsController),
            if (contactsController.message.isNotEmpty) ...[
              const SizedBox(height: 10),
              _InlineStatus(message: contactsController.message),
            ],
            if (contactsController.incomingRequests.isNotEmpty) ...[
              const SizedBox(height: 18),
              const _SectionTitle(title: 'Requests'),
              const SizedBox(height: 8),
              ...contactsController.incomingRequests.map(
                (request) => _RequestTile(
                  request: request,
                  contactsController: contactsController,
                ),
              ),
            ],
            if (contactsController.incomingPokes.isNotEmpty) ...[
              const SizedBox(height: 18),
              const _SectionTitle(title: 'Pokes'),
              const SizedBox(height: 8),
              ...contactsController.incomingPokes.map(
                (poke) => _PokeTile(
                  poke: poke,
                  contactsController: contactsController,
                ),
              ),
            ],
            const SizedBox(height: 18),
            _SectionTitle(
              title: 'Contacts',
              trailing: IconButton(
                tooltip: 'Refresh',
                onPressed: contactsController.loading
                    ? null
                    : () => contactsController.refresh(),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ),
            const SizedBox(height: 8),
            if (contactsController.contacts.isEmpty)
              const _EmptyState(label: 'No contacts yet')
            else
              ...contactsController.contacts.map((contact) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ContactTile(
                    contact: contact,
                    hasPoke: contactsController.hasPokeFrom(contact.id),
                    selected:
                        contactsController.selectedContact?.id == contact.id,
                    onTap: () => contactsController.selectContact(contact),
                    onPoke: () => contactsController.sendPoke(contact),
                    onDelete: () => contactsController.deleteContact(contact),
                  ),
                );
              }),
            const SizedBox(height: 18),
            _GroupsSection(contactsController: contactsController),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _InlineStatus extends StatelessWidget {
  const _InlineStatus({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final isError = message.toLowerCase().contains('error') ||
        message.toLowerCase().contains('could not') ||
        message.toLowerCase().contains('failed');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError ? const Color(0xFF2A1418) : const Color(0xFF181B21),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError ? const Color(0xFF6E2C37) : Colors.white10,
        ),
      ),
      child: Text(
        message,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isError ? const Color(0xFFFF9DA9) : Colors.white54,
              letterSpacing: 0,
            ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF181B21),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white38)),
    );
  }
}

class _PresenceSwitch extends StatelessWidget {
  const _PresenceSwitch({required this.contactsController});

  final ContactsController contactsController;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF181B21),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          _StatusDot(isOnline: contactsController.online),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              contactsController.online ? 'Online' : 'Offline',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          Switch(
            value: contactsController.online,
            activeThumbColor: const Color(0xFF38E07B),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: contactsController.setOnline,
          ),
        ],
      ),
    );
  }
}

class _AddContactForm extends StatelessWidget {
  const _AddContactForm({required this.contactsController});

  final ContactsController contactsController;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: contactsController.emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              hintText: 'Add by email',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => contactsController.addContactByEmail(),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: const Color(0xFF38E07B),
          borderRadius: BorderRadius.circular(8),
          child: IconButton(
            tooltip: 'Send request',
            onPressed: contactsController.loading
                ? null
                : contactsController.addContactByEmail,
            color: const Color(0xFF101216),
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
        ),
      ],
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.request,
    required this.contactsController,
  });

  final ContactRequest request;
  final ContactsController contactsController;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF181B21),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            request.sender.email,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => contactsController.declineRequest(request),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => contactsController.approveRequest(request),
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.contact,
    required this.hasPoke,
    required this.selected,
    required this.onTap,
    required this.onPoke,
    required this.onDelete,
  });

  final UserProfile contact;
  final bool hasPoke;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onPoke;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      selectedTileColor: const Color(0x2238E07B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: selected ? const Color(0xFF38E07B) : Colors.white10),
      ),
      leading: _StatusDot(isOnline: contact.isOnline),
      title: Text(
        '${hasPoke ? '📣 ' : ''}${contact.label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(contact.isOnline ? 'Online' : 'Offline'),
      trailing: PopupMenuButton<String>(
        tooltip: 'Contact actions',
        onSelected: (value) {
          switch (value) {
            case 'poke':
              onPoke();
              break;
            case 'delete':
              onDelete();
              break;
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'poke',
            child: Text('Poke'),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text('Delete friend'),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _PokeTile extends StatelessWidget {
  const _PokeTile({
    required this.poke,
    required this.contactsController,
  });

  final PokeNotice poke;
  final ContactsController contactsController;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Colors.white10),
      ),
      leading: const Icon(Icons.campaign_rounded, color: Color(0xFF38E07B)),
      title: Text(
        poke.sender.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: const Text('Tried to talk to you'),
      onTap: () {
        contactsController.selectContact(poke.sender);
      },
    );
  }
}

class _GroupsSection extends StatelessWidget {
  const _GroupsSection({required this.contactsController});

  final ContactsController contactsController;

  @override
  Widget build(BuildContext context) {
    final selectedGroup = contactsController.selectedGroup;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Groups',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
            ),
            const Spacer(),
            SizedBox(
              width: 150,
              child: TextField(
                controller: contactsController.groupNameController,
                decoration: const InputDecoration(
                  hintText: 'New group',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => contactsController.createGroup(),
              ),
            ),
            IconButton(
              tooltip: 'Create group',
              onPressed: contactsController.createGroup,
              icon: const Icon(Icons.add_circle_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: contactsController.groups.isEmpty ? 42 : 94,
          child: contactsController.groups.isEmpty
              ? const Center(
                  child: Text(
                    'No groups',
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: contactsController.groups.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final group = contactsController.groups[index];
                    final selected = selectedGroup?.id == group.id;
                    return ChoiceChip(
                      selected: selected,
                      label: Text(group.name),
                      avatar: Icon(
                        group.isAdmin
                            ? Icons.admin_panel_settings_rounded
                            : Icons.groups_rounded,
                        size: 18,
                      ),
                      onSelected: (_) => contactsController.selectGroup(group),
                    );
                  },
                ),
        ),
        if (selectedGroup != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: contactsController.groupMemberEmailController,
                  enabled: selectedGroup.isAdmin,
                  decoration: const InputDecoration(
                    hintText: 'Member email',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) =>
                      contactsController.addSelectedGroupMember(),
                ),
              ),
              IconButton(
                tooltip: 'Add member',
                onPressed: selectedGroup.isAdmin
                    ? contactsController.addSelectedGroupMember
                    : null,
                icon: const Icon(Icons.group_add_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 96,
            child: ListView.separated(
              itemCount: contactsController.selectedGroupMembers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final member = contactsController.selectedGroupMembers[index];
                return ListTile(
                  dense: true,
                  leading: _StatusDot(isOnline: member.profile.isOnline),
                  title: Text(
                    member.profile.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(member.role),
                  trailing: selectedGroup.isAdmin ||
                          member.profile.id ==
                              contactsController.authController.user?.id
                      ? IconButton(
                          tooltip: member.profile.id ==
                                  contactsController.authController.user?.id
                              ? 'Leave group'
                              : 'Remove member',
                          onPressed: () => contactsController
                              .removeSelectedGroupMember(member),
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                        )
                      : null,
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.isOnline});

  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isOnline ? const Color(0xFF38E07B) : const Color(0xFF5A1F2A),
        boxShadow: isOnline
            ? const [
                BoxShadow(
                  color: Color(0x6638E07B),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
    );
  }
}

class LoginView extends StatelessWidget {
  const LoginView({super.key, required this.authController});

  final AuthController authController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.graphic_eq_rounded,
                    size: 58,
                    color: Color(0xFF38E07B),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Walkie Talkie',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    authController.authMessage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white60,
                          letterSpacing: 0,
                        ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: authController.signingIn
                        ? null
                        : authController.signInWithGoogle,
                    icon: authController.signingIn
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_rounded),
                    label: Text(
                      authController.signingIn
                          ? 'Waiting for Google...'
                          : 'Continue with Google',
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: const Color(0xFF38E07B),
                      foregroundColor: const Color(0xFF101216),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.displayName,
    required this.status,
    required this.lastSeenAt,
  });

  final String id;
  final String email;
  final String displayName;
  final String status;
  final DateTime? lastSeenAt;

  bool get isOnline {
    final seenAt = lastSeenAt;
    if (status != 'online' || seenAt == null) return false;
    return DateTime.now().toUtc().difference(seenAt.toUtc()).inSeconds < 45;
  }

  String get label => displayName.isEmpty ? email : displayName;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String,
      email: (json['email'] as String?) ?? '',
      displayName: (json['display_name'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'offline',
      lastSeenAt: json['last_seen_at'] == null
          ? null
          : DateTime.tryParse(json['last_seen_at'] as String),
    );
  }
}

class ContactRequest {
  const ContactRequest({
    required this.id,
    required this.sender,
    required this.createdAt,
  });

  final String id;
  final UserProfile sender;
  final DateTime? createdAt;

  factory ContactRequest.fromJson(Map<String, dynamic> json) {
    return ContactRequest(
      id: json['id'] as String,
      sender: UserProfile.fromJson(
        Map<String, dynamic>.from(json['sender'] as Map),
      ),
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'] as String),
    );
  }
}

class TalkGroup {
  const TalkGroup({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.myRole,
  });

  final String id;
  final String name;
  final String createdBy;
  final String myRole;

  bool get isAdmin => myRole == 'admin';

  factory TalkGroup.fromMembershipJson(Map<String, dynamic> json) {
    final group = Map<String, dynamic>.from(json['group'] as Map);
    return TalkGroup(
      id: group['id'] as String,
      name: (group['name'] as String?) ?? 'Untitled group',
      createdBy: group['created_by'] as String,
      myRole: (json['role'] as String?) ?? 'member',
    );
  }
}

class GroupMember {
  const GroupMember({
    required this.profile,
    required this.role,
  });

  final UserProfile profile;
  final String role;

  bool get isAdmin => role == 'admin';

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      profile: UserProfile.fromJson(
        Map<String, dynamic>.from(json['profile'] as Map),
      ),
      role: (json['role'] as String?) ?? 'member',
    );
  }
}

class PokeNotice {
  const PokeNotice({
    required this.id,
    required this.sender,
    required this.createdAt,
  });

  final String id;
  final UserProfile sender;
  final DateTime? createdAt;

  factory PokeNotice.fromJson(Map<String, dynamic> json) {
    return PokeNotice(
      id: json['id'] as String,
      sender: UserProfile.fromJson(
        Map<String, dynamic>.from(json['sender'] as Map),
      ),
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'] as String),
    );
  }
}

class ContactsController extends ChangeNotifier {
  ContactsController(this.authController);

  final AuthController authController;
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController emailController = TextEditingController();
  final TextEditingController groupNameController = TextEditingController();
  final TextEditingController groupMemberEmailController =
      TextEditingController();

  StreamSubscription<AuthState>? _authSubscription;
  Timer? _refreshTimer;
  Timer? _heartbeatTimer;

  UserProfile? myProfile;
  UserProfile? selectedContact;
  TalkGroup? selectedGroup;
  List<UserProfile> contacts = [];
  List<ContactRequest> incomingRequests = [];
  List<TalkGroup> groups = [];
  List<GroupMember> selectedGroupMembers = [];
  List<PokeNotice> incomingPokes = [];
  bool online = true;
  bool loading = false;
  String message = 'Add a colleague by email.';

  Future<void> start() async {
    _authSubscription = _client.auth.onAuthStateChange.listen((data) {
      if (data.session?.user == null) {
        _clear();
      } else {
        bootstrap();
      }
    });

    if (authController.user != null) {
      await bootstrap();
    }
  }

  Future<void> bootstrap() async {
    final user = authController.user;
    if (user == null) return;

    loading = true;
    notifyListeners();
    await _ensureProfile(user);
    await setOnline(true);
    await refresh();

    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) => refresh(silent: true),
    );
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _heartbeat(),
    );
    loading = false;
    notifyListeners();
  }

  Future<void> _ensureProfile(User user) async {
    final metadata = user.userMetadata ?? <String, dynamic>{};
    final email = (user.email ?? '').toLowerCase();
    final displayName =
        (metadata['full_name'] ?? metadata['name'] ?? email.split('@').first)
            .toString();

    await _client.from('profiles').upsert({
      'id': user.id,
      'email': email,
      'display_name': displayName,
      'avatar_url': metadata['avatar_url'],
      'status': online ? 'online' : 'offline',
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> refresh({bool silent = false}) async {
    final user = authController.user;
    if (user == null) return;

    if (!silent) {
      loading = true;
      notifyListeners();
    }

    try {
      final profileRows =
          await _client.from('profiles').select().eq('id', user.id).limit(1);
      final profileList = List<Map<String, dynamic>>.from(profileRows as List);
      if (profileList.isNotEmpty) {
        myProfile = UserProfile.fromJson(profileList.first);
        online = myProfile?.status == 'online';
      }

      final contactRows = await _client
          .from('contacts')
          .select(
            'user:profiles!contacts_user_id_fkey(*), '
            'contact:profiles!contacts_contact_id_fkey(*)',
          )
          .or('user_id.eq.${user.id},contact_id.eq.${user.id}')
          .order('created_at');
      final contactMap = <String, UserProfile>{};
      for (final row in List<Map<String, dynamic>>.from(contactRows as List)) {
        final rowUser = UserProfile.fromJson(
          Map<String, dynamic>.from(row['user'] as Map),
        );
        final rowContact = UserProfile.fromJson(
          Map<String, dynamic>.from(row['contact'] as Map),
        );
        final other = rowUser.id == user.id ? rowContact : rowUser;
        contactMap[other.id] = other;
      }
      contacts = contactMap.values.toList();

      if (selectedContact == null && contacts.isNotEmpty) {
        selectedContact = contacts.first;
      } else if (selectedContact != null) {
        selectedContact = contacts
            .where((contact) => contact.id == selectedContact!.id)
            .cast<UserProfile?>()
            .firstWhere((contact) => contact != null, orElse: () => null);
      }

      final requestRows = await _client
          .from('contact_requests')
          .select(
              'id, created_at, sender:profiles!contact_requests_sender_id_fkey(*)')
          .eq('receiver_id', user.id)
          .eq('status', 'pending')
          .order('created_at');
      incomingRequests = List<Map<String, dynamic>>.from(requestRows as List)
          .map(ContactRequest.fromJson)
          .toList();

      final groupRows = await _client
          .from('group_members')
          .select('role, group:groups!group_members_group_id_fkey(*)')
          .eq('user_id', user.id)
          .order('created_at');
      groups = List<Map<String, dynamic>>.from(groupRows as List)
          .map(TalkGroup.fromMembershipJson)
          .toList();

      if (selectedGroup != null) {
        selectedGroup = groups
            .where((group) => group.id == selectedGroup!.id)
            .cast<TalkGroup?>()
            .firstWhere((group) => group != null, orElse: () => null);
      }
      if (selectedGroup != null) {
        await _refreshSelectedGroupMembers();
      } else {
        selectedGroupMembers = [];
      }

      final pokeRows = await _client
          .from('pokes')
          .select('id, created_at, sender:profiles!pokes_sender_id_fkey(*)')
          .eq('receiver_id', user.id)
          .eq('status', 'pending')
          .order('created_at');
      incomingPokes = List<Map<String, dynamic>>.from(pokeRows as List)
          .map(PokeNotice.fromJson)
          .toList();

      message = contacts.isEmpty
          ? 'Add a colleague by email.'
          : '${contacts.length} contact${contacts.length == 1 ? '' : 's'} ready.';
    } catch (error) {
      message = 'Supabase data error: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> addContactByEmail() async {
    final user = authController.user;
    if (user == null) return;

    final email = emailController.text.trim().toLowerCase();
    if (email.isEmpty) return;
    if (email == user.email?.toLowerCase()) {
      message = 'You cannot add yourself.';
      notifyListeners();
      return;
    }

    loading = true;
    notifyListeners();

    try {
      final rows =
          await _client.from('profiles').select().eq('email', email).limit(1);
      final matches = List<Map<String, dynamic>>.from(rows as List);
      if (matches.isEmpty) {
        message = 'No signed-up user found for $email.';
        return;
      }

      final receiver = UserProfile.fromJson(matches.first);
      await _client.from('contact_requests').upsert({
        'sender_id': user.id,
        'receiver_id': receiver.id,
        'status': 'pending',
      });
      emailController.clear();
      message = 'Request sent to ${receiver.email}.';
    } catch (error) {
      message = 'Could not send request: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> approveRequest(ContactRequest request) async {
    loading = true;
    notifyListeners();
    try {
      await _client.rpc(
        'approve_contact_request',
        params: {'request_id': request.id},
      );
      message = 'Added ${request.sender.email}.';
      await refresh(silent: true);
    } catch (error) {
      message = 'Could not approve request: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> deleteContact(UserProfile contact) async {
    loading = true;
    notifyListeners();
    try {
      await _client.rpc(
        'delete_contact',
        params: {'other_user_id': contact.id},
      );
      contacts.removeWhere((item) => item.id == contact.id);
      if (selectedContact?.id == contact.id) {
        selectedContact = contacts.isEmpty ? null : contacts.first;
      }
      message = 'Removed ${contact.email}.';
      await refresh(silent: true);
    } catch (error) {
      message = 'Could not remove contact: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> declineRequest(ContactRequest request) async {
    loading = true;
    notifyListeners();
    try {
      await _client
          .from('contact_requests')
          .update({'status': 'declined'}).eq('id', request.id);
      incomingRequests.removeWhere((item) => item.id == request.id);
      message = 'Request declined.';
    } catch (error) {
      message = 'Could not decline request: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setOnline(bool value) async {
    final user = authController.user;
    if (user == null) return;

    online = value;
    await _client.from('profiles').update({
      'status': value ? 'online' : 'offline',
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', user.id);
    await refresh(silent: true);
  }

  void selectContact(UserProfile contact) {
    selectedContact = contact;
    selectedGroup = null;
    selectedGroupMembers = [];
    message = contact.isOnline
        ? 'Ready to talk to ${contact.label}.'
        : '${contact.label} is offline.';
    notifyListeners();
  }

  Future<void> createGroup() async {
    final name = groupNameController.text.trim();
    if (name.isEmpty) return;

    loading = true;
    notifyListeners();
    try {
      await _client.rpc(
        'create_group',
        params: {'group_name': name},
      );
      groupNameController.clear();
      message = 'Group created.';
      await refresh(silent: true);
    } catch (error) {
      message = 'Could not create group: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> selectGroup(TalkGroup group) async {
    selectedGroup = group;
    selectedContact = null;
    message = 'Group ${group.name} selected.';
    notifyListeners();
    await _refreshSelectedGroupMembers();
    notifyListeners();
  }

  Future<void> addSelectedGroupMember() async {
    final group = selectedGroup;
    if (group == null || !group.isAdmin) return;

    final email = groupMemberEmailController.text.trim().toLowerCase();
    if (email.isEmpty) return;

    loading = true;
    notifyListeners();
    try {
      await _client.rpc(
        'add_group_member',
        params: {
          'target_group_id': group.id,
          'member_email': email,
        },
      );
      groupMemberEmailController.clear();
      message = 'Group member added.';
      await _refreshSelectedGroupMembers();
    } catch (error) {
      message = 'Could not add group member: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> removeSelectedGroupMember(GroupMember member) async {
    final group = selectedGroup;
    if (group == null) return;

    loading = true;
    notifyListeners();
    try {
      await _client.rpc(
        'remove_group_member',
        params: {
          'target_group_id': group.id,
          'target_member_id': member.profile.id,
        },
      );
      message = member.profile.id == authController.user?.id
          ? 'You left ${group.name}.'
          : 'Removed ${member.profile.email}.';
      if (member.profile.id == authController.user?.id) {
        selectedGroup = null;
        selectedGroupMembers = [];
        await refresh(silent: true);
      } else {
        await _refreshSelectedGroupMembers();
      }
    } catch (error) {
      message = 'Could not remove group member: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> sendPoke(UserProfile contact) async {
    loading = true;
    notifyListeners();
    try {
      await _client.rpc(
        'send_poke',
        params: {'target_user_id': contact.id},
      );
      message = 'Poked ${contact.label}.';
    } catch (error) {
      message = 'Could not send poke: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> clearPokeFrom(String userId) async {
    incomingPokes.removeWhere((poke) => poke.sender.id == userId);
    notifyListeners();
    try {
      await _client.rpc(
        'clear_poke_from',
        params: {'target_user_id': userId},
      );
    } catch (_) {}
  }

  bool hasPokeFrom(String userId) {
    return incomingPokes.any((poke) => poke.sender.id == userId);
  }

  Future<void> _refreshSelectedGroupMembers() async {
    final group = selectedGroup;
    if (group == null) return;

    final rows = await _client
        .from('group_members')
        .select('role, profile:profiles!group_members_user_id_fkey(*)')
        .eq('group_id', group.id)
        .order('created_at');
    selectedGroupMembers = List<Map<String, dynamic>>.from(rows as List)
        .map(GroupMember.fromJson)
        .toList();
  }

  Future<void> _heartbeat() async {
    final user = authController.user;
    if (user == null || !online) return;
    await _client.from('profiles').update({
      'status': 'online',
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', user.id);
  }

  Future<void> goOffline() async {
    await setOnline(false);
  }

  void _clear() {
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    myProfile = null;
    selectedContact = null;
    selectedGroup = null;
    contacts = [];
    groups = [];
    selectedGroupMembers = [];
    incomingRequests = [];
    incomingPokes = [];
    online = false;
    message = 'Signed out';
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    emailController.dispose();
    groupNameController.dispose();
    groupMemberEmailController.dispose();
    super.dispose();
  }
}

class WalkieTalkieController extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();
  RawPcmMediaKitPlayer? _playback;

  WebSocket? _socket;
  StreamSubscription<Uint8List>? _micSubscription;
  Timer? _reconnectTimer;

  TalkState state = TalkState.disconnected;
  String notice = 'Connecting to $_serverUri';
  int receivedChunks = 0;
  int receivedBytes = 0;
  bool connected = false;
  bool remoteTalking = false;
  bool _holdingToTalk = false;
  bool _streamingMic = false;
  bool _disposed = false;
  String? _userId;
  List<String> _recipientIds = [];

  void setIdentity(String? userId) {
    _userId = userId;
    if (connected && userId != null) {
      _socket?.add('HELLO|$userId');
    }
  }

  void setRecipients(List<String> recipientIds) {
    _recipientIds = recipientIds.where((id) => id.isNotEmpty).toSet().toList();
  }

  Future<void> start() async {
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _setConnection(false, 'Connecting to $_serverUri');

    try {
      final socket = await WebSocket.connect(_serverUri);
      socket.pingInterval = const Duration(seconds: 15);
      _socket = socket;
      _setConnection(true, 'Connected');
      if (_userId != null) {
        socket.add('HELLO|$_userId');
      }
      socket.listen(
        _handleSocketMessage,
        onDone: _handleDisconnect,
        onError: (Object error) => _handleDisconnect(error),
        cancelOnError: true,
      );
    } catch (error) {
      _setConnection(false, 'Server unavailable. Retrying...');
      _scheduleReconnect();
    }
  }

  void _handleSocketMessage(dynamic message) {
    if (message is String) {
      switch (message) {
        case 'MIC_GRANTED':
          remoteTalking = false;
          notice = 'Mic granted';
          if (_holdingToTalk) {
            _startStreamingMic();
          }
          break;
        case 'MIC_DENIED':
          _stopStreamingMic(sendRelease: false);
          state = TalkState.busy;
          notice = 'Line busy. Another user has the mic.';
          notifyListeners();
          break;
        case 'MIC_RELEASED':
          remoteTalking = false;
          if (!_streamingMic) {
            state = connected ? TalkState.idle : TalkState.disconnected;
            notice = connected ? 'Ready' : 'Disconnected';
            notifyListeners();
          }
          break;
        case 'REMOTE_TALKING_STARTED':
          remoteTalking = true;
          if (!_streamingMic) {
            state = TalkState.busy;
            notice = 'Another user is talking';
            notifyListeners();
          }
          break;
        case 'REMOTE_TALKING_STOPPED':
          remoteTalking = false;
          if (!_streamingMic) {
            state = connected ? TalkState.idle : TalkState.disconnected;
            notice = connected ? 'Ready' : 'Disconnected';
            notifyListeners();
          }
          break;
        default:
          notice = message;
          notifyListeners();
          break;
      }
      return;
    }

    if (message is List<int>) {
      receivedChunks++;
      receivedBytes += message.length;
      if (state != TalkState.transmitting) {
        remoteTalking = true;
        state = TalkState.busy;
        notice = 'Another user is talking';
      }
      notifyListeners();
      debugPrint('received audio chunk: ${message.length} bytes');
      (_playback ??= RawPcmMediaKitPlayer()).addPcmChunk(
        Uint8List.fromList(message),
        onError: (error) {
          notice = 'Playback failed: $error';
          notifyListeners();
        },
      );
    }
  }

  void _handleDisconnect([Object? error]) {
    _socket = null;
    _stopStreamingMic(sendRelease: false);
    _setConnection(false, 'Disconnected. Retrying...');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _connect);
  }

  Future<void> requestMic() async {
    if (!connected ||
        _socket == null ||
        _holdingToTalk ||
        state == TalkState.busy) {
      return;
    }

    _holdingToTalk = true;
    state = TalkState.requesting;
    notice = 'Requesting mic...';
    notifyListeners();
    if (_recipientIds.isEmpty) {
      _socket?.add('REQUEST_MIC');
    } else {
      _socket?.add('REQUEST_MIC|${_recipientIds.join(',')}');
    }
  }

  Future<void> releaseMic() async {
    if (!_holdingToTalk && !_streamingMic) return;
    _holdingToTalk = false;
    await _stopStreamingMic(sendRelease: true);
    if (connected) {
      state = TalkState.idle;
      notice = 'Ready';
      notifyListeners();
    }
  }

  void setNotice(String value) {
    notice = value;
    notifyListeners();
  }

  Future<void> _startStreamingMic() async {
    if (_streamingMic || _socket == null) return;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      state = TalkState.idle;
      notice = 'Microphone permission is required';
      _socket?.add('RELEASE_MIC');
      notifyListeners();
      return;
    }

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: _channels,
      ),
    );

    _streamingMic = true;
    state = TalkState.transmitting;
    notice = 'Transmitting';
    notifyListeners();

    _micSubscription = stream.listen(
      (chunk) {
        if (_streamingMic && connected) {
          _socket?.add(chunk);
        }
      },
      onError: (Object error) {
        notice = 'Microphone stream failed: $error';
        releaseMic();
      },
      cancelOnError: true,
    );
  }

  Future<void> _stopStreamingMic({required bool sendRelease}) async {
    if (_streamingMic) {
      _streamingMic = false;
      await _micSubscription?.cancel();
      _micSubscription = null;
      await _recorder.stop();
    }

    if (sendRelease && connected) {
      _socket?.add('RELEASE_MIC');
    }
  }

  void _setConnection(bool isConnected, String message) {
    connected = isConnected;
    remoteTalking = false;
    state = isConnected ? TalkState.idle : TalkState.disconnected;
    notice = message;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    await _stopStreamingMic(sendRelease: connected);
    await _socket?.close();
    await _recorder.dispose();
    await _playback?.dispose();
    super.dispose();
  }
}

class RawPcmMediaKitPlayer {
  static const int _targetBatchBytes = 9600;

  final Player _player = Player(
    configuration: const PlayerConfiguration(
      title: 'Walkie Talkie Receiver',
      bufferSize: 64 * 1024,
    ),
  );
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _opened = false;
  Timer? _flushTimer;
  Future<void> _queue = Future<void>.value();

  void addPcmChunk(
    Uint8List pcm, {
    void Function(Object error)? onError,
  }) {
    if (pcm.isEmpty) return;
    _buffer.add(pcm);

    if (_buffer.length >= _targetBatchBytes) {
      _flush(onError: onError);
      return;
    }

    _flushTimer?.cancel();
    _flushTimer = Timer(
      const Duration(milliseconds: 120),
      () => _flush(onError: onError),
    );
  }

  void _flush({void Function(Object error)? onError}) {
    if (_buffer.isEmpty) return;
    final pcm = _buffer.takeBytes();
    _queue = _queue.then((_) => _play(pcm)).catchError((Object error) {
      onError?.call(error);
    });
  }

  Future<void> _play(Uint8List pcm) async {
    final media = await Media.memory(_wavFromPcm(pcm), type: 'audio/wav');
    if (_opened) {
      await _player.add(media);
    } else {
      _opened = true;
      await _player.open(media, play: true);
      await _player.setVolume(100);
    }
  }

  Uint8List _wavFromPcm(Uint8List pcm) {
    const byteRate = _sampleRate * _channels * _bitsPerSample ~/ 8;
    const blockAlign = _channels * _bitsPerSample ~/ 8;
    final dataLength = pcm.length;
    final totalLength = 44 + dataLength;
    final bytes = Uint8List(totalLength);
    final data = ByteData.view(bytes.buffer);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, 36 + dataLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, _channels, Endian.little);
    data.setUint32(24, _sampleRate, Endian.little);
    data.setUint32(28, byteRate, Endian.little);
    data.setUint16(32, blockAlign, Endian.little);
    data.setUint16(34, _bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, dataLength, Endian.little);
    bytes.setRange(44, totalLength, pcm);
    return bytes;
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flush();
    await _queue;
    await _player.dispose();
  }
}

class WalkieTalkieHome extends StatelessWidget {
  const WalkieTalkieHome({
    super.key,
    required this.controller,
    this.authController,
    this.contactsController,
  });

  final WalkieTalkieController controller;
  final AuthController? authController;
  final ContactsController? contactsController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final contact = contactsController?.selectedContact;
        final group = contactsController?.selectedGroup;
        final canTalk = contactsController == null ||
            ((contactsController?.online ?? true) &&
                ((contact?.isOnline ?? false) || group != null));
        return Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final buttonSize = constraints.maxHeight < 650 ? 220.0 : 280.0;
              return Padding(
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 22),
                child: Column(
                  children: [
                    _Header(controller: controller),
                    const SizedBox(height: 22),
                    _SelectedContactHeader(contact: contact, group: group),
                    const Spacer(),
                    PushToTalkButton(
                      controller: controller,
                      size: buttonSize,
                      enabled: canTalk,
                      disabledLabel: _disabledTalkLabel(
                        contactsController: contactsController,
                        contact: contact,
                        group: group,
                      ),
                      onStartTalk: () {
                        if (contact != null) {
                          contactsController?.clearPokeFrom(contact.id);
                        }
                      },
                    ),
                    const Spacer(),
                    _TalkFooter(
                      message: canTalk
                          ? controller.notice
                          : _disabledTalkNotice(
                              contact: contact,
                              group: group,
                            ),
                      receivedChunks: controller.receivedChunks,
                      receivedBytes: controller.receivedBytes,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  String _disabledTalkLabel({
    required ContactsController? contactsController,
    required UserProfile? contact,
    required TalkGroup? group,
  }) {
    if (group != null) return 'GROUP TALK';
    if (contact == null) return 'SELECT USER';
    if (!(contactsController?.online ?? true)) return 'YOU ARE OFFLINE';
    if (!contact.isOnline) return 'USER OFFLINE';
    return 'UNAVAILABLE';
  }

  String _disabledTalkNotice({
    required UserProfile? contact,
    required TalkGroup? group,
  }) {
    if (group != null) return 'Set yourself online to talk in this group.';
    if (contact == null) return 'Select an online contact to start talking.';
    if (!contact.isOnline) return '${contact.label} is offline.';
    return 'Set yourself online to talk.';
  }
}

class _SelectedContactHeader extends StatelessWidget {
  const _SelectedContactHeader({
    required this.contact,
    required this.group,
  });

  final UserProfile? contact;
  final TalkGroup? group;

  @override
  Widget build(BuildContext context) {
    if (group != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.groups_rounded, color: Color(0xFF38E07B)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              group!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
            ),
          ),
        ],
      );
    }

    if (contact == null) {
      return Text(
        'No contact selected',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StatusDot(isOnline: contact!.isOnline),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            contact!.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
          ),
        ),
      ],
    );
  }
}

class _TalkFooter extends StatelessWidget {
  const _TalkFooter({
    required this.message,
    required this.receivedChunks,
    required this.receivedBytes,
  });

  final String message;
  final int receivedChunks;
  final int receivedBytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white70,
                letterSpacing: 0,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          Platform.isWindows
              ? 'Hold the mic button'
              : 'Hold Caps Lock or Left Ctrl',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white38,
                letterSpacing: 0,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Received $receivedChunks chunks / $receivedBytes bytes',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white30,
                letterSpacing: 0,
              ),
        ),
      ],
    );
  }
}

class _AccountStrip extends StatelessWidget {
  const _AccountStrip({required this.authController});

  final AuthController authController;

  @override
  Widget build(BuildContext context) {
    final email = authController.user?.email ?? 'Google user';
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF181B21),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.account_circle_rounded,
            color: Color(0xFF38E07B),
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
            ),
          ),
          TextButton.icon(
            onPressed: authController.signOut,
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Sign Out'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final WalkieTalkieController controller;

  @override
  Widget build(BuildContext context) {
    final connected = controller.connected;
    return Row(
      children: [
        const Icon(Icons.graphic_eq_rounded,
            size: 34, color: Color(0xFF38E07B)),
        const SizedBox(width: 12),
        Text(
          'Walkie Talkie',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
        ),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color:
                connected ? const Color(0xFF38E07B) : const Color(0xFFFF4D5E),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: (connected
                        ? const Color(0xFF38E07B)
                        : const Color(0xFFFF4D5E))
                    .withValues(alpha: 0.45),
                blurRadius: 18,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          connected ? 'Online' : 'Offline',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white70,
                letterSpacing: 0,
              ),
        ),
      ],
    );
  }
}

class PushToTalkButton extends StatelessWidget {
  const PushToTalkButton({
    super.key,
    required this.controller,
    this.size = 280,
    this.enabled = true,
    this.disabledLabel,
    this.onStartTalk,
  });

  final WalkieTalkieController controller;
  final double size;
  final bool enabled;
  final String? disabledLabel;
  final FutureOr<void> Function()? onStartTalk;

  @override
  Widget build(BuildContext context) {
    final style = enabled
        ? _buttonStyle(controller.state, controller.remoteTalking)
        : _PttButtonStyle(
            label: disabledLabel ?? 'UNAVAILABLE',
            icon: Icons.block_rounded,
            color: const Color(0xFF30343B),
            border: const Color(0xFF565D68),
            glow: const Color(0x33565D68),
          );
    final disabled = controller.state == TalkState.busy ||
        controller.state == TalkState.disconnected ||
        !enabled;

    return GestureDetector(
      onTapDown: disabled
          ? null
          : (_) async {
              await onStartTalk?.call();
              await controller.requestMic();
            },
      onTapUp: disabled ? null : (_) => controller.releaseMic(),
      onTapCancel: disabled ? null : controller.releaseMic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: style.color,
          border: Border.all(color: style.border, width: 2),
          boxShadow: [
            BoxShadow(
              color: style.glow,
              blurRadius: controller.state == TalkState.transmitting ? 64 : 28,
              spreadRadius: controller.state == TalkState.transmitting ? 10 : 2,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(style.icon, size: size * 0.26, color: Colors.white),
            SizedBox(height: size * 0.06),
            Text(
              style.label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                    fontSize: size < 240 ? 24 : null,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  _PttButtonStyle _buttonStyle(TalkState state, bool remoteTalking) {
    switch (state) {
      case TalkState.transmitting:
        return const _PttButtonStyle(
          label: 'TRANSMITTING',
          icon: Icons.mic_rounded,
          color: Color(0xFF148F46),
          border: Color(0xFF70F0A4),
          glow: Color(0xAA38E07B),
        );
      case TalkState.busy:
        return _PttButtonStyle(
          label: remoteTalking ? 'LISTENING' : 'LINE BUSY',
          icon: remoteTalking ? Icons.volume_up_rounded : Icons.block_rounded,
          color: const Color(0xFF8D1D2B),
          border: const Color(0xFFFF6B78),
          glow: const Color(0x77FF4D5E),
        );
      case TalkState.requesting:
        return const _PttButtonStyle(
          label: 'REQUESTING',
          icon: Icons.hourglass_top_rounded,
          color: Color(0xFF444B56),
          border: Color(0xFF7C8797),
          glow: Color(0x557C8797),
        );
      case TalkState.disconnected:
        return const _PttButtonStyle(
          label: 'OFFLINE',
          icon: Icons.wifi_off_rounded,
          color: Color(0xFF30343B),
          border: Color(0xFF565D68),
          glow: Color(0x33565D68),
        );
      case TalkState.idle:
        return const _PttButtonStyle(
          label: 'PUSH TO TALK',
          icon: Icons.mic_none_rounded,
          color: Color(0xFF3B4048),
          border: Color(0xFF626A76),
          glow: Color(0x44626A76),
        );
    }
  }
}

class _PttButtonStyle {
  const _PttButtonStyle({
    required this.label,
    required this.icon,
    required this.color,
    required this.border,
    required this.glow,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color border;
  final Color glow;
}
