import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as lnp;
import 'package:flutter_nearby_connections/flutter_nearby_connections.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _supabaseUrl = 'https://jziefknvztxxllogiwba.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp6aWVma252enR4eGxsb2dpd2JhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk2MjI1MzUsImV4cCI6MjA4NTE5ODUzNX0.uQzvXMfLT4spxhTjerxdarcMR8-f5l2KDpby-9Q1bAg';
const _darkModePrefsKey = 'app_dark_mode_v1';
final ValueNotifier<bool> _darkModeNotifier = ValueNotifier<bool>(false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  await _initLocalNotifications();
  final prefs = await SharedPreferences.getInstance();
  _darkModeNotifier.value = prefs.getBool(_darkModePrefsKey) ?? false;
  runApp(const VMessagesApp());
}

final lnp.FlutterLocalNotificationsPlugin _localNotifications =
    lnp.FlutterLocalNotificationsPlugin();

Future<void> _initLocalNotifications() async {
  const initSettings = lnp.InitializationSettings(
    android: lnp.AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: lnp.DarwinInitializationSettings(),
    macOS: lnp.DarwinInitializationSettings(),
  );
  await _localNotifications.initialize(settings: initSettings);
}

class VMessagesApp extends StatelessWidget {
  const VMessagesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _darkModeNotifier,
      builder: (context, darkMode, _) {
        return CupertinoApp(
          debugShowCheckedModeBanner: false,
          title: 'VMessages',
          theme: CupertinoThemeData(
            brightness: darkMode ? Brightness.dark : Brightness.light,
            primaryColor: CupertinoColors.systemBlue,
            scaffoldBackgroundColor: darkMode
                ? const Color(0xFF000000)
                : CupertinoColors.systemGroupedBackground,
          ),
          home: const RootSessionGate(),
        );
      },
    );
  }
}

Future<void> _setDarkMode(bool value) async {
  _darkModeNotifier.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_darkModePrefsKey, value);
}

class RootSessionGate extends StatelessWidget {
  const RootSessionGate({super.key});

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      initialData: AuthState(
        AuthChangeEvent.initialSession,
        client.auth.currentSession,
      ),
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? client.auth.currentSession;
        if (session == null) return const PhonePasswordAuthScreen();
        return AuthenticatedBootstrap(session: session);
      },
    );
  }
}

enum AuthMode { signIn, signUp }

class PhonePasswordAuthScreen extends StatefulWidget {
  const PhonePasswordAuthScreen({super.key});

  @override
  State<PhonePasswordAuthScreen> createState() =>
      _PhonePasswordAuthScreenState();
}

class _PhonePasswordAuthScreenState extends State<PhonePasswordAuthScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  AuthMode _mode = AuthMode.signIn;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String _phoneToEmail(String phone) {
    final normalized = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    return '${normalized.replaceAll('+', 'plus')}@vmessages.local';
  }

  Future<void> _submitAuth() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();

    if (phone.isEmpty || code.length < 4) {
      setState(() {
        _error =
            'Ingresa un telefono valido y un codigo de al menos 4 digitos.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final email = _phoneToEmail(phone);
      final auth = Supabase.instance.client.auth;
      if (_mode == AuthMode.signUp) {
        await auth.signUp(email: email, password: code, data: {'phone': phone});
      } else {
        await auth.signInWithPassword(email: email, password: code);
      }
      await _saveOrUpdateProfileCode(phone: phone, code: code);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo completar la autenticacion.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveOrUpdateProfileCode({
    required String phone,
    required String code,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final profile = await Supabase.instance.client
        .from('profiles')
        .select('access_code,avatar_url')
        .eq('id', user.id)
        .maybeSingle();

    if (profile?['access_code']?.toString() == code) return;

    await Supabase.instance.client.from('profiles').upsert({
      'id': user.id,
      'phone': phone,
      'display_name': phone,
      'access_code': code,
      'avatar_url': profile?['avatar_url'],
    });
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Accede a tu cuenta',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: CupertinoColors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Usa tu telefono y codigo personal.',
                    style: TextStyle(color: CupertinoColors.systemGrey),
                  ),
                  const SizedBox(height: 24),
                  CupertinoSlidingSegmentedControl<AuthMode>(
                    groupValue: _mode,
                    children: const {
                      AuthMode.signIn: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('Iniciar sesion'),
                      ),
                      AuthMode.signUp: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('Registrarme'),
                      ),
                    },
                    onValueChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _mode = value;
                        _error = null;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  _IOSField(
                    child: CupertinoTextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      placeholder: 'Numero de telefono (+525512345678)',
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _IOSField(
                    child: CupertinoTextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      placeholder: 'Codigo personal',
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Minimo 4 caracteres',
                    style: TextStyle(
                      color: CupertinoColors.systemGrey,
                      fontSize: 13,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoButton.filled(
                      onPressed: _loading ? null : _submitAuth,
                      child: _loading
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            )
                          : Text(
                              _mode == AuthMode.signIn
                                  ? 'Iniciar sesion'
                                  : 'Crear cuenta',
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

class AuthenticatedBootstrap extends StatefulWidget {
  const AuthenticatedBootstrap({super.key, required this.session});

  final Session session;

  @override
  State<AuthenticatedBootstrap> createState() => _AuthenticatedBootstrapState();
}

class _AuthenticatedBootstrapState extends State<AuthenticatedBootstrap> {
  late final Future<void> _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _ensureProfile();
  }

  Future<void> _ensureProfile() async {
    final user = widget.session.user;
    final phone = user.userMetadata?['phone']?.toString() ?? 'Sin telefono';
    final profile = await Supabase.instance.client
        .from('profiles')
        .select('access_code,avatar_url')
        .eq('id', user.id)
        .maybeSingle();
    await Supabase.instance.client.from('profiles').upsert({
      'id': user.id,
      'phone': phone,
      'display_name': phone,
      'access_code': profile?['access_code'],
      'avatar_url': profile?['avatar_url'],
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const CupertinoPageScaffold(
            child: Center(child: CupertinoActivityIndicator(radius: 14)),
          );
        }

        if (snapshot.hasError) {
          return CupertinoPageScaffold(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error iniciando perfil: ${snapshot.error}'),
              ),
            ),
          );
        }

        return const MessagesHomePage();
      },
    );
  }
}

class MessagesHomePage extends StatefulWidget {
  const MessagesHomePage({super.key});

  @override
  State<MessagesHomePage> createState() => _MessagesHomePageState();
}

class _MessagesHomePageState extends State<MessagesHomePage> {
  final _client = Supabase.instance.client;
  final _bluetoothService = BluetoothNearbyService.instance;
  bool _creatingChat = false;
  late final Stream<List<Map<String, dynamic>>> _membershipStream;
  Timer? _homeRefreshFallbackTimer;
  Timer? _iosBluetoothKeepAliveTimer;
  Timer? _iosBackgroundHeartbeatTimer;
  bool _presenceRefreshInFlight = false;
  DateTime _lastPresenceRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _btBootstrapping = false;
  String? _btError;
  List<Device> _nearbyDevices = const [];
  final Map<String, Device> _recentNearbyDevicesById = <String, Device>{};
  final Map<String, DateTime> _recentNearbySeenAtById = <String, DateTime>{};
  static const Duration _nearbyDeviceRetention = Duration(seconds: 95);
  final Map<String, NearbyChatMeta> _nearbyMetaByDeviceId = {};
  StreamSubscription<BluetoothIncomingMessage>? _btIncomingSub;
  RealtimeChannel? _messageNotificationsChannel;
  bool _incomingBtCallDialogOpen = false;
  Timer? _incomingCallToneTimer;
  final AudioPlayer _incomingCallTonePlayer = AudioPlayer();
  Uint8List? _incomingCallToneBytes;
  String? _incomingCallToneFilePath;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  int _notificationIdCounter = 1000;
  final Set<String> _recentNotifiedMessageIds = <String>{};
  final List<String> _recentBtNotificationKeys = <String>[];
  static const String _btNotifDedupePrefsKey = 'bt_notif_dedupe_keys_v1';
  static const String _pendingWalkieInvitePrefsKey = 'bt_pending_walkie_invite_v1';
  bool _btNotifDedupeLoaded = false;
  Map<String, String>? _pendingWalkieInvite;
  bool _walkieInviteDialogOpen = false;
  bool get _isApplePeerSupported => Platform.isIOS || Platform.isMacOS;
  DateTime _lastRealtimeResubscribeAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _iosBackgroundBridge = IOSBackgroundTaskBridge();
  final _iosSilentAudioBridge = IOSSilentAudioBridge();
  String? _myBluetoothAvatarBase64;
  String? _myBluetoothAvatarHash;

  String get _currentUserId => _client.auth.currentUser!.id;

  Future<List<ConversationSummary>> _loadConversationSummaries(
    List<Map<String, dynamic>> membershipRows,
  ) async {
    final conversationIds = membershipRows
        .map((row) => row['conversation_id'].toString())
        .toList();
    if (conversationIds.isEmpty) return [];

    final readAtByConversation = <String, DateTime?>{};
    for (final row in membershipRows) {
      final conversationId = row['conversation_id'].toString();
      final readRaw = row['last_read_at']?.toString();
      readAtByConversation[conversationId] = readRaw == null
          ? null
          : DateTime.tryParse(readRaw)?.toUtc();
    }

    final otherMembers = await _client
        .from('conversation_members')
        .select('conversation_id,user_id')
        .inFilter('conversation_id', conversationIds)
        .neq('user_id', _currentUserId);

    final otherUserByConversation = <String, String>{};
    final otherUserIds = <String>{};
    for (final row in otherMembers) {
      final conversationId = row['conversation_id'].toString();
      final userId = row['user_id'].toString();
      otherUserByConversation[conversationId] = userId;
      otherUserIds.add(userId);
    }

    final profiles = otherUserIds.isEmpty
        ? <dynamic>[]
        : await _client
              .from('profiles')
              .select('id,phone,display_name,avatar_url')
              .inFilter('id', otherUserIds.toList());

    final profileById = <String, Map<String, dynamic>>{};
    for (final row in profiles) {
      profileById[row['id'].toString()] = Map<String, dynamic>.from(row);
    }

    final messages = await _client
        .from('messages')
        .select('id,conversation_id,body,created_at,sender_id')
        .inFilter('conversation_id', conversationIds)
        .order('created_at', ascending: false)
        .order('id', ascending: false);

    final lastMessageByConversation = <String, Map<String, dynamic>>{};
    for (final row in messages) {
      final conversationId = row['conversation_id'].toString();
      lastMessageByConversation.putIfAbsent(
        conversationId,
        () => Map<String, dynamic>.from(row),
      );
    }

    final summaries = <ConversationSummary>[];
    for (final conversationId in conversationIds) {
      final otherUserId = otherUserByConversation[conversationId];
      final profile = otherUserId == null ? null : profileById[otherUserId];
      final phone = profile?['phone']?.toString() ?? 'Sin numero';
      final displayName =
          profile?['display_name']?.toString().trim().isNotEmpty == true
          ? profile!['display_name'].toString()
          : phone;
      final lastMessage = lastMessageByConversation[conversationId];
      final rawLastBody = lastMessage?['body']?.toString();
      final lastBody = rawLastBody == null
          ? 'Sin mensajes aun'
          : (rawLastBody.startsWith('photo::') ? '📷 Foto' : rawLastBody);
      final createdAtRaw = lastMessage?['created_at']?.toString();
      final lastAt = createdAtRaw == null
          ? null
          : DateTime.tryParse(createdAtRaw)?.toLocal();
      final lastAtUtc = createdAtRaw == null
          ? null
          : DateTime.tryParse(createdAtRaw)?.toUtc();
      final readAtUtc = readAtByConversation[conversationId];
      final lastSenderId = lastMessage?['sender_id']?.toString();
      final hasUnread =
          lastAtUtc != null &&
          lastSenderId != _currentUserId &&
          (readAtUtc == null || lastAtUtc.isAfter(readAtUtc));

      summaries.add(
        ConversationSummary(
          id: conversationId,
          peerPhone: phone,
          peerDisplayName: displayName,
          peerAvatarUrl: profile?['avatar_url']?.toString(),
          lastMessage: lastBody,
          lastMessageAt: lastAt,
          hasUnread: hasUnread,
        ),
      );
    }

    summaries.sort((a, b) {
      final left = a.lastMessageAt?.millisecondsSinceEpoch ?? 0;
      final right = b.lastMessageAt?.millisecondsSinceEpoch ?? 0;
      return right.compareTo(left);
    });

    return summaries;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _configureIncomingCallTonePlayer();
    _membershipStream = _client
        .from('conversation_members')
        .stream(primaryKey: ['conversation_id', 'user_id'])
        .eq('user_id', _currentUserId);
    _homeRefreshFallbackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _initBluetoothNearby();
    _startBluetoothKeepAlive();
    _loadNearbyChatMeta();
    _loadMyBluetoothAvatarCache();
    _loadBtNotificationDedupeCache();
    _loadPendingWalkieInvite();
    _requestNotificationPermissions();
    _resubscribeMessageNotifications(force: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _homeRefreshFallbackTimer?.cancel();
    _iosBluetoothKeepAliveTimer?.cancel();
    _iosBackgroundHeartbeatTimer?.cancel();
    _btIncomingSub?.cancel();
    if (_messageNotificationsChannel != null) {
      _client.removeChannel(_messageNotificationsChannel!);
    }
    _stopIncomingCallTone();
    _incomingCallTonePlayer.dispose();
    if (_isApplePeerSupported) {
      _stopIOSBackgroundExecution();
      _bluetoothService.stop();
    }
    super.dispose();
  }

  Future<void> _initBluetoothNearby() async {
    if (!_isApplePeerSupported) return;
    setState(() {
      _btBootstrapping = true;
      _btError = null;
    });
    try {
      final phone =
          _client.auth.currentUser?.userMetadata?['phone']?.toString() ??
          'iPhone';
      await _bluetoothService.start(displayName: phone);
      _bluetoothService.devicesStream.listen((devices) {
        if (!mounted) return;
        final now = DateTime.now();
        for (final device in devices) {
          final id = device.deviceId.trim();
          if (id.isEmpty) continue;
          _recentNearbyDevicesById[id] = device;
          _recentNearbySeenAtById[id] = now;
        }
        _pruneStaleNearbyDevices();
        setState(() {
          _nearbyDevices = devices;
        });
        unawaited(_broadcastBluetoothPresence());
      });
      _btIncomingSub?.cancel();
      _btIncomingSub = _bluetoothService.messagesStream.listen((
        incoming,
      ) async {
        final body = _extractBtVisibleText(incoming.message);
        if (body.isEmpty) return;
        final resolvedId = _resolveNearbyDeviceId(incoming.deviceId);
        final incomingMsgId = _extractIncomingBtMsgId(body);
        if (incomingMsgId != null) {
          try {
            await _bluetoothService.sendText(
              resolvedId,
              'btack::${jsonEncode({'id': incomingMsgId})}',
            );
          } catch (_) {}
        }
        if (await _handleIncomingBtCallInvite(
          body: body,
          incomingDeviceId: resolvedId,
        )) {
          return;
        }
        if (await _handleIncomingBtWalkieInvite(
          body: body,
          incomingDeviceId: resolvedId,
          rawIncomingDeviceId: incoming.deviceId,
        )) {
          return;
        }
        if (_handleIncomingBtPresence(deviceId: resolvedId, body: body)) {
          return;
        }
        if (body.startsWith('btctl::')) {
          await _appendNearbyIncomingToHistory(deviceId: resolvedId, body: body);
          return;
        }
        if (body.startsWith('btack::') || body.startsWith('btseen::')) {
          return;
        }
        if (_isBluetoothControlPayload(body)) return;
        await _appendNearbyIncomingToHistory(deviceId: resolvedId, body: body);
        await _showBluetoothMessageNotificationIfNeeded(
          deviceId: resolvedId,
          body: body,
          rawIncoming: incoming.message,
        );
        final lastPreview = _notificationPreviewFromBluetoothBody(body);
        final updated = NearbyChatMeta(
          lastMessage: lastPreview,
          lastMessageAt: DateTime.now(),
          hasUnread: true,
          peerPresence:
              _nearbyMetaByDeviceId[resolvedId]?.peerPresence ?? 'online',
          peerPresenceAt: _nearbyMetaByDeviceId[resolvedId]?.peerPresenceAt,
          peerAvatarBase64:
              _nearbyMetaByDeviceId[resolvedId]?.peerAvatarBase64,
          peerAvatarHash: _nearbyMetaByDeviceId[resolvedId]?.peerAvatarHash,
        );
        if (!mounted) return;
        setState(() {
          _nearbyMetaByDeviceId[resolvedId] = updated;
        });
        await _saveNearbyChatMeta();
      });
      await _broadcastBluetoothPresence();
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _btError =
            'El plugin Bluetooth actual no incluye implementacion nativa para macOS en esta version.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _btError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _btBootstrapping = false;
        });
      }
    }
  }

  String? _extractIncomingBtMsgId(String body) {
    final clean = body.trim();
    if (!clean.startsWith('btmsg::')) return null;
    try {
      final payload = clean.replaceFirst('btmsg::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final id = map['id']?.toString().trim() ?? '';
      if (id.isEmpty) return null;
      return id;
    } catch (_) {
      return null;
    }
  }

  Future<void> _requestNotificationPermissions() async {
    if (Platform.isIOS) {
      final ios = _localNotifications
          .resolvePlatformSpecificImplementation<
            lnp.IOSFlutterLocalNotificationsPlugin
          >();
      await ios?.requestPermissions(alert: true, badge: true, sound: true);
      return;
    }
    if (Platform.isMacOS) {
      final mac = _localNotifications
          .resolvePlatformSpecificImplementation<
            lnp.MacOSFlutterLocalNotificationsPlugin
          >();
      await mac?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  void _subscribeMessageNotifications() {
    _messageNotificationsChannel = _client
        .channel('messages-notify-$_currentUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            _handleIncomingMessageNotification(payload.newRecord);
          },
        )
        .subscribe();
  }

  void _resubscribeMessageNotifications({bool force = false}) {
    final secondsSinceLast = DateTime.now()
        .difference(_lastRealtimeResubscribeAt)
        .inSeconds;
    if (!force && secondsSinceLast < 2) return;
    _lastRealtimeResubscribeAt = DateTime.now();
    if (_messageNotificationsChannel != null) {
      _client.removeChannel(_messageNotificationsChannel!);
      _messageNotificationsChannel = null;
    }
    _subscribeMessageNotifications();
  }

  Future<void> _handleIncomingMessageNotification(
    Map<String, dynamic> row,
  ) async {
    try {
      if (_appLifecycleState == AppLifecycleState.resumed) return;
      final messageId = row['id']?.toString() ?? '';
      if (messageId.isEmpty) return;
      if (_recentNotifiedMessageIds.contains(messageId)) return;

      final senderId = row['sender_id']?.toString() ?? '';
      if (senderId == _currentUserId) return;
      final conversationId = row['conversation_id']?.toString() ?? '';
      if (conversationId.isEmpty) return;

      final membership = await _client
          .from('conversation_members')
          .select('conversation_id')
          .eq('conversation_id', conversationId)
          .eq('user_id', _currentUserId)
          .maybeSingle();
      if (membership == null) return;

      final senderProfile = await _client
          .from('profiles')
          .select('display_name,phone')
          .eq('id', senderId)
          .maybeSingle();
      final senderName =
          senderProfile?['display_name']?.toString().trim().isNotEmpty == true
          ? senderProfile!['display_name'].toString().trim()
          : (senderProfile?['phone']?.toString() ?? 'Nuevo mensaje');

      final rawBody = row['body']?.toString() ?? '';
      final body = rawBody.startsWith('photo::')
          ? '📷 Foto'
          : rawBody.trim().isEmpty
          ? 'Nuevo mensaje'
          : rawBody;

      const details = lnp.NotificationDetails(
        iOS: lnp.DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        macOS: lnp.DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );
      _notificationIdCounter++;
      await _localNotifications.show(
        id: _notificationIdCounter,
        title: senderName,
        body: body,
        notificationDetails: details,
      );
      _recentNotifiedMessageIds.add(messageId);
      if (_recentNotifiedMessageIds.length > 300) {
        _recentNotifiedMessageIds.remove(_recentNotifiedMessageIds.first);
      }
    } catch (_) {}
  }

  Future<void> _showBluetoothMessageNotificationIfNeeded({
    required String deviceId,
    required String body,
    required String rawIncoming,
  }) async {
    try {
      if (_appLifecycleState == AppLifecycleState.resumed) return;
      if (!_btNotifDedupeLoaded) {
        await _loadBtNotificationDedupeCache();
      }
      final key = _buildBluetoothNotificationKey(
        deviceId: deviceId,
        body: body,
        rawIncoming: rawIncoming,
      );
      if (_recentBtNotificationKeys.contains(key)) return;

      final peer = _nearbyDevices.firstWhere(
        (d) => d.deviceId.trim() == deviceId,
        orElse: () => Device(deviceId, deviceId, 0),
      );
      final peerName = peer.deviceName.trim().isNotEmpty
          ? peer.deviceName.trim()
          : (peer.deviceId.trim().isEmpty ? 'Bluetooth' : peer.deviceId.trim());

      final preview = _notificationPreviewFromBluetoothBody(body);

      const details = lnp.NotificationDetails(
        iOS: lnp.DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        macOS: lnp.DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );
      _notificationIdCounter++;
      await _localNotifications.show(
        id: _notificationIdCounter,
        title: peerName,
        body: preview,
        notificationDetails: details,
      );

      _recentBtNotificationKeys.add(key);
      if (_recentBtNotificationKeys.length > 250) {
        _recentBtNotificationKeys.removeAt(0);
      }
      await _saveBtNotificationDedupeCache();
    } catch (_) {}
  }

  Future<void> _loadBtNotificationDedupeCache() async {
    if (_btNotifDedupeLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_btNotifDedupePrefsKey) ?? const [];
      _recentBtNotificationKeys
        ..clear()
        ..addAll(raw.where((e) => e.trim().isNotEmpty));
      if (_recentBtNotificationKeys.length > 250) {
        _recentBtNotificationKeys.removeRange(
          0,
          _recentBtNotificationKeys.length - 250,
        );
      }
    } catch (_) {
      _recentBtNotificationKeys.clear();
    } finally {
      _btNotifDedupeLoaded = true;
    }
  }

  Future<void> _saveBtNotificationDedupeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _btNotifDedupePrefsKey,
        List<String>.from(_recentBtNotificationKeys),
      );
    } catch (_) {}
  }

  Future<void> _loadPendingWalkieInvite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingWalkieInvitePrefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final deviceId = map['deviceId']?.toString().trim() ?? '';
      if (deviceId.isEmpty) return;
      _pendingWalkieInvite = <String, String>{
        'deviceId': deviceId,
        'inviteId': map['inviteId']?.toString().trim() ?? '',
      };
      if (mounted && _appLifecycleState == AppLifecycleState.resumed) {
        unawaited(_presentPendingWalkieInviteIfNeeded());
      }
    } catch (_) {}
  }

  Future<void> _savePendingWalkieInvite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = _pendingWalkieInvite;
      if (pending == null) {
        await prefs.remove(_pendingWalkieInvitePrefsKey);
        return;
      }
      await prefs.setString(_pendingWalkieInvitePrefsKey, jsonEncode(pending));
    } catch (_) {}
  }

  String _peerLabelFromDeviceId(String deviceId) {
    final cleanId = deviceId.trim();
    if (cleanId.isEmpty) return 'Bluetooth';
    final fromLive = _nearbyDevices.where((d) => d.deviceId.trim() == cleanId);
    if (fromLive.isNotEmpty) {
      final peer = fromLive.first;
      final name = peer.deviceName.trim();
      if (name.isNotEmpty) return name;
    }
    final fromRecent = _recentNearbyDevicesById[cleanId];
    if (fromRecent != null) {
      final name = fromRecent.deviceName.trim();
      if (name.isNotEmpty) return name;
    }
    return cleanId;
  }

  Future<void> _presentPendingWalkieInviteIfNeeded() async {
    if (!mounted) return;
    if (_appLifecycleState != AppLifecycleState.resumed) return;
    if (_walkieInviteDialogOpen) return;
    final pending = _pendingWalkieInvite;
    if (pending == null) return;
    final deviceId = pending['deviceId']?.trim() ?? '';
    if (deviceId.isEmpty) return;

    _walkieInviteDialogOpen = true;
    final peerName = _peerLabelFromDeviceId(deviceId);
    final decision = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Walkie Talkie'),
        content: Text('$peerName quiere hacer Walkie Talkie contigo. ¿Quieres unirte?'),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop('reject'),
            child: const Text('Rechazar'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop('accept'),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
    _walkieInviteDialogOpen = false;
    if (!mounted) return;

    final inviteId = pending['inviteId']?.trim() ?? '';
    _pendingWalkieInvite = null;
    await _savePendingWalkieInvite();
    if (!mounted) return;

    if (decision == 'accept') {
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute<void>(
          builder: (_) => WalkieTalkieScreen(
            service: _bluetoothService,
            deviceId: deviceId,
            peerName: peerName,
            sendStartSignalOnOpen: false,
            inviteId: inviteId,
            isJoiner: true,
          ),
        ),
      );
    } else {
      await _bluetoothService.sendText(
        deviceId,
        'btcall::${jsonEncode({'type': 'end', 'inviteId': inviteId})}',
      );
    }
  }

  String _buildBluetoothNotificationKey({
    required String deviceId,
    required String body,
    required String rawIncoming,
  }) {
    final cleanBody = body.trim();
    if (cleanBody.startsWith('btvoicecall::')) {
      final payload = cleanBody.replaceFirst('btvoicecall::', '');
      try {
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString().trim() ?? '';
        final callId = map['callId']?.toString().trim() ?? '';
        if (type == 'invite') {
          return 'btcall:$deviceId:$type:${callId.isEmpty ? rawIncoming.trim().hashCode : callId}';
        }
      } catch (_) {}
    }
    if (cleanBody.startsWith('btcall::')) {
      final payload = cleanBody.replaceFirst('btcall::', '');
      try {
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString().trim() ?? '';
        final inviteId = map['inviteId']?.toString().trim() ?? '';
        if (type == 'start') {
          return 'btwalkie:$deviceId:$type:${inviteId.isEmpty ? rawIncoming.trim().hashCode : inviteId}';
        }
      } catch (_) {}
    }
    if (cleanBody.startsWith('btmsg::')) {
      final payload = cleanBody.replaceFirst('btmsg::', '');
      try {
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final messageId = map['id']?.toString().trim() ?? '';
        if (messageId.isNotEmpty) return 'btmsg:$deviceId:$messageId';

        final type = map['type']?.toString().trim() ?? 'text';
        final text = map['text']?.toString().trim() ?? '';
        final caption = map['caption']?.toString().trim() ?? '';
        final bytes = map['bytes']?.toString().trim() ?? '';
        final duration = map['durationMs']?.toString().trim() ?? '';
        return 'btmsg:$deviceId:$type:$text:$caption:$duration:${bytes.hashCode}';
      } catch (_) {}
    }

    return 'raw:$deviceId:${rawIncoming.trim()}';
  }

  Future<void> _showBluetoothEventNotificationIfNeeded({
    required String deviceId,
    required String eventType,
    required String title,
    required String body,
    required String rawIncoming,
  }) async {
    try {
      if (_appLifecycleState == AppLifecycleState.resumed) return;
      if (!_btNotifDedupeLoaded) {
        await _loadBtNotificationDedupeCache();
      }
      final baseKey = _buildBluetoothNotificationKey(
        deviceId: deviceId,
        body: rawIncoming,
        rawIncoming: rawIncoming,
      );
      final key = '$eventType:$baseKey';
      if (_recentBtNotificationKeys.contains(key)) return;

      final peer = _nearbyDevices.firstWhere(
        (d) => d.deviceId.trim() == deviceId,
        orElse: () => Device(deviceId, deviceId, 0),
      );
      final peerName = peer.deviceName.trim().isNotEmpty
          ? peer.deviceName.trim()
          : (peer.deviceId.trim().isEmpty ? 'Bluetooth' : peer.deviceId.trim());

      final isIncomingCallInvite = eventType == 'btcall_invite';
      final details = lnp.NotificationDetails(
        android: isIncomingCallInvite
            ? const lnp.AndroidNotificationDetails(
                'vmessages_incoming_call_v2',
                'Incoming Calls',
                channelDescription: 'Llamadas entrantes Bluetooth',
                importance: lnp.Importance.max,
                priority: lnp.Priority.max,
                category: lnp.AndroidNotificationCategory.call,
                fullScreenIntent: true,
                ongoing: true,
                autoCancel: false,
                playSound: true,
                audioAttributesUsage:
                    lnp.AudioAttributesUsage.notificationRingtone,
              )
            : const lnp.AndroidNotificationDetails(
                'vmessages_events_v1',
                'Events',
                channelDescription: 'Eventos Bluetooth',
                importance: lnp.Importance.high,
                priority: lnp.Priority.high,
              ),
        iOS: isIncomingCallInvite
            ? const lnp.DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
                sound: 'incoming_call.caf',
                interruptionLevel: lnp.InterruptionLevel.timeSensitive,
              )
            : const lnp.DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
        macOS: const lnp.DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );
      _notificationIdCounter++;
      await _localNotifications.show(
        id: _notificationIdCounter,
        title: '$title · $peerName',
        body: body,
        notificationDetails: details,
      );

      _recentBtNotificationKeys.add(key);
      if (_recentBtNotificationKeys.length > 250) {
        _recentBtNotificationKeys.removeAt(0);
      }
      await _saveBtNotificationDedupeCache();
    } catch (_) {}
  }

  String _notificationPreviewFromBluetoothBody(String body) {
    final clean = body.trim();
    if (clean.isEmpty) return 'Nuevo mensaje';
    if (clean.startsWith('btphoto::')) return '📷 Foto';
    if (clean.startsWith('btvoice::')) return '🎤 Audio';

    if (clean.startsWith('btmsg::')) {
      final payload = clean.replaceFirst('btmsg::', '');
      try {
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString() ?? 'text';
        if (type == 'photo') return '📷 Foto';
        if (type == 'voice') return '🎤 Audio';
        final text = map['text']?.toString().trim() ?? '';
        return text.isEmpty ? 'Nuevo mensaje' : text;
      } catch (_) {
        return 'Nuevo mensaje';
      }
    }

    try {
      final decoded = jsonDecode(clean);
      if (decoded is Map) {
        final visible = decoded['message']?.toString().trim() ?? '';
        if (visible.isNotEmpty) return visible;
      }
    } catch (_) {}

    return clean;
  }

  Future<void> _configureIncomingCallTonePlayer() async {
    try {
      await _incomingCallTonePlayer.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playAndRecord,
            options: {
              AVAudioSessionOptions.defaultToSpeaker,
              AVAudioSessionOptions.allowBluetooth,
              AVAudioSessionOptions.allowBluetoothA2DP,
              AVAudioSessionOptions.allowAirPlay,
            },
          ),
          android: const AudioContextAndroid(
            isSpeakerphoneOn: true,
            stayAwake: false,
            usageType: AndroidUsageType.alarm,
            contentType: AndroidContentType.sonification,
            audioFocus: AndroidAudioFocus.gain,
          ),
        ),
      );
      await _incomingCallTonePlayer.setPlayerMode(PlayerMode.mediaPlayer);
      await _incomingCallTonePlayer.setVolume(1.0);
    } catch (e) {
      debugPrint('Error configurando ringtone entrante: $e');
    }
  }

  void _startBluetoothKeepAlive() {
    if (!_isApplePeerSupported) return;
    _iosBluetoothKeepAliveTimer?.cancel();
    _iosBluetoothKeepAliveTimer = Timer.periodic(const Duration(seconds: 18), (
      _,
    ) async {
      await _refreshPresenceSafely(minGap: const Duration(seconds: 8));
      if (_appLifecycleState == AppLifecycleState.resumed &&
          _nearbyDevices.isEmpty) {
        await _refreshAdvertising(force: true);
      }
    });
  }

  Future<void> _refreshPresenceSafely({Duration minGap = Duration.zero}) async {
    if (!_isApplePeerSupported) return;
    if (_presenceRefreshInFlight) return;
    final now = DateTime.now();
    if (minGap > Duration.zero &&
        now.difference(_lastPresenceRefreshAt) < minGap) {
      return;
    }
    _presenceRefreshInFlight = true;
    try {
      await _bluetoothService.refreshPresence();
      _lastPresenceRefreshAt = DateTime.now();
    } catch (_) {
      _lastPresenceRefreshAt = DateTime.now();
    } finally {
      _presenceRefreshInFlight = false;
    }
  }

  Future<void> _refreshAdvertising({bool force = false}) async {
    if (!_isApplePeerSupported) return;
    if (_appLifecycleState != AppLifecycleState.resumed) {
      try {
        await _bluetoothService.refreshPresence();
      } catch (_) {}
      return;
    }
    final inactivitySeconds = DateTime.now()
        .difference(_bluetoothService.lastActivityAt)
        .inSeconds;
    final shouldSkip =
        !force &&
        (_bluetoothService.hasConnectedPeers || inactivitySeconds < 22);
    if (shouldSkip) return;
    try {
      final phone =
          _client.auth.currentUser?.userMetadata?['phone']?.toString() ??
          'iPhone';
      await _bluetoothService.stop();
      await _bluetoothService.start(displayName: phone);
    } catch (_) {}
  }

  Future<void> _startIOSBackgroundExecution() async {
    if (!Platform.isIOS) return;
    try {
      await _iosBackgroundBridge.start();
    } catch (_) {}
    try {
      await _iosSilentAudioBridge.start();
    } catch (_) {}
    _iosBackgroundHeartbeatTimer?.cancel();
    _iosBackgroundHeartbeatTimer = Timer.periodic(const Duration(seconds: 12), (
      _,
    ) async {
      if (_appLifecycleState == AppLifecycleState.resumed) return;
      await _refreshPresenceSafely(minGap: const Duration(seconds: 8));
    });
  }

  Future<void> _stopIOSBackgroundExecution() async {
    _iosBackgroundHeartbeatTimer?.cancel();
    _iosBackgroundHeartbeatTimer = null;
    if (!Platform.isIOS) return;
    try {
      await _iosBackgroundBridge.stop();
    } catch (_) {}
    try {
      await _iosSilentAudioBridge.stop();
    } catch (_) {}
  }

  late final WidgetsBindingObserver _lifecycleObserver = _LifecycleObserver(
    onChanged: (state) async {
      _appLifecycleState = state;
      if (!mounted) return;
      if (state == AppLifecycleState.resumed) {
        await _stopIOSBackgroundExecution();
        _resubscribeMessageNotifications();
        unawaited(_presentPendingWalkieInviteIfNeeded());
      }
      await _broadcastBluetoothPresence();
      if (!_isApplePeerSupported) return;
      if (state == AppLifecycleState.resumed) {
        await _refreshPresenceSafely();
        await _refreshAdvertising(force: true);
        return;
      }
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        await _startIOSBackgroundExecution();
        await _refreshPresenceSafely();
      }
    },
  );

  String _extractBtVisibleText(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final message = decoded['message']?.toString() ?? '';
        if (message.trim().isNotEmpty) return message.trim();
      }
    } catch (_) {}
    return raw.trim();
  }

  String _resolveNearbyDeviceId(String incomingId) {
    final clean = incomingId.trim();
    if (clean.isEmpty) return 'unknown';
    for (final d in _nearbyDevices) {
      if (d.deviceId.trim() == clean || d.deviceName.trim() == clean) {
        return d.deviceId.trim();
      }
    }
    return clean;
  }

  bool _isBluetoothControlPayload(String body) {
    return body.startsWith('btcall::') ||
        body.startsWith('btcallvoice::') ||
        body.startsWith('btvoicecall::') ||
        body.startsWith('btctl::');
  }

  bool _handleIncomingBtPresence({
    required String deviceId,
    required String body,
  }) {
    if (!body.startsWith('btctl::')) return false;
    try {
      final payload = body.replaceFirst('btctl::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      if (map['action']?.toString() != 'presence') return false;
      final state = map['state']?.toString() ?? 'online';
      final incomingAvatarB64 = map['avatarB64']?.toString().trim();
      final incomingAvatarHash = map['avatarHash']?.toString().trim();
      final current = _nearbyMetaByDeviceId[deviceId];
      final nextAvatarBase64 = incomingAvatarB64?.isNotEmpty == true
          ? incomingAvatarB64
          : current?.peerAvatarBase64;
      final noVisualChange =
          current != null &&
          current.peerPresence == state &&
          (incomingAvatarHash?.isNotEmpty != true ||
              incomingAvatarHash == current.peerAvatarHash);
      if (noVisualChange) return true;
      final updated = NearbyChatMeta(
        lastMessage: current?.lastMessage ?? '',
        lastMessageAt: current?.lastMessageAt,
        hasUnread: current?.hasUnread ?? false,
        peerPresence: state,
        peerPresenceAt: DateTime.now(),
        peerAvatarBase64: nextAvatarBase64,
        peerAvatarHash: incomingAvatarHash?.isNotEmpty == true
            ? incomingAvatarHash
            : current?.peerAvatarHash,
      );
      if (mounted) {
        setState(() {
          _nearbyMetaByDeviceId[deviceId] = updated;
        });
      } else {
        _nearbyMetaByDeviceId[deviceId] = updated;
      }
      unawaited(_saveNearbyChatMeta());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _broadcastBluetoothPresence() async {
    if (!_isApplePeerSupported) return;
    final state =
        _appLifecycleState == AppLifecycleState.resumed ? 'online' : 'background';
    final payloadMap = <String, dynamic>{
      'action': 'presence',
      'state': state,
    };
    final avatarB64 = _myBluetoothAvatarBase64;
    if (avatarB64 != null && avatarB64.isNotEmpty) {
      payloadMap['avatarB64'] = avatarB64;
      payloadMap['avatarHash'] = _myBluetoothAvatarHash;
    }
    final payload = 'btctl::${jsonEncode(payloadMap)}';
    for (final device in _nearbyDevices) {
      final id = device.deviceId.trim();
      if (id.isEmpty) continue;
      try {
        await _bluetoothService.sendText(id, payload);
      } catch (_) {}
    }
  }

  Future<bool> _handleIncomingBtCallInvite({
    required String body,
    required String incomingDeviceId,
  }) async {
    if (!body.startsWith('btvoicecall::')) return false;
    try {
      final payload = body.replaceFirst('btvoicecall::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final type = map['type']?.toString() ?? '';
      if (type == 'audio' || type == 'accept') return true;
      if (type != 'invite') return true;
      final resolvedId = _resolveNearbyDeviceId(incomingDeviceId);
      await _showBluetoothEventNotificationIfNeeded(
        deviceId: resolvedId,
        eventType: 'btcall_invite',
        title: 'Llamada Bluetooth',
        body: 'Llamada entrante',
        rawIncoming: body,
      );
      if (_appLifecycleState != AppLifecycleState.resumed) return true;
      if (_incomingBtCallDialogOpen || !mounted) return true;
      _incomingBtCallDialogOpen = true;
      _startIncomingCallTone();
      if (!mounted) return true;
      final peer = _nearbyDevices.firstWhere(
        (d) => d.deviceId.trim() == resolvedId,
        orElse: () => Device(resolvedId, resolvedId, 0),
      );
      final peerLabel = peer.deviceName.trim().isEmpty
          ? peer.deviceId
          : peer.deviceName;
      final decision = await showGeneralDialog<String>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Llamada entrante',
        barrierColor: const Color(0x44000000),
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          return SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD1D1D6),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        peerLabel.characters.first.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Llamada de Bluetooth',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF636366),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            peerLabel,
                            style: const TextStyle(
                              fontSize: 17,
                              color: Color(0xFF1C1C1E),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      onPressed: () => Navigator.of(context).pop('reject'),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF3B30),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          CupertinoIcons.phone_down_fill,
                          size: 20,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      onPressed: () => Navigator.of(context).pop('accept'),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: const BoxDecoration(
                          color: Color(0xFF34C759),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          CupertinoIcons.phone_fill,
                          size: 20,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      _stopIncomingCallTone();
      _incomingBtCallDialogOpen = false;
      if (!mounted) return true;
      if (decision == 'accept') {
        await Navigator.of(context, rootNavigator: true).push(
          CupertinoPageRoute<void>(
            builder: (_) => BluetoothConversationScreen(
              service: _bluetoothService,
              deviceId: resolvedId,
              peerName: peerLabel,
              peerAvatarBase64:
                  _nearbyMetaByDeviceId[resolvedId]?.peerAvatarBase64,
              peerAvatarHash: _nearbyMetaByDeviceId[resolvedId]?.peerAvatarHash,
              autoOpenVoiceCall: true,
              autoOpenVoiceCallAsInitiator: false,
            ),
          ),
        );
      } else {
        await _bluetoothService.sendText(
          resolvedId,
          'btvoicecall::${jsonEncode({'type': 'end'})}',
        );
      }
    } catch (_) {
      _stopIncomingCallTone();
      _incomingBtCallDialogOpen = false;
    }
    return true;
  }

  Future<bool> _handleIncomingBtWalkieInvite({
    required String body,
    required String incomingDeviceId,
    required String rawIncomingDeviceId,
  }) async {
    if (!body.startsWith('btcall::')) return false;
    try {
      final payload = body.replaceFirst('btcall::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final type = map['type']?.toString() ?? '';
      if (type != 'start') return true;
      final resolvedId = _resolveNearbyDeviceId(incomingDeviceId);
      final rawId = rawIncomingDeviceId.trim();
      final fallbackPhoneLike =
          RegExp(r'^\+?[0-9]{6,}$').hasMatch(resolvedId.trim());
      final effectiveId = fallbackPhoneLike && rawId.isNotEmpty
          ? rawId
          : resolvedId;
      final inviteId = map['inviteId']?.toString().trim() ?? '';
      await _showBluetoothEventNotificationIfNeeded(
        deviceId: effectiveId,
        eventType: 'btwalkie_invite',
        title: 'Walkie Talkie',
        body: 'Quiere hablar contigo',
        rawIncoming: body,
      );
      if (_appLifecycleState != AppLifecycleState.resumed) {
        _pendingWalkieInvite = <String, String>{
          'deviceId': effectiveId,
          'inviteId': inviteId,
        };
        await _savePendingWalkieInvite();
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<void> _startIncomingCallTone() async {
    _incomingCallToneTimer?.cancel();
    _incomingCallToneBytes ??= _buildIncomingRingtoneWav();
    try {
      await _incomingCallTonePlayer.stop();
      _incomingCallToneFilePath ??= await _ensureIncomingCallToneFile();
      await _incomingCallTonePlayer.setVolume(1.0);
      await _incomingCallTonePlayer.setReleaseMode(ReleaseMode.loop);
      await _incomingCallTonePlayer.play(
        DeviceFileSource(_incomingCallToneFilePath!),
      );
    } catch (e) {
      debugPrint('Error reproduciendo ringtone entrante: $e');
    }
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.mediumImpact();
    _incomingCallToneTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.mediumImpact();
    });
  }

  void _stopIncomingCallTone() {
    _incomingCallToneTimer?.cancel();
    _incomingCallToneTimer = null;
    _incomingCallTonePlayer.stop();
  }

  Future<String> _ensureIncomingCallToneFile() async {
    final dir = await _runtimeTempDir();
    final path = '${dir.path}/incoming_call_ringtone.wav';
    final file = File(path);
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.writeAsBytes(_incomingCallToneBytes!, flush: true);
    }
    return path;
  }

  Uint8List _buildIncomingRingtoneWav() {
    const sampleRate = 16000;
    const totalSeconds = 1.6;
    final totalSamples = (sampleRate * totalSeconds).toInt();
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final pcmDataBytes = totalSamples * blockAlign;
    final wav = BytesBuilder();

    void writeAscii(String value) =>
        wav.add(value.codeUnits.map((e) => e & 0xFF).toList());
    void writeInt16(int value) {
      wav.add([value & 0xFF, (value >> 8) & 0xFF]);
    }

    void writeInt32(int value) {
      wav.add([
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ]);
    }

    writeAscii('RIFF');
    writeInt32(36 + pcmDataBytes);
    writeAscii('WAVE');
    writeAscii('fmt ');
    writeInt32(16);
    writeInt16(1);
    writeInt16(channels);
    writeInt32(sampleRate);
    writeInt32(byteRate);
    writeInt16(blockAlign);
    writeInt16(bitsPerSample);
    writeAscii('data');
    writeInt32(pcmDataBytes);

    const twoPi = 6.283185307179586;
    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final pulseA = (t >= 0.0 && t < 0.35);
      final pulseB = (t >= 0.45 && t < 0.8);
      final pulse = pulseA || pulseB;
      final freq = pulseA ? 860.0 : 700.0;
      final env = pulse ? 0.45 : 0.0;
      final sample = (32767 * env * sin(twoPi * freq * t)).round().clamp(
        -32768,
        32767,
      );
      writeInt16(sample);
    }

    return wav.toBytes();
  }

  Future<void> _loadNearbyChatMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bt_chat_meta') ?? '{}';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final incoming = <String, NearbyChatMeta>{};
      decoded.forEach((key, value) {
        final parsed = NearbyChatMeta.fromJson(value);
        if (parsed != null) incoming[key.toString()] = parsed;
      });
      if (!mounted) return;
      setState(() {
        _nearbyMetaByDeviceId
          ..clear()
          ..addAll(incoming);
      });
    } catch (_) {}
  }

  Future<void> _loadMyBluetoothAvatarCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final b64 = prefs.getString('my_bt_avatar_b64')?.trim() ?? '';
      final hash = prefs.getString('my_bt_avatar_hash')?.trim() ?? '';
      if (!mounted) return;
      setState(() {
        _myBluetoothAvatarBase64 = b64.isEmpty ? null : b64;
        _myBluetoothAvatarHash = hash.isEmpty ? null : hash;
      });
    } catch (_) {}
  }

  Future<void> _saveNearbyChatMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{};
    _nearbyMetaByDeviceId.forEach((key, value) {
      payload[key] = value.toJson();
    });
    await prefs.setString('bt_chat_meta', jsonEncode(payload));
  }

  Future<void> _markNearbyChatRead(String deviceId) async {
    final current = _nearbyMetaByDeviceId[deviceId];
    if (current == null) return;
    setState(() {
      _nearbyMetaByDeviceId[deviceId] = NearbyChatMeta(
        lastMessage: current.lastMessage,
        lastMessageAt: current.lastMessageAt,
        hasUnread: false,
        peerPresence: current.peerPresence,
        peerPresenceAt: current.peerPresenceAt,
        peerAvatarBase64: current.peerAvatarBase64,
        peerAvatarHash: current.peerAvatarHash,
      );
    });
    await _saveNearbyChatMeta();
  }

  void _pruneStaleNearbyDevices() {
    final now = DateTime.now();
    final staleIds = <String>[];
    _recentNearbySeenAtById.forEach((id, seenAt) {
      if (now.difference(seenAt) > _nearbyDeviceRetention) {
        staleIds.add(id);
      }
    });
    for (final id in staleIds) {
      _recentNearbySeenAtById.remove(id);
      _recentNearbyDevicesById.remove(id);
    }
  }

  List<Device> _visibleNearbyDevices() {
    _pruneStaleNearbyDevices();
    final merged = Map<String, Device>.from(_recentNearbyDevicesById);
    for (final device in _nearbyDevices) {
      final id = device.deviceId.trim();
      if (id.isEmpty) continue;
      merged[id] = device;
    }
    return merged.values.toList()
      ..sort((a, b) {
        final aSeen =
            _recentNearbySeenAtById[a.deviceId.trim()] ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bSeen =
            _recentNearbySeenAtById[b.deviceId.trim()] ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bSeen.compareTo(aSeen);
      });
  }

  String _btHistoryKey(String deviceId) =>
      'bt_history_device_${deviceId.trim()}';

  Future<void> _appendNearbyIncomingToHistory({
    required String deviceId,
    required String body,
  }) async {
    if (body.startsWith('btcall::') ||
        body.startsWith('btcallvoice::') ||
        body.startsWith('btvoicecall::') ||
        body.startsWith('btack::') ||
        body.startsWith('btseen::')) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = _btHistoryKey(deviceId);
    final raw = prefs.getString(key);
    final list = <dynamic>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      } catch (_) {}
    }

    final sentAt = DateTime.now().toIso8601String();
    bool isDuplicateLastIncoming({
      required String text,
      String? photoBytes,
      String? audioBytes,
      int? audioDurationMs,
      String? caption,
    }) {
      if (list.isEmpty) return false;
      final lastRaw = list.last;
      if (lastRaw is! Map) return false;
      final last = Map<String, dynamic>.from(lastRaw);
      if (last['isMe'] == true) return false;
      final sameText = (last['text']?.toString() ?? '') == text;
      final samePhoto =
          (last['photoBytes']?.toString() ?? '') == (photoBytes ?? '');
      final sameAudio =
          (last['audioBytes']?.toString() ?? '') == (audioBytes ?? '');
      final sameAudioDuration =
          (last['audioDurationMs'] as int? ?? 0) == (audioDurationMs ?? 0);
      final sameCaption =
          (last['caption']?.toString() ?? '') == (caption ?? '');
      return sameText &&
          samePhoto &&
          sameAudio &&
          sameAudioDuration &&
          sameCaption;
    }

    if (body.startsWith('btctl::')) {
      try {
        final payload = body.replaceFirst('btctl::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final action = map['action']?.toString() ?? '';
        if (action == 'delete') {
          final messageId = map['messageId']?.toString() ?? '';
          if (messageId.isNotEmpty) {
            list.removeWhere((item) {
              if (item is! Map) return false;
              final row = Map<String, dynamic>.from(item);
              return row['messageId']?.toString() == messageId;
            });
            await prefs.setString(key, jsonEncode(list));
          }
        } else if (action == 'reaction') {
          final messageId = map['messageId']?.toString().trim() ?? '';
          if (messageId.isNotEmpty) {
            final reaction = map['reaction']?.toString().trim() ?? '';
            for (var i = 0; i < list.length; i++) {
              final item = list[i];
              if (item is! Map) continue;
              final row = Map<String, dynamic>.from(item);
              if (row['messageId']?.toString() != messageId) continue;
              row['reaction'] = reaction.isEmpty ? null : reaction;
              list[i] = row;
              await prefs.setString(key, jsonEncode(list));
              break;
            }
          }
        }
      } catch (_) {}
      return;
    } else if (body.startsWith('btmsg::')) {
      try {
        final payload = body.replaceFirst('btmsg::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final messageId = map['id']?.toString() ?? '';
        final type = map['type']?.toString() ?? 'text';
        if (messageId.isNotEmpty &&
            list.any(
              (item) =>
                  item is Map && item['messageId']?.toString() == messageId,
            )) {
          return;
        }
        if (type == 'photo') {
          final photoBytes = map['bytes']?.toString();
          final caption = map['caption']?.toString();
          final replyToMessageId = map['replyToMessageId']?.toString();
          final replyToPreview = map['replyToPreview']?.toString();
          list.add({
            'messageId': messageId,
            'text': '',
            'isMe': false,
            'sentAt': sentAt,
            'photoBytes': photoBytes,
            'audioBytes': null,
            'audioDurationMs': null,
            'caption': caption,
            'replyToMessageId': replyToMessageId,
            'replyToPreview': replyToPreview,
          });
        } else if (type == 'voice') {
          final audioBytes = map['bytes']?.toString();
          final audioDurationMs = int.tryParse(
            map['durationMs']?.toString() ?? '',
          );
          final replyToMessageId = map['replyToMessageId']?.toString();
          final replyToPreview = map['replyToPreview']?.toString();
          list.add({
            'messageId': messageId,
            'text': '',
            'isMe': false,
            'sentAt': sentAt,
            'photoBytes': null,
            'audioBytes': audioBytes,
            'audioDurationMs': audioDurationMs,
            'caption': null,
            'replyToMessageId': replyToMessageId,
            'replyToPreview': replyToPreview,
          });
        } else {
          final text = map['text']?.toString() ?? '';
          if (text.trim().isEmpty) return;
          final replyToMessageId = map['replyToMessageId']?.toString();
          final replyToPreview = map['replyToPreview']?.toString();
          list.add({
            'messageId': messageId,
            'text': text.trim(),
            'isMe': false,
            'sentAt': sentAt,
            'photoBytes': null,
            'audioBytes': null,
            'audioDurationMs': null,
            'caption': null,
            'replyToMessageId': replyToMessageId,
            'replyToPreview': replyToPreview,
          });
        }
      } catch (_) {}
    } else if (body.startsWith('btphoto::')) {
      try {
        final payload = body.replaceFirst('btphoto::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final photoBytes = map['bytes']?.toString();
        final caption = map['caption']?.toString();
        if (isDuplicateLastIncoming(
          text: '',
          photoBytes: photoBytes,
          caption: caption,
        )) {
          return;
        }
        list.add({
          'messageId': 'legacy_${DateTime.now().microsecondsSinceEpoch}',
          'text': '',
          'isMe': false,
          'sentAt': sentAt,
          'photoBytes': photoBytes,
          'audioBytes': null,
          'audioDurationMs': null,
          'caption': caption,
        });
      } catch (_) {
        if (isDuplicateLastIncoming(text: body)) return;
        list.add({
          'messageId': 'legacy_${DateTime.now().microsecondsSinceEpoch}',
          'text': body,
          'isMe': false,
          'sentAt': sentAt,
          'photoBytes': null,
          'audioBytes': null,
          'audioDurationMs': null,
          'caption': null,
        });
      }
    } else if (body.startsWith('btvoice::')) {
      try {
        final payload = body.replaceFirst('btvoice::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final audioBytes = map['bytes']?.toString();
        final audioDurationMs = int.tryParse(
          map['durationMs']?.toString() ?? '',
        );
        if (isDuplicateLastIncoming(
          text: '',
          audioBytes: audioBytes,
          audioDurationMs: audioDurationMs,
        )) {
          return;
        }
        list.add({
          'messageId': 'legacy_${DateTime.now().microsecondsSinceEpoch}',
          'text': '',
          'isMe': false,
          'sentAt': sentAt,
          'photoBytes': null,
          'audioBytes': audioBytes,
          'audioDurationMs': audioDurationMs,
          'caption': null,
        });
      } catch (_) {
        if (isDuplicateLastIncoming(text: body)) return;
        list.add({
          'messageId': 'legacy_${DateTime.now().microsecondsSinceEpoch}',
          'text': body,
          'isMe': false,
          'sentAt': sentAt,
          'photoBytes': null,
          'audioBytes': null,
          'audioDurationMs': null,
          'caption': null,
        });
      }
    } else {
      if (isDuplicateLastIncoming(text: body)) return;
      list.add({
        'messageId': 'legacy_${DateTime.now().microsecondsSinceEpoch}',
        'text': body,
        'isMe': false,
        'sentAt': sentAt,
        'photoBytes': null,
        'audioBytes': null,
        'audioDurationMs': null,
        'caption': null,
      });
    }
    await prefs.setString(key, jsonEncode(list));
  }

  Future<void> _startNewChat() async {
    final phone = await _showPhoneInputDialog(context);
    if (phone == null || phone.trim().isEmpty) return;

    setState(() {
      _creatingChat = true;
    });

    try {
      final result = await _client.rpc(
        'start_dm_chat',
        params: {'peer_phone': phone.trim()},
      );

      if (!mounted) return;
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => ConversationScreen(
            conversationId: result.toString(),
            peerPhone: phone.trim(),
          ),
        ),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      await _showErrorDialog(e.message);
    } catch (_) {
      if (!mounted) return;
      await _showErrorDialog('No se pudo crear el chat.');
    } finally {
      if (mounted) {
        setState(() {
          _creatingChat = false;
        });
      }
    }
  }

  Future<String?> _showPhoneInputDialog(BuildContext context) async {
    final controller = TextEditingController();
    return showCupertinoDialog<String>(
      context: context,
      builder: (context) {
        return CupertinoAlertDialog(
          title: const Text('Nuevo chat'),
          content: Column(
            children: [
              const SizedBox(height: 10),
              CupertinoTextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                placeholder: '+525512345678',
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Crear'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showErrorDialog(String message) async {
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) {
        return CupertinoAlertDialog(
          title: const Text('Error'),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () async {
            await Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => const ProfileScreen(),
              ),
            );
            await _loadMyBluetoothAvatarCache();
            await _broadcastBluetoothPresence();
          },
          child: const Icon(CupertinoIcons.person_circle, size: 24),
        ),
        middle: const Text('Mensajes'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
              child: const Icon(CupertinoIcons.settings, size: 24),
            ),
            const SizedBox(width: 10),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _creatingChat ? null : _startNewChat,
              child: _creatingChat
                  ? const CupertinoActivityIndicator(radius: 10)
                  : const Icon(CupertinoIcons.square_pencil, size: 24),
            ),
            const SizedBox(width: 10),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => _client.auth.signOut(),
              child: const Icon(CupertinoIcons.square_arrow_right, size: 24),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _membershipStream,
          builder: (context, membershipSnapshot) {
            if (membershipSnapshot.hasError) {
              return Center(child: Text('Error: ${membershipSnapshot.error}'));
            }
            if (!membershipSnapshot.hasData) {
              return const Center(
                child: CupertinoActivityIndicator(radius: 14),
              );
            }

            final membershipRows = membershipSnapshot.data!;
            final conversationIds = membershipRows
                .map((row) => row['conversation_id'].toString())
                .toList();

            if (conversationIds.isEmpty && _visibleNearbyDevices().isEmpty) {
              return _buildHomePlaceholder();
            }

            return FutureBuilder<List<ConversationSummary>>(
              future: _loadConversationSummaries(membershipRows),
              builder: (context, summarySnapshot) {
                if (summarySnapshot.hasError) {
                  return Center(child: Text('Error: ${summarySnapshot.error}'));
                }
                if (!summarySnapshot.hasData) {
                  return const Center(
                    child: CupertinoActivityIndicator(radius: 14),
                  );
                }

                final summaries = summarySnapshot.data!;
                final nearbyTiles = _buildNearbyChatTiles();
                return ListView(
                  children: [
                    ...nearbyTiles,
                    ...summaries.map(_buildConversationTile),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildHomePlaceholder() {
    final nearbyTiles = _buildNearbyChatTiles();
    if (nearbyTiles.isNotEmpty) {
      return ListView(children: nearbyTiles);
    }
    return ListView(
      children: [
        Center(
          child: Text(
            'Sin chats aun. Toca el icono para iniciar uno.',
            style: TextStyle(
              color: CupertinoDynamicColor.resolve(
                CupertinoColors.secondaryLabel,
                context,
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildNearbyChatTiles() {
    if (!_isApplePeerSupported) return const [];
    if (_btBootstrapping) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              CupertinoActivityIndicator(radius: 10),
              SizedBox(width: 10),
              Text('Buscando dispositivos cercanos...'),
            ],
          ),
        ),
      ];
    }
    if (_btError != null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Text(
            'Bluetooth cercano no disponible: $_btError',
            style: const TextStyle(color: CupertinoColors.systemRed),
          ),
        ),
      ];
    }
    final visibleDevices = _visibleNearbyDevices();
    if (visibleDevices.isEmpty) return const [];
    return visibleDevices.map(_buildNearbyConversationTile).toList();
  }

  Widget _buildNearbyConversationTile(Device device) {
    final peerLabel = device.deviceName.isEmpty
        ? device.deviceId
        : device.deviceName;
    final meta = _nearbyMetaByDeviceId[device.deviceId.trim()];
    final subtitle = meta?.lastMessage.trim().isNotEmpty == true
        ? meta!.lastMessage
        : 'Dispositivo cercano';
    final presence = _effectiveNearbyPresence(meta);
    final presenceColor = presence == 'background'
        ? const Color(0xFFFF9500)
        : CupertinoColors.activeGreen;
    final presenceLabel = presence == 'background' ? 'En segundo plano' : 'En linea';
    final time = meta?.lastMessageAt == null
        ? ''
        : _formatTime(meta!.lastMessageAt!);
    final isConnected = device.state
        .toString()
        .toLowerCase()
        .contains('connected');
    final statusLabel = isConnected ? 'Conectado' : 'Cercano';
    final statusColor = isConnected
        ? CupertinoColors.activeGreen
        : CupertinoColors.systemBlue;
    final statusBg = isConnected
        ? const Color(0x1A34C759)
        : const Color(0x1A0A84FF);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () async {
        await _markNearbyChatRead(device.deviceId.trim());
        if (!mounted) return;
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => BluetoothConversationScreen(
              service: _bluetoothService,
              deviceId: device.deviceId,
              peerName: peerLabel,
              peerAvatarBase64: meta?.peerAvatarBase64,
              peerAvatarHash: meta?.peerAvatarHash,
            ),
          ),
        );
        await _loadNearbyChatMeta();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            _ProfileAvatar(
              imageBase64: meta?.peerAvatarBase64,
              imageBase64Hash: meta?.peerAvatarHash,
              label: peerLabel,
              size: 48,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peerLabel,
                    style: TextStyle(
                      fontSize: 16,
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.label,
                        context,
                      ),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: presenceColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        presenceLabel,
                        style: TextStyle(
                          color: presenceColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.secondaryLabel,
                        context,
                      ),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  time,
                  style: TextStyle(
                    color: CupertinoDynamicColor.resolve(
                      CupertinoColors.tertiaryLabel,
                      context,
                    ),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                if (meta?.hasUnread == true)
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: CupertinoColors.systemBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.dot_radiowaves_left_right,
                        size: 12,
                        color: statusColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _effectiveNearbyPresence(NearbyChatMeta? meta) {
    final state = meta?.peerPresence ?? 'online';
    final at = meta?.peerPresenceAt;
    if (at == null) return state;
    if (DateTime.now().difference(at).inSeconds > 18) {
      return 'background';
    }
    return state;
  }

  Widget _buildConversationTile(ConversationSummary summary) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () {
        Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => ConversationScreen(
              conversationId: summary.id,
              peerPhone: summary.peerDisplayName,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            _ProfileAvatar(
              imageUrl: summary.peerAvatarUrl,
              label: summary.peerDisplayName,
              size: 48,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.peerDisplayName,
                    style: TextStyle(
                      fontSize: 16,
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.label,
                        context,
                      ),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    summary.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.secondaryLabel,
                        context,
                      ),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  summary.lastMessageAt == null
                      ? ''
                      : _formatTime(summary.lastMessageAt!),
                  style: TextStyle(
                    color: CupertinoDynamicColor.resolve(
                      CupertinoColors.tertiaryLabel,
                      context,
                    ),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                if (summary.hasUnread)
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: CupertinoColors.systemBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _client = Supabase.instance.client;
  final _picker = ImagePicker();
  final _codeController = TextEditingController();
  bool _savingCode = false;
  bool _uploadingAvatar = false;
  String? _avatarUrl;
  String _phone = '';
  String _displayName = '';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    final row = await _client
        .from('profiles')
        .select('phone,display_name,avatar_url')
        .eq('id', user.id)
        .maybeSingle();
    if (!mounted) return;
    setState(() {
      _phone = row?['phone']?.toString() ?? '';
      _displayName = row?['display_name']?.toString() ?? _phone;
      _avatarUrl = row?['avatar_url']?.toString();
    });
  }

  Future<void> _changeAccessCode() async {
    final newCode = _codeController.text.trim();
    if (newCode.length < 4) {
      await _showInfo('El codigo debe tener al menos 4 caracteres.');
      return;
    }
    final user = _client.auth.currentUser;
    if (user == null || _savingCode) return;

    setState(() {
      _savingCode = true;
    });
    try {
      await _client.auth.updateUser(UserAttributes(password: newCode));
      await _client.from('profiles').update({
        'access_code': newCode,
      }).eq('id', user.id);
      _codeController.clear();
      if (!mounted) return;
      await _showInfo('Codigo actualizado.');
    } on AuthException catch (e) {
      await _showInfo(e.message);
    } catch (_) {
      await _showInfo('No se pudo actualizar el codigo.');
    } finally {
      if (mounted) {
        setState(() {
          _savingCode = false;
        });
      }
    }
  }

  Future<void> _changeAvatar() async {
    if (_uploadingAvatar) return;
    final user = _client.auth.currentUser;
    if (user == null) return;
    try {
      final photo = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (photo == null) return;
      setState(() {
        _uploadingAvatar = true;
      });
      final bytes = await photo.readAsBytes();
      final avatarBase64 = base64Encode(bytes);
      final avatarHash = avatarBase64.hashCode.toString();
      final path = 'avatars/${user.id}/profile.jpg';
      await _client.storage.from('chat-media').uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(
          contentType: 'image/jpeg',
          upsert: true,
        ),
      );
      final publicUrl = _client.storage.from('chat-media').getPublicUrl(path);
      final version = DateTime.now().millisecondsSinceEpoch;
      await _client.from('profiles').update({
        'avatar_url': '$publicUrl?v=$version',
      }).eq('id', user.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('my_bt_avatar_b64', avatarBase64);
      await prefs.setString('my_bt_avatar_hash', avatarHash);
      if (!mounted) return;
      setState(() {
        _avatarUrl = '$publicUrl?v=$version';
      });
    } on StorageException catch (e) {
      await _showInfo('Error subiendo foto: ${e.message}');
    } on PostgrestException catch (e) {
      await _showInfo('Error guardando perfil: ${e.message}');
    } catch (e) {
      await _showInfo('No se pudo actualizar la foto de perfil: $e');
    } finally {
      if (mounted) {
        setState(() {
          _uploadingAvatar = false;
        });
      }
    }
  }

  Future<void> _showInfo(String message) async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Perfil')),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: _ProfileAvatar(
                imageUrl: _avatarUrl,
                label: _displayName.isEmpty ? _phone : _displayName,
                size: 92,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                onPressed: _uploadingAvatar ? null : _changeAvatar,
                child: _uploadingAvatar
                    ? const CupertinoActivityIndicator()
                    : const Text('Cambiar foto de perfil'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _displayName.isEmpty ? _phone : _displayName,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              _phone,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
            const SizedBox(height: 26),
            const Text(
              'Cambiar codigo de acceso',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            _IOSField(
              child: CupertinoTextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                obscureText: true,
                placeholder: 'Nuevo codigo (minimo 4)',
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
            ),
            const SizedBox(height: 12),
            CupertinoButton.filled(
              onPressed: _savingCode ? null : _changeAccessCode,
              child: _savingCode
                  ? const CupertinoActivityIndicator(
                      color: CupertinoColors.white,
                    )
                  : const Text('Guardar codigo'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Configuracion')),
      child: SafeArea(
        child: ValueListenableBuilder<bool>(
          valueListenable: _darkModeNotifier,
          builder: (context, darkMode, _) {
            return ListView(
              children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: CupertinoDynamicColor.resolve(
                      CupertinoColors.secondarySystemGroupedBackground,
                      context,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Modo oscuro',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                      CupertinoSwitch(
                        value: darkMode,
                        onChanged: (value) {
                          _setDarkMode(value);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    this.imageUrl,
    this.imageBase64,
    this.imageBase64Hash,
    required this.label,
    required this.size,
  });

  static final Map<String, Uint8List> _decodedMemoryCache =
      <String, Uint8List>{};

  final String? imageUrl;
  final String? imageBase64;
  final String? imageBase64Hash;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final firstChar = label.trim().isEmpty
        ? '?'
        : label.trim().characters.first.toUpperCase();
    Uint8List? decodedBytes;
    final base64Input = imageBase64?.trim() ?? '';
    if (base64Input.isNotEmpty) {
      final cacheKey = imageBase64Hash?.trim().isNotEmpty == true
          ? imageBase64Hash!.trim()
          : base64Input.hashCode.toString();
      decodedBytes = _decodedMemoryCache[cacheKey];
      try {
        decodedBytes ??= base64Decode(base64Input);
        _decodedMemoryCache[cacheKey] = decodedBytes;
        if (_decodedMemoryCache.length > 48) {
          _decodedMemoryCache.remove(_decodedMemoryCache.keys.first);
        }
      } catch (_) {
        decodedBytes = null;
      }
    }
    final hasUrl = imageUrl?.trim().isNotEmpty == true;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: decodedBytes != null
            ? Image.memory(
                decodedBytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) =>
                    _fallback(firstChar),
              )
            : hasUrl
            ? Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) =>
                    _fallback(firstChar),
              )
            : _fallback(firstChar),
      ),
    );
  }

  Widget _fallback(String firstChar) {
    return Container(
      color: const Color(0xFFD1D1D6),
      alignment: Alignment.center,
      child: Text(
        firstChar,
        style: TextStyle(
          color: const Color(0xFF1C1C1E),
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
        ),
      ),
    );
  }
}

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    required this.peerPhone,
  });

  final String conversationId;
  final String peerPhone;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with WidgetsBindingObserver {
  final _client = Supabase.instance.client;
  final _scrollController = ScrollController();
  RealtimeChannel? _messagesChannel;
  Timer? _fallbackTimer;
  List<Map<String, dynamic>> _messages = [];
  final Set<String> _removingMessageIds = <String>{};
  String? _lastMarkedReadAt;
  bool _loadedOnce = false;
  bool _loading = true;
  String? _error;
  bool _wasKeyboardVisible = false;
  DateTime _lastRealtimeResubscribeAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchMessages();
    _resubscribeConversationRealtime(force: true);
    _fallbackTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchMessages(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    _scrollController.dispose();
    if (_messagesChannel != null) {
      _client.removeChannel(_messagesChannel!);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resubscribeConversationRealtime();
      _fetchMessages(silent: true);
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _animateToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  void _ensureBottomVisibleAfterKeyboard() {
    _animateToBottom();
    Future<void>.delayed(const Duration(milliseconds: 120), _animateToBottom);
    Future<void>.delayed(const Duration(milliseconds: 260), _animateToBottom);
  }

  Future<void> _fetchMessages({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final rows = await _client
          .from('messages')
          .select()
          .eq('conversation_id', widget.conversationId)
          .order('created_at', ascending: true);
      if (!mounted) return;
      final incoming = List<Map<String, dynamic>>.from(rows);

      if (!_loadedOnce) {
        setState(() {
          _messages = incoming;
          _loading = false;
          _loadedOnce = true;
        });
        await _markConversationRead();
        _jumpToBottom();
        return;
      }

      final currentIds = _messages.map((m) => m['id'].toString()).toSet();
      final incomingIds = incoming.map((m) => m['id'].toString()).toSet();
      final removedIds = currentIds.difference(incomingIds);
      for (final removedId in removedIds) {
        _animateOutMessageLocally(removedId);
      }
      final rowsPendingRemoval = _messages.where((m) {
        final id = m['id'].toString();
        return removedIds.contains(id);
      });
      final mergedRows = <Map<String, dynamic>>[
        ...incoming,
        ...rowsPendingRemoval,
      ];

      final previousCount = _messages.length;
      setState(() {
        _messages = mergedRows;
        _loading = false;
      });
      await _markConversationRead();
      if (incoming.length > previousCount) {
        _animateToBottom();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _animateOutMessageLocally(String messageId) async {
    if (_removingMessageIds.contains(messageId)) return;
    final exists = _messages.any((m) => m['id'].toString() == messageId);
    if (!exists) return;

    if (mounted) {
      setState(() {
        _removingMessageIds.add(messageId);
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => m['id'].toString() == messageId);
      _removingMessageIds.remove(messageId);
    });
  }

  Future<void> _markConversationRead() async {
    final last = _messages.isEmpty ? null : _messages.last;
    final lastCreatedAt = last?['created_at']?.toString();
    if (lastCreatedAt == null) return;
    if (_lastMarkedReadAt == lastCreatedAt) return;
    final me = _client.auth.currentUser?.id;
    if (me == null) return;
    await _client
        .from('conversation_members')
        .update({'last_read_at': lastCreatedAt})
        .eq('conversation_id', widget.conversationId)
        .eq('user_id', me);
    _lastMarkedReadAt = lastCreatedAt;
  }

  void _subscribeToRealtime() {
    _messagesChannel = _client
        .channel('messages-${widget.conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversationId,
          ),
          callback: (_) {
            _fetchMessages(silent: true);
          },
        )
        .subscribe();
  }

  void _resubscribeConversationRealtime({bool force = false}) {
    final secondsSinceLast = DateTime.now()
        .difference(_lastRealtimeResubscribeAt)
        .inSeconds;
    if (!force && secondsSinceLast < 2) return;
    _lastRealtimeResubscribeAt = DateTime.now();
    if (_messagesChannel != null) {
      _client.removeChannel(_messagesChannel!);
      _messagesChannel = null;
    }
    _subscribeToRealtime();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = _client.auth.currentUser?.id;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    if (keyboardVisible && !_wasKeyboardVisible) {
      _wasKeyboardVisible = true;
      _ensureBottomVisibleAfterKeyboard();
    } else if (!keyboardVisible && _wasKeyboardVisible) {
      _wasKeyboardVisible = false;
    }

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        previousPageTitle: 'Mensajes',
        middle: Text(widget.peerPhone),
      ),
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator(radius: 14))
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : _messages.isEmpty
                  ? const Center(child: Text('Aun no hay mensajes.'))
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 84),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final row = _messages[index];
                        final rowId = row['id'].toString();
                        final isMe = row['sender_id'] == currentUserId;
                        final isRemoving = _removingMessageIds.contains(rowId);
                        return AnimatedOpacity(
                          duration: const Duration(milliseconds: 220),
                          opacity: isRemoving ? 0 : 1,
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: isRemoving
                                ? const SizedBox.shrink()
                                : _AnimatedMessageBubble(
                                    row: row,
                                    isMe: isMe,
                                    animation: const AlwaysStoppedAnimation(1),
                                    canDeleteForEveryone: isMe,
                                    onDeleteForEveryone: () =>
                                        _deleteMessageForEveryone(row),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) {
                  final keyboardVisible =
                      MediaQuery.of(context).viewInsets.bottom > 0;
                  if (!keyboardVisible) return;
                  if (details.delta.dy > 7) {
                    FocusScope.of(context).unfocus();
                  }
                },
                child: MessageComposer(
                  currentUserId: currentUserId,
                  conversationId: widget.conversationId,
                  onInputFocused: _ensureBottomVisibleAfterKeyboard,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessageForEveryone(Map<String, dynamic> row) async {
    final messageId = row['id'];
    if (messageId == null) return;
    final messageIdString = messageId.toString();
    final me = _client.auth.currentUser?.id;
    if (me == null) return;
    await _animateOutMessageLocally(messageIdString);
    try {
      await _client
          .from('messages')
          .delete()
          .eq('id', messageId)
          .eq('sender_id', me);
      await _fetchMessages(silent: true);
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Error'),
          content: const Text('No se pudo eliminar el mensaje.'),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

class _AnimatedMessageBubble extends StatelessWidget {
  const _AnimatedMessageBubble({
    required this.row,
    required this.isMe,
    required this.animation,
    required this.canDeleteForEveryone,
    required this.onDeleteForEveryone,
  });

  final Map<String, dynamic> row;
  final bool isMe;
  final Animation<double> animation;
  final bool canDeleteForEveryone;
  final Future<void> Function() onDeleteForEveryone;

  @override
  Widget build(BuildContext context) {
    final body = row['body'].toString();
    final isSticker = body.startsWith('sticker::');
    final isPhoto = body.startsWith('photo::');
    final stickerValue = isSticker ? body.replaceFirst('sticker::', '') : body;
    Map<String, dynamic>? photoData;
    if (isPhoto) {
      final jsonRaw = body.replaceFirst('photo::', '');
      try {
        photoData = Map<String, dynamic>.from(jsonDecode(jsonRaw));
      } catch (_) {
        photoData = null;
      }
    }
    final bubbleBody = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(
        horizontal: isPhoto ? 8 : 14,
        vertical: isPhoto ? 8 : 10,
      ),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.76,
      ),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF0A84FF) : const Color(0xFFE5E5EA),
        borderRadius: BorderRadius.circular(20),
      ),
      child: isPhoto
          ? _PhotoBubbleContent(photoData: photoData, isMe: isMe)
          : Text(
              stickerValue,
              style: TextStyle(
                fontSize: isSticker ? 34 : 16,
                color: isSticker
                    ? const Color(0xFF1C1C1E)
                    : (isMe ? CupertinoColors.white : const Color(0xFF1C1C1E)),
              ),
            ),
    );

    final bubbleMenu = CupertinoContextMenu(
      actions: [
        CupertinoContextMenuAction(
          isDestructiveAction: true,
          trailingIcon: CupertinoIcons.delete,
          onPressed: canDeleteForEveryone
              ? () async {
                  Navigator.of(context).pop();
                  await onDeleteForEveryone();
                }
              : null,
          child: Text(
            canDeleteForEveryone ? 'Eliminar para todos' : 'Solo tus mensajes',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      child: bubbleBody,
    );

    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: SizeTransition(
        sizeFactor: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        ),
        axisAlignment: -1,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.96, end: 1),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          builder: (context, scale, child) {
            return Transform.scale(scale: scale, child: child);
          },
          child: Row(
            mainAxisAlignment: isMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [bubbleMenu],
          ),
        ),
      ),
    );
  }
}

class _PhotoBubbleContent extends StatelessWidget {
  const _PhotoBubbleContent({required this.photoData, required this.isMe});

  final Map<String, dynamic>? photoData;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final photoUrl = photoData?['url']?.toString();
    final caption = photoData?['caption']?.toString().trim() ?? '';
    if (photoUrl == null || photoUrl.isEmpty) {
      return Text(
        'Foto no disponible',
        style: TextStyle(
          color: isMe ? CupertinoColors.white : const Color(0xFF1C1C1E),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(
            photoUrl,
            width: 220,
            height: 220,
            fit: BoxFit.cover,
          ),
        ),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            caption,
            style: TextStyle(
              fontSize: 14,
              color: isMe ? CupertinoColors.white : const Color(0xFF1C1C1E),
            ),
          ),
        ],
      ],
    );
  }
}

class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.currentUserId,
    required this.conversationId,
    this.onInputFocused,
  });

  final String? currentUserId;
  final String conversationId;
  final VoidCallback? onInputFocused;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _picker = ImagePicker();
  bool _sending = false;
  bool _showAttachMenu = false;
  XFile? _pendingPhoto;
  static const List<String> _stickers = [
    '😀',
    '😎',
    '🔥',
    '❤️',
    '😂',
    '😮',
    '👏',
    '🎉',
  ];

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        widget.onInputFocused?.call();
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingPhoto == null) return;

    if (_pendingPhoto != null) {
      await _sendPhotoWithCaption(text);
    } else {
      await _sendBody(text);
    }

    _controller.clear();
    if (mounted) {
      setState(() {
        _pendingPhoto = null;
      });
    }
  }

  Future<void> _sendBody(String body) async {
    if (body.trim().isEmpty || widget.currentUserId == null || _sending) return;

    setState(() {
      _sending = true;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      final senderPhone =
          user?.userMetadata?['phone']?.toString() ?? 'Sin telefono';
      await Supabase.instance.client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': widget.currentUserId,
        'sender_phone': senderPhone,
        'body': body.trim(),
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _sendPhotoWithCaption(String caption) async {
    final photo = _pendingPhoto;
    if (photo == null || widget.currentUserId == null || _sending) return;
    final bytes = await photo.readAsBytes();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sanitizedUserId = widget.currentUserId!.replaceAll('-', '');
    final path = 'messages/$sanitizedUserId/$timestamp.jpg';

    await Supabase.instance.client.storage
        .from('chat-media')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );

    final publicUrl = Supabase.instance.client.storage
        .from('chat-media')
        .getPublicUrl(path);
    final payload = jsonEncode({'url': publicUrl, 'caption': caption});
    await _sendBody('photo::$payload');
  }

  Future<void> _onTapPhoto() async {
    if (_sending) return;
    try {
      final selected = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (selected == null || !mounted) return;
      setState(() {
        _pendingPhoto = selected;
        _showAttachMenu = false;
      });
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('No se pudo abrir fotos'),
          content: const Text('Intenta de nuevo y verifica permisos.'),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _sendSticker(String sticker) async {
    await _sendBody('sticker::$sticker');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pendingPhoto != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(_pendingPhoto!.path),
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Foto adjunta',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _sending
                      ? null
                      : () {
                          setState(() {
                            _pendingPhoto = null;
                          });
                        },
                  child: const Icon(CupertinoIcons.xmark_circle_fill),
                ),
              ],
            ),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: _showAttachMenu ? 112 : 0,
          padding: EdgeInsets.fromLTRB(12, _showAttachMenu ? 8 : 0, 12, 0),
          child: ClipRect(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                children: [
                  Row(
                    children: [
                      _AttachTile(
                        icon: CupertinoIcons.photo_on_rectangle,
                        title: 'Fotos',
                        color: const Color(0xFF34C759),
                        onTap: _onTapPhoto,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Stickers',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 42,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _stickers.length,
                      separatorBuilder: (_, index) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final sticker = _stickers[index];
                        return CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          color: const Color(0xFFE9E9EE),
                          borderRadius: BorderRadius.circular(14),
                          onPressed: _sending
                              ? null
                              : () => _sendSticker(sticker),
                          child: Text(
                            sticker,
                            style: const TextStyle(fontSize: 22),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          child: Row(
            children: [
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () {
                  setState(() {
                    _showAttachMenu = !_showAttachMenu;
                  });
                },
                child: Icon(
                  _showAttachMenu
                      ? CupertinoIcons.xmark_circle_fill
                      : CupertinoIcons.add_circled_solid,
                  size: 30,
                  color: CupertinoColors.systemBlue,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: CupertinoTextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    placeholder: 'iMessage',
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const CupertinoActivityIndicator(radius: 12)
                    : const Icon(CupertinoIcons.arrow_up_circle_fill, size: 34),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AttachTile extends StatelessWidget {
  const _AttachTile({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final tileBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE9E9EE);
    final tileText = isDark
        ? CupertinoColors.white
        : const Color(0xFF1C1C1E);
    final tileBorder = isDark
        ? const Color(0xFF3A3A3C)
        : const Color(0xFFD8D8DD);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: tileBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tileBorder, width: 0.6),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: tileText,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingSpectrum extends StatelessWidget {
  const _RecordingSpectrum({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: values
            .map(
              (v) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0.8),
                  child: Align(
                    alignment: Alignment.center,
                    child: Container(
                      height: 4 + (20 * v.clamp(0.0, 1.0)),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class BluetoothNearbyService {
  BluetoothNearbyService._();

  static final BluetoothNearbyService instance = BluetoothNearbyService._();
  static const _serviceType = 'vmsgchat';

  final NearbyService _nearby = NearbyService();
  final StreamController<List<Device>> _devicesController =
      StreamController<List<Device>>.broadcast();
  final StreamController<BluetoothIncomingMessage> _messagesController =
      StreamController<BluetoothIncomingMessage>.broadcast();
  final _macBridge = MacNearbyChannelBridge();

  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<dynamic>? _dataSub;
  List<Device> _devices = const [];
  bool _started = false;
  DateTime _lastActivityAt = DateTime.now();

  Stream<List<Device>> get devicesStream => _devicesController.stream;
  Stream<BluetoothIncomingMessage> get messagesStream =>
      _messagesController.stream;
  List<Device> get currentDevices => List<Device>.from(_devices);
  bool get hasConnectedPeers => _devices.any(
    (d) => d.state.toString().toLowerCase().contains('connected'),
  );
  bool get requiresExplicitInvite => true;
  DateTime get lastActivityAt => _lastActivityAt;

  Future<void> start({required String displayName}) async {
    if (!(Platform.isIOS || Platform.isMacOS) || _started) return;
    if (Platform.isMacOS) {
      await _macBridge.init(
        displayName: displayName,
        serviceType: _serviceType,
      );
      _stateSub = _macBridge.peersStream.listen((peers) {
        _devices = peers;
        _lastActivityAt = DateTime.now();
        _devicesController.add(_devices);
      });
      _dataSub = _macBridge.messagesStream.listen((incoming) {
        _lastActivityAt = DateTime.now();
        _messagesController.add(incoming);
      });
      await _macBridge.startAdvertisingPeer();
      await _macBridge.startBrowsingForPeers();
      _started = true;
      return;
    }
    await _nearby.init(
      serviceType: _serviceType,
      strategy: Strategy.P2P_CLUSTER,
      deviceName: displayName,
      callback: (dynamic _) {},
    );
    _stateSub = _nearby.stateChangedSubscription(
      callback: (dynamic changed) {
        final incoming = List<Device>.from(changed as List);
        _devices = incoming.where((d) => d.deviceId.isNotEmpty).toList();
        _lastActivityAt = DateTime.now();
        _devicesController.add(_devices);
      },
    );
    _dataSub = _nearby.dataReceivedSubscription(
      callback: (dynamic data) {
        if (data is Message) {
          _lastActivityAt = DateTime.now();
          _messagesController.add(
            BluetoothIncomingMessage(
              deviceId: data.deviceId,
              message: data.message,
            ),
          );
          return;
        }
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          _lastActivityAt = DateTime.now();
          _messagesController.add(
            BluetoothIncomingMessage(
              deviceId:
                  map['senderDeviceId']?.toString() ??
                  map['deviceId']?.toString() ??
                  '',
              message: map['message']?.toString() ?? '',
            ),
          );
          return;
        }
        if (data is String) {
          _lastActivityAt = DateTime.now();
          _messagesController.add(
            BluetoothIncomingMessage(deviceId: '', message: data),
          );
        }
      },
    );
    await _nearby.startAdvertisingPeer();
    await _nearby.startBrowsingForPeers();
    _started = true;
  }

  Future<void> invite(String deviceId, {String? deviceName}) async {
    if (Platform.isMacOS) {
      await _macBridge.invitePeer(deviceID: deviceId, deviceName: deviceName);
      return;
    }
    await _nearby.invitePeer(deviceID: deviceId, deviceName: deviceName);
  }

  Future<void> sendText(String deviceId, String text) async {
    _lastActivityAt = DateTime.now();
    if (Platform.isMacOS) {
      Object? lastError;
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          if (attempt > 0) {
            await _macBridge.invitePeer(deviceID: deviceId);
            await Future<void>.delayed(const Duration(milliseconds: 260));
          }
          await _macBridge.sendMessage(deviceID: deviceId, message: text);
          return;
        } catch (e) {
          lastError = e;
        }
      }
      debugPrint('No se pudo enviar mensaje BT en macOS: $lastError');
      return;
    }
    try {
      await _nearby.sendMessage(deviceId, text);
    } catch (e) {
      Object? lastError = e;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await _nearby.invitePeer(deviceID: deviceId, deviceName: null);
          await Future<void>.delayed(const Duration(milliseconds: 260));
          await _nearby.sendMessage(deviceId, text);
          return;
        } catch (retryError) {
          lastError = retryError;
        }
      }
      debugPrint('No se pudo enviar mensaje BT: $lastError');
    }
  }

  Future<void> stop() async {
    if (Platform.isMacOS) {
      await _macBridge.stopBrowsingForPeers();
      await _macBridge.stopAdvertisingPeer();
    } else {
      await _nearby.stopBrowsingForPeers();
      await _nearby.stopAdvertisingPeer();
    }
    await _stateSub?.cancel();
    await _dataSub?.cancel();
    _stateSub = null;
    _dataSub = null;
    _started = false;
  }

  Future<void> refreshPresence() async {
    if (!(Platform.isIOS || Platform.isMacOS) || !_started) return;
    _lastActivityAt = DateTime.now();
    if (Platform.isMacOS) {
      await _macBridge.startAdvertisingPeer();
      await _macBridge.startBrowsingForPeers();
      return;
    }
    await _nearby.startAdvertisingPeer();
    await _nearby.startBrowsingForPeers();
  }
}

class MacNearbyChannelBridge {
  static const _methodChannel = MethodChannel('vmessages/macos_nearby/methods');
  static const _peersEventChannel = EventChannel(
    'vmessages/macos_nearby/peers',
  );
  static const _messagesEventChannel = EventChannel(
    'vmessages/macos_nearby/messages',
  );

  Stream<List<Device>> get peersStream => _peersEventChannel
      .receiveBroadcastStream()
      .map((event) => _toDevices(event));

  Stream<BluetoothIncomingMessage> get messagesStream => _messagesEventChannel
      .receiveBroadcastStream()
      .map((event) => _toIncoming(event));

  Future<void> init({
    required String displayName,
    required String serviceType,
  }) async {
    await _methodChannel.invokeMethod('init', {
      'deviceName': displayName,
      'serviceType': serviceType,
    });
  }

  Future<void> startAdvertisingPeer() =>
      _methodChannel.invokeMethod('startAdvertisingPeer');

  Future<void> stopAdvertisingPeer() =>
      _methodChannel.invokeMethod('stopAdvertisingPeer');

  Future<void> startBrowsingForPeers() =>
      _methodChannel.invokeMethod('startBrowsingForPeers');

  Future<void> stopBrowsingForPeers() =>
      _methodChannel.invokeMethod('stopBrowsingForPeers');

  Future<void> invitePeer({required String deviceID, String? deviceName}) =>
      _methodChannel.invokeMethod('invitePeer', {
        'deviceID': deviceID,
        'deviceName': deviceName,
      });

  Future<void> sendMessage({
    required String deviceID,
    required String message,
  }) => _methodChannel.invokeMethod('sendMessage', {
    'deviceID': deviceID,
    'message': message,
  });

  List<Device> _toDevices(dynamic event) {
    if (event is! List) return const [];
    return event.map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      return Device(
        map['deviceId']?.toString() ?? '',
        map['deviceName']?.toString() ?? '',
        int.tryParse(map['state']?.toString() ?? '0') ?? 0,
      );
    }).toList();
  }

  BluetoothIncomingMessage _toIncoming(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    return BluetoothIncomingMessage(
      deviceId: map['deviceId']?.toString() ?? '',
      message: map['message']?.toString() ?? '',
    );
  }
}

class IOSBackgroundTaskBridge {
  static const MethodChannel _channel = MethodChannel(
    'vmessages/ios_background_task',
  );

  Future<void> start() => _channel.invokeMethod('start');
  Future<void> stop() => _channel.invokeMethod('stop');
}

class IOSSilentAudioBridge {
  static const MethodChannel _channel = MethodChannel(
    'vmessages/ios_silent_audio',
  );

  Future<void> start() => _channel.invokeMethod('start');
  Future<void> stop() => _channel.invokeMethod('stop');
}

class BluetoothIncomingMessage {
  const BluetoothIncomingMessage({
    required this.deviceId,
    required this.message,
  });

  final String deviceId;
  final String message;
}

class BluetoothConversationScreen extends StatefulWidget {
  const BluetoothConversationScreen({
    super.key,
    required this.service,
    required this.deviceId,
    required this.peerName,
    this.peerAvatarBase64,
    this.peerAvatarHash,
    this.autoOpenVoiceCall = false,
    this.autoOpenVoiceCallAsInitiator = false,
  });

  final BluetoothNearbyService service;
  final String deviceId;
  final String peerName;
  final String? peerAvatarBase64;
  final String? peerAvatarHash;
  final bool autoOpenVoiceCall;
  final bool autoOpenVoiceCallAsInitiator;

  @override
  State<BluetoothConversationScreen> createState() =>
      _BluetoothConversationScreenState();
}

class _BluetoothConversationScreenState
    extends State<BluetoothConversationScreen>
    with WidgetsBindingObserver {
  static const List<String> _quickReactions = ['❤️', '😂', '😮', '🔥', '👍', '👎'];
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  final List<_BluetoothChatMessage> _messages = [];
  StreamSubscription<BluetoothIncomingMessage>? _incomingSub;
  StreamSubscription<List<Device>>? _devicesSub;
  List<Device> _liveNearbyDevices = const [];
  bool _connecting = false;
  bool _sending = false;
  bool _wasKeyboardVisible = false;
  bool _showAttachMenu = false;
  XFile? _pendingPhoto;
  Uint8List? _pendingVoiceBytes;
  int? _pendingVoiceDurationMs;
  bool _recordingVoice = false;
  DateTime? _recordingStartedAt;
  int _recordingElapsedMs = 0;
  Timer? _recordingTicker;
  StreamSubscription<Amplitude>? _amplitudeSub;
  List<double> _recordingSpectrum = List<double>.filled(20, 0.08);
  String? _playingMessageId;
  bool _showWalkieInvite = false;
  bool _peerInBluetoothCall = false;
  String _incomingWalkieInviteId = '';
  String _incomingWalkieSenderDeviceId = '';
  bool _showVoiceCallInvite = false;
  String _peerPresence = 'online';
  String _onlinePeerDeviceId = '';
  String _backgroundPeerDeviceId = '';
  String _lastIncomingDeviceId = '';
  String? _peerAvatarBase64;
  String? _peerAvatarHash;
  bool _peerTyping = false;
  bool _amTyping = false;
  Timer? _typingIdleTimer;
  Timer? _peerTypingExpiryTimer;
  final List<Uint8List> _incomingCallQueue = [];
  final List<String> _recentWalkieAudioSignatures = [];
  bool _playingIncomingCallAudio = false;
  bool _loadingHistory = true;
  bool _plusButtonPressed = false;
  bool _stopButtonPressed = false;
  String? _replyToMessageId;
  String? _replyToPreview;
  Timer? _resumeRelinkTimer;
  int _resumeRelinkAttempts = 0;
  AppLifecycleState _screenLifecycleState = AppLifecycleState.resumed;
  String _newBtMessageId() =>
      'bt_${DateTime.now().microsecondsSinceEpoch}_${DateTime.now().millisecondsSinceEpoch % 1000}';

  String? _extractBtMessageId(String raw) {
    final visibleText = _extractVisibleText(raw);
    if (!visibleText.startsWith('btmsg::')) return null;
    try {
      final payload = visibleText.replaceFirst('btmsg::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final id = map['id']?.toString().trim() ?? '';
      if (id.isEmpty) return null;
      return id;
    } catch (_) {
      return null;
    }
  }

  bool _handleDeliveryAck(String raw) {
    final visibleText = _extractVisibleText(raw);
    if (!visibleText.startsWith('btack::')) return false;
    try {
      final payload = visibleText.replaceFirst('btack::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final id = map['id']?.toString().trim() ?? '';
      if (id.isEmpty) return true;
      var changed = false;
      for (var i = 0; i < _messages.length; i++) {
        final current = _messages[i];
        if (!current.isMe) continue;
        if (current.messageId != id) continue;
        if (current.isDelivered) return true;
        _messages[i] = current.copyWith(isDelivered: true);
        changed = true;
        break;
      }
      if (changed && mounted) {
        setState(() {});
        _saveLocalHistory();
      }
    } catch (_) {}
    return true;
  }

  bool _handleSeenAck(String raw) {
    final visibleText = _extractVisibleText(raw);
    if (!visibleText.startsWith('btseen::')) return false;
    try {
      final payload = visibleText.replaceFirst('btseen::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final id = map['id']?.toString().trim() ?? '';
      if (id.isEmpty) return true;
      final targetIndex = _messages.indexWhere(
        (m) => m.isMe && m.messageId == id,
      );
      if (targetIndex == -1) return true;
      final targetSentAt = _messages[targetIndex].sentAt;
      var changed = false;
      for (var i = 0; i < _messages.length; i++) {
        final current = _messages[i];
        if (!current.isMe) continue;
        if (current.sentAt.isAfter(targetSentAt)) continue;
        if (current.isSeen) continue;
        _messages[i] = current.copyWith(isDelivered: true, isSeen: true);
        changed = true;
      }
      if (changed && mounted) {
        setState(() {});
        _saveLocalHistory();
      }
    } catch (_) {}
    return true;
  }

  Future<void> _sendDeliveryAck(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _sendTextSmart('btack::${jsonEncode({'id': id})}');
  }

  Future<void> _sendSeenAck(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    await _sendTextSmart('btseen::${jsonEncode({'id': id})}');
  }

  Future<void> _sendLatestSeenIfAny() async {
    if (!_canMarkSeenNow()) return;
    if (!mounted) return;
    final latestIncomingWithId = _messages.lastWhere(
      (m) => !m.isMe && m.messageId.trim().isNotEmpty,
      orElse: () => _BluetoothChatMessage(
        messageId: '',
        text: '',
        isMe: false,
        isDelivered: true,
        isSeen: true,
        sentAt: DateTime.fromMillisecondsSinceEpoch(0),
        photoBytes: null,
        audioBytes: null,
        audioDurationMs: null,
        caption: null,
      ),
    );
    final id = latestIncomingWithId.messageId.trim();
    if (id.isEmpty) return;
    await _sendSeenAck(id);
  }

  bool _canMarkSeenNow() {
    if (!mounted) return false;
    if (_screenLifecycleState != AppLifecycleState.resumed) return false;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return false;
    return true;
  }

  bool _isDuplicateLastIncoming(_BluetoothChatMessage incoming) {
    if (_messages.isEmpty) return false;
    final last = _messages.last;
    if (last.isMe) return false;
    final sameText = last.text == incoming.text;
    final sameCaption = (last.caption ?? '') == (incoming.caption ?? '');
    final sameAudioDuration =
        (last.audioDurationMs ?? 0) == (incoming.audioDurationMs ?? 0);
    final samePhoto = last.photoBytes == null && incoming.photoBytes == null
        ? true
        : (last.photoBytes != null &&
              incoming.photoBytes != null &&
              base64Encode(last.photoBytes!) ==
                  base64Encode(incoming.photoBytes!));
    final sameAudio = last.audioBytes == null && incoming.audioBytes == null
        ? true
        : (last.audioBytes != null &&
              incoming.audioBytes != null &&
              base64Encode(last.audioBytes!) ==
                  base64Encode(incoming.audioBytes!));
    return sameText &&
        sameCaption &&
        samePhoto &&
        sameAudio &&
        sameAudioDuration;
  }

  @override
  void initState() {
    super.initState();
    _peerAvatarBase64 = widget.peerAvatarBase64;
    _peerAvatarHash = widget.peerAvatarHash;
    WidgetsBinding.instance.addObserver(this);
    _loadLocalHistory();
    _liveNearbyDevices = widget.service.currentDevices;
    _devicesSub = widget.service.devicesStream.listen((devices) {
      _liveNearbyDevices = devices;
    });
    _incomingSub = widget.service.messagesStream.listen((event) {
      if (!mounted) return;
      if (_handleDeliveryAck(event.message)) return;
      if (_handleSeenAck(event.message)) return;
      if (_handleCallSignal(event.message, event.deviceId)) return;
      if (_handleControlSignal(event.message, event.deviceId)) return;
      final incomingMessageId = _extractBtMessageId(event.message);
      if (incomingMessageId != null) {
        unawaited(_sendDeliveryAck(incomingMessageId));
      }
      final incoming = _parseIncomingMessage(event.message);
      if (incoming == null) return;
      final senderId = event.deviceId.trim();
      if (senderId.isNotEmpty) {
        _lastIncomingDeviceId = senderId;
        if (_peerPresence == 'background') {
          _backgroundPeerDeviceId = senderId;
        } else {
          _onlinePeerDeviceId = senderId;
        }
      }
      if (_isDuplicateLastIncoming(incoming)) return;
      setState(() {
        _messages.add(incoming.copyWith(isMe: false, sentAt: DateTime.now()));
      });
      _saveLocalHistory();
      _animateToBottom();
      final seenId = incoming.messageId.trim();
      if (seenId.isNotEmpty && _canMarkSeenNow()) {
        unawaited(_sendSeenAck(seenId));
      }
    });
    _connectIfNeeded();
    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playingMessageId = null;
      });
    });
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        _ensureBottomVisibleAfterKeyboard();
      }
    });
    if (widget.autoOpenVoiceCall) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openVoiceCall(isInitiator: widget.autoOpenVoiceCallAsInitiator);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _screenLifecycleState = state;
    if (state != AppLifecycleState.resumed) return;
    _startResumeRelink();
    unawaited(_sendLatestSeenIfAny());
  }

  void _startResumeRelink() {
    _resumeRelinkTimer?.cancel();
    _resumeRelinkAttempts = 0;
    _resumeRelinkTimer = Timer.periodic(const Duration(milliseconds: 900), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        _resumeRelinkTimer = null;
        return;
      }
      if (_resumeRelinkAttempts >= 8) {
        timer.cancel();
        _resumeRelinkTimer = null;
        return;
      }
      _resumeRelinkAttempts++;
      try {
        await widget.service.refreshPresence();
      } catch (_) {}
      final targets = _candidateOutgoingPeerIds();
      for (final target in targets) {
        try {
          await widget.service.invite(target, deviceName: widget.peerName);
        } catch (_) {}
      }
    });
  }

  Future<void> _connectIfNeeded() async {
    if (!widget.service.requiresExplicitInvite) {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
      return;
    }
    setState(() {
      _connecting = true;
    });
    try {
      await widget.service.invite(
        _resolveOutgoingDeviceId(),
        deviceName: widget.peerName,
      );
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    }
  }

  String _normalizePeerName(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _resolveOutgoingDeviceId() {
    final onlinePinned = _onlinePeerDeviceId.trim();
    final backgroundPinned = _backgroundPeerDeviceId.trim();
    if (_peerPresence == 'background' && backgroundPinned.isNotEmpty) {
      return backgroundPinned;
    }
    if (_peerPresence != 'background' && onlinePinned.isNotEmpty) {
      return onlinePinned;
    }
    final fallback = widget.deviceId.trim();
    if (_liveNearbyDevices.isEmpty) return fallback;
    final target = _normalizePeerName(widget.peerName);
    final matches = _liveNearbyDevices.where((d) {
      final id = d.deviceId.trim();
      if (id.isEmpty) return false;
      final name = _normalizePeerName(d.deviceName);
      return name == target || id == fallback;
    }).toList();
    if (matches.isEmpty) return fallback;
    matches.sort((a, b) {
      final aConnected = a.state.toString().toLowerCase().contains('connected');
      final bConnected = b.state.toString().toLowerCase().contains('connected');
      if (aConnected != bConnected) return bConnected ? 1 : -1;
      final aIsFallback = a.deviceId.trim() == fallback;
      final bIsFallback = b.deviceId.trim() == fallback;
      if (aIsFallback != bIsFallback) return aIsFallback ? 1 : -1;
      return 0;
    });
    final resolved = matches.first.deviceId.trim();
    if (resolved.isNotEmpty) {
      if (_peerPresence == 'background') {
        _backgroundPeerDeviceId = resolved;
      } else {
        _onlinePeerDeviceId = resolved;
      }
    }
    return resolved;
  }

  List<String> _candidateOutgoingPeerIds() {
    final out = <String>{};
    final resolved = _resolveOutgoingDeviceId().trim();
    if (resolved.isNotEmpty) out.add(resolved);
    final onlinePinned = _onlinePeerDeviceId.trim();
    if (onlinePinned.isNotEmpty) out.add(onlinePinned);
    final backgroundPinned = _backgroundPeerDeviceId.trim();
    if (backgroundPinned.isNotEmpty) out.add(backgroundPinned);
    final lastIncoming = _lastIncomingDeviceId.trim();
    if (lastIncoming.isNotEmpty) out.add(lastIncoming);
    final fallback = widget.deviceId.trim();
    if (fallback.isNotEmpty) out.add(fallback);
    if (_peerPresence == 'background') {
      for (final d in _liveNearbyDevices) {
        final id = d.deviceId.trim();
        if (id.isNotEmpty) out.add(id);
      }
    }
    return out.toList();
  }

  Future<void> _sendTextSmart(String payload) async {
    final targets = _candidateOutgoingPeerIds();
    for (final target in targets) {
      try {
        await widget.service.invite(target, deviceName: widget.peerName);
      } catch (_) {}
      try {
        await widget.service.sendText(target, payload);
      } catch (_) {}
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if ((text.isEmpty && _pendingPhoto == null && _pendingVoiceBytes == null) ||
        _sending) {
      return;
    }
    setState(() {
      _sending = true;
    });
    try {
      if (_pendingPhoto != null) {
        await _sendPhotoWithCaption(text);
      } else if (_pendingVoiceBytes != null) {
        await _sendVoiceNote();
      } else {
        final id = _newBtMessageId();
        final replyToId = _replyToMessageId;
        final replyToPreview = _replyToPreview;
        await _sendTextSmart(
          'btmsg::${jsonEncode({'id': id, 'type': 'text', 'text': text, 'replyToMessageId': replyToId, 'replyToPreview': replyToPreview})}',
        );
        if (!mounted) return;
        setState(() {
            _messages.add(
              _BluetoothChatMessage(
                messageId: id,
                text: text,
                isMe: true,
                isDelivered: false,
                isSeen: false,
                sentAt: DateTime.now(),
              photoBytes: null,
              audioBytes: null,
              audioDurationMs: null,
              caption: null,
              replyToMessageId: replyToId,
              replyToPreview: replyToPreview,
            ),
          );
        });
        await _updateNearbyListLastMessage(text.trim());
      }
      if (!mounted) return;
      setState(() {
        _pendingPhoto = null;
        _pendingVoiceBytes = null;
        _pendingVoiceDurationMs = null;
        _replyToMessageId = null;
        _replyToPreview = null;
      });
      _saveLocalHistory();
      _controller.clear();
      _onComposerChanged('');
      _animateToBottom();
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _sendPhotoWithCaption(String caption) async {
    final photo = _pendingPhoto;
    if (photo == null) return;
    final bytes = await photo.readAsBytes();
    final id = _newBtMessageId();
    final replyToId = _replyToMessageId;
    final replyToPreview = _replyToPreview;
    final payload = jsonEncode({
      'id': id,
      'type': 'photo',
      'bytes': base64Encode(bytes),
      'caption': caption,
      'replyToMessageId': replyToId,
      'replyToPreview': replyToPreview,
    });
    await _sendTextSmart('btmsg::$payload');
    if (!mounted) return;
    setState(() {
      _messages.add(
        _BluetoothChatMessage(
          messageId: id,
          text: '',
          isMe: true,
          isDelivered: false,
          isSeen: false,
          sentAt: DateTime.now(),
          photoBytes: bytes,
          audioBytes: null,
          audioDurationMs: null,
          caption: caption.trim().isEmpty ? null : caption.trim(),
          replyToMessageId: replyToId,
          replyToPreview: replyToPreview,
        ),
      );
    });
    _saveLocalHistory();
    await _updateNearbyListLastMessage(
      caption.trim().isEmpty ? '📷 Foto' : '📷 ${caption.trim()}',
    );
  }

  Future<void> _sendVoiceNote() async {
    final voice = _pendingVoiceBytes;
    if (voice == null) return;
    final id = _newBtMessageId();
    final replyToId = _replyToMessageId;
    final replyToPreview = _replyToPreview;
    final payload = jsonEncode({
      'id': id,
      'type': 'voice',
      'bytes': base64Encode(voice),
      'durationMs': _pendingVoiceDurationMs ?? 0,
      'replyToMessageId': replyToId,
      'replyToPreview': replyToPreview,
    });
    await _sendTextSmart('btmsg::$payload');
    if (!mounted) return;
    setState(() {
      _messages.add(
        _BluetoothChatMessage(
          messageId: id,
          text: '',
          isMe: true,
          isDelivered: false,
          isSeen: false,
          sentAt: DateTime.now(),
          photoBytes: null,
          audioBytes: voice,
          audioDurationMs: _pendingVoiceDurationMs,
          caption: null,
          replyToMessageId: replyToId,
          replyToPreview: replyToPreview,
        ),
      );
    });
    _saveLocalHistory();
    await _updateNearbyListLastMessage('🎤 Audio');
  }

  Future<void> _updateNearbyListLastMessage(String preview) async {
    try {
      final cleanPreview = preview.trim().isEmpty ? 'Nuevo mensaje' : preview.trim();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('bt_chat_meta') ?? '{}';
      final decoded = jsonDecode(raw);
      final map = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      final key = widget.deviceId.trim();
      final current = NearbyChatMeta.fromJson(map[key]);
      map[key] = NearbyChatMeta(
        lastMessage: cleanPreview,
        lastMessageAt: DateTime.now(),
        hasUnread: false,
        peerPresence: current?.peerPresence ?? 'online',
        peerPresenceAt: current?.peerPresenceAt,
        peerAvatarBase64: current?.peerAvatarBase64,
        peerAvatarHash: current?.peerAvatarHash,
      ).toJson();
      await prefs.setString('bt_chat_meta', jsonEncode(map));
    } catch (_) {}
  }

  Future<void> _toggleVoiceRecording() async {
    if (_sending) return;
    if (_recordingVoice) {
      await _stopVoiceRecording();
      return;
    }
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (_) => CupertinoAlertDialog(
          title: const Text('Permiso de microfono'),
          content: const Text(
            'Activa el microfono para enviar audios desde este dispositivo.',
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final dir = await _runtimeTempDir();
    final path =
        '${dir.path}/bt_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: path,
    );
    if (!mounted) return;
    await _amplitudeSub?.cancel();
    _amplitudeSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 90))
        .listen((amp) {
          if (!mounted) return;
          final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
          setState(() {
            _recordingSpectrum = [
              ..._recordingSpectrum.sublist(1),
              0.08 + (normalized * 0.92),
            ];
          });
        });
    setState(() {
      _pendingPhoto = null;
      _showAttachMenu = false;
      _recordingVoice = true;
      _recordingStartedAt = DateTime.now();
      _recordingElapsedMs = 0;
      _recordingSpectrum = List<double>.filled(20, 0.08);
    });
    _startRecordingUiTicker();
  }

  Future<void> _stopVoiceRecording() async {
    final path = await _audioRecorder.stop();
    if (!mounted) return;
    final start = _recordingStartedAt;
    final durationMs = start == null
        ? 0
        : DateTime.now().difference(start).inMilliseconds;
    Uint8List? bytes;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      }
    }
    setState(() {
      _recordingVoice = false;
      _recordingStartedAt = null;
      _pendingVoiceBytes = bytes;
      _pendingVoiceDurationMs = durationMs > 0 ? durationMs : null;
      _recordingElapsedMs = 0; 
      _recordingSpectrum = List<double>.filled(20, 0.08);
    });
    _recordingTicker?.cancel();
    _recordingTicker = null;
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
  }

  Future<void> _togglePendingVoicePreview() async {
    final voice = _pendingVoiceBytes;
    if (voice == null || voice.isEmpty) return;
    const draftId = 'draft_voice_preview';
    if (_playingMessageId == draftId) {
      await _audioPlayer.stop();
      if (!mounted) return;
      setState(() {
        _playingMessageId = null;
      });
      return;
    }
    final dir = await _runtimeTempDir();
    final path = '${dir.path}/$draftId.m4a';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(voice, flush: true);
    await _audioPlayer.stop();
    await _audioPlayer.play(DeviceFileSource(path));
    if (!mounted) return;
    setState(() {
      _playingMessageId = draftId;
    });
  }

  Future<void> _pulsePlusButton() async {
    if (!mounted) return;
    setState(() {
      _plusButtonPressed = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 110));
    if (!mounted) return;
    setState(() {
      _plusButtonPressed = false;
    });
  }

  Future<void> _pulseStopButton() async {
    if (!mounted) return;
    setState(() {
      _stopButtonPressed = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    setState(() {
      _stopButtonPressed = false;
    });
  }

  Future<void> _onPrimaryActionPressed() async {
    if (_sending) return;
    if (_recordingVoice) {
      await _pulseStopButton();
      await _stopVoiceRecording();
      return;
    }
    await _send();
  }

  Future<void> _playVoiceMessage(_BluetoothChatMessage message) async {
    if (message.audioBytes == null) return;
    final messageId =
        '${message.sentAt.millisecondsSinceEpoch}_${message.isMe}';
    if (_playingMessageId == messageId) {
      await _audioPlayer.stop();
      if (!mounted) return;
      setState(() {
        _playingMessageId = null;
      });
      return;
    }
    final dir = await _runtimeTempDir();
    final path = '${dir.path}/play_voice_$messageId.m4a';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(message.audioBytes!, flush: true);
    await _audioPlayer.stop();
    await _audioPlayer.play(DeviceFileSource(path));
    if (!mounted) return;
    setState(() {
      _playingMessageId = messageId;
    });
  }

  bool _handleCallSignal(String raw, String incomingDeviceId) {
    final visibleText = _extractVisibleText(raw);
    if (visibleText.startsWith('btvoicecall::')) {
      try {
        final payload = visibleText.replaceFirst('btvoicecall::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString() ?? '';
        if (type == 'invite') {
          setState(() {
            _showVoiceCallInvite = true;
          });
        } else if (type == 'end') {
          setState(() {
            _showVoiceCallInvite = false;
          });
        }
      } catch (_) {}
      return true;
    }
    if (visibleText.startsWith('btcall::')) {
      try {
        final payload = visibleText.replaceFirst('btcall::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString() ?? '';
        if (type == 'start') {
          final senderId = incomingDeviceId.trim();
          final inviteId = map['inviteId']?.toString().trim() ?? '';
          setState(() {
            _showWalkieInvite = true;
            _peerInBluetoothCall = true;
            _incomingWalkieInviteId = inviteId;
            if (senderId.isNotEmpty) {
              _incomingWalkieSenderDeviceId = senderId;
            }
          });
        } else if (type == 'end') {
          setState(() {
            _showWalkieInvite = false;
            _peerInBluetoothCall = false;
            _incomingWalkieInviteId = '';
            _incomingWalkieSenderDeviceId = '';
          });
        }
      } catch (_) {}
      return true;
    }
    if (visibleText.startsWith('btcallvoice::')) {
      try {
        final payload = visibleText.replaceFirst('btcallvoice::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final bytesRaw = map['bytes']?.toString() ?? '';
        final durationRaw = map['durationMs']?.toString() ?? '0';
        if (bytesRaw.isEmpty) return true;
        final signature =
            '${bytesRaw.length}:${bytesRaw.hashCode}:$durationRaw';
        if (_recentWalkieAudioSignatures.contains(signature)) return true;
        _recentWalkieAudioSignatures.add(signature);
        if (_recentWalkieAudioSignatures.length > 80) {
          _recentWalkieAudioSignatures.removeAt(0);
        }
        final bytes = base64Decode(bytesRaw);
        _incomingCallQueue.add(bytes);
        _playIncomingCallQueue();
      } catch (_) {}
      return true;
    }
    return false;
  }

  bool _handleControlSignal(String raw, String incomingDeviceId) {
    final visibleText = _extractVisibleText(raw);
    if (!visibleText.startsWith('btctl::')) return false;
    try {
      final payload = visibleText.replaceFirst('btctl::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final action = map['action']?.toString() ?? '';
      if (action == 'presence') {
        final state = map['state']?.toString() ?? 'online';
        final incomingAvatarB64 = map['avatarB64']?.toString().trim();
        final incomingAvatarHash = map['avatarHash']?.toString().trim();
        final senderId = incomingDeviceId.trim();
        if (state == 'background') {
          final currentOnline = _onlinePeerDeviceId.trim();
          if (currentOnline.isEmpty) {
            final currentResolved = _resolveOutgoingDeviceId().trim();
            if (currentResolved.isNotEmpty) {
              _onlinePeerDeviceId = currentResolved;
            }
          }
          if (senderId.isNotEmpty) {
            _backgroundPeerDeviceId = senderId;
          }
        } else {
          if (senderId.isNotEmpty) {
            _onlinePeerDeviceId = senderId;
          }
        }
        if (!mounted) return true;
        final shouldUpdateAvatar = incomingAvatarHash?.isNotEmpty == true
            ? incomingAvatarHash != _peerAvatarHash
            : incomingAvatarB64?.isNotEmpty == true && _peerAvatarBase64 == null;
        if (state == _peerPresence && !shouldUpdateAvatar) return true;
        setState(() {
          _peerPresence = state;
          if (incomingAvatarB64?.isNotEmpty == true && shouldUpdateAvatar) {
            _peerAvatarBase64 = incomingAvatarB64;
            _peerAvatarHash = incomingAvatarHash?.isNotEmpty == true
                ? incomingAvatarHash
                : incomingAvatarB64.hashCode.toString();
          }
        });
        return true;
      }
      if (action == 'typing') {
        final isTyping = map['isTyping'] == true;
        _setPeerTyping(isTyping);
        return true;
      }
      if (action == 'reaction') {
        final messageId = map['messageId']?.toString().trim() ?? '';
        final reactionRaw = map['reaction']?.toString().trim() ?? '';
        if (messageId.isEmpty) return true;
        _applyReactionLocally(
          messageId: messageId,
          reaction: reactionRaw.isEmpty ? null : reactionRaw,
        );
        return true;
      }
      if (action != 'delete') return true;
      final messageId = map['messageId']?.toString() ?? '';
      if (messageId.isEmpty) return true;
      setState(() {
        _messages.removeWhere((m) => m.messageId == messageId);
      });
      _saveLocalHistory();
    } catch (_) {}
    return true;
  }

  Future<void> _deleteMessageForEveryone(_BluetoothChatMessage message) async {
    if (!message.isMe) return;
    setState(() {
      _messages.removeWhere((m) => m.messageId == message.messageId);
    });
    await _saveLocalHistory();
    await _sendTextSmart(
      'btctl::${jsonEncode({'action': 'delete', 'messageId': message.messageId})}',
    );
  }

  void _applyReactionLocally({
    required String messageId,
    required String? reaction,
  }) {
    final targetIndex = _messages.indexWhere((m) => m.messageId == messageId);
    if (targetIndex < 0) return;
    setState(() {
      _messages[targetIndex] = _messages[targetIndex].copyWith(
        reaction: reaction,
        clearReaction: reaction == null,
      );
    });
    unawaited(_saveLocalHistory());
  }

  Future<void> _setMessageReaction(
    _BluetoothChatMessage message,
    String? reaction,
  ) async {
    _applyReactionLocally(messageId: message.messageId, reaction: reaction);
    await _sendTextSmart(
      'btctl::${jsonEncode({'action': 'reaction', 'messageId': message.messageId, 'reaction': reaction ?? ''})}',
    );
  }

  void _setPeerTyping(bool value) {
    _peerTypingExpiryTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _peerTyping = value;
    });
    if (value) {
      _animateToBottom();
    }
    if (value) {
      _peerTypingExpiryTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        setState(() {
          _peerTyping = false;
        });
      });
    }
  }

  void _onComposerChanged(String value) {
    final hasText = value.trim().isNotEmpty;
    if (!hasText) {
      _typingIdleTimer?.cancel();
      _updateTypingState(false);
      return;
    }
    _updateTypingState(true);
    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(const Duration(milliseconds: 1400), () {
      _updateTypingState(false);
    });
  }

  void _updateTypingState(bool isTyping) {
    if (_amTyping == isTyping) return;
    _amTyping = isTyping;
    unawaited(
      _sendTextSmart(
        'btctl::${jsonEncode({'action': 'typing', 'isTyping': isTyping})}',
      ),
    );
  }

  Future<void> _openWalkieTalkie({required bool isInitiator}) async {
    String? sessionInviteId;
    String targetId = widget.deviceId;
    if (isInitiator) {
      targetId = _resolveOutgoingDeviceId();
      final inviteId = DateTime.now().microsecondsSinceEpoch.toString();
      sessionInviteId = inviteId;
      final payload = 'btcall::${jsonEncode({'type': 'start', 'inviteId': inviteId})}';
      for (var i = 0; i < 3; i++) {
        Future<void>.delayed(Duration(milliseconds: i * 220), () {
          _sendTextSmart(payload);
        });
      }
    } else {
      targetId = _incomingWalkieSenderDeviceId.trim().isNotEmpty
          ? _incomingWalkieSenderDeviceId.trim()
          : _resolveOutgoingDeviceId();
      sessionInviteId = _incomingWalkieInviteId.trim().isEmpty
          ? null
          : _incomingWalkieInviteId.trim();
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => WalkieTalkieScreen(
          service: widget.service,
          deviceId: targetId,
          peerName: widget.peerName,
          sendStartSignalOnOpen: isInitiator,
          inviteId: sessionInviteId,
          isJoiner: !isInitiator,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _showWalkieInvite = false;
      _peerInBluetoothCall = false;
      _incomingWalkieInviteId = '';
      _incomingWalkieSenderDeviceId = '';
    });
  }

  Future<void> _openVoiceCall({required bool isInitiator}) async {
    if (isInitiator) {
      await _sendTextSmart(
        'btvoicecall::${jsonEncode({'type': 'invite'})}',
      );
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => BluetoothVoiceCallScreen(
          service: widget.service,
          deviceId: widget.deviceId,
          peerName: widget.peerName,
          isInitiator: isInitiator,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _showVoiceCallInvite = false;
    });
  }

  Future<void> _playIncomingCallQueue() async {
    if (_playingIncomingCallAudio || _incomingCallQueue.isEmpty) return;
    _playingIncomingCallAudio = true;
    try {
      while (_incomingCallQueue.isNotEmpty) {
        final bytes = _incomingCallQueue.removeAt(0);
        final dir = await _runtimeTempDir();
        final path =
            '${dir.path}/bt_call_in_${DateTime.now().microsecondsSinceEpoch}.m4a';
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        await _audioPlayer.play(DeviceFileSource(path));
        await _audioPlayer.onPlayerComplete.first;
      }
    } catch (_) {
    } finally {
      _playingIncomingCallAudio = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _typingIdleTimer?.cancel();
    _peerTypingExpiryTimer?.cancel();
    _resumeRelinkTimer?.cancel();
    if (_amTyping) {
      unawaited(
        _sendTextSmart(
          'btctl::${jsonEncode({'action': 'typing', 'isTyping': false})}',
        ),
      );
    }
    _devicesSub?.cancel();
    _incomingSub?.cancel();
    _recordingTicker?.cancel();
    _amplitudeSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _animateToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  void _ensureBottomVisibleAfterKeyboard() {
    _animateToBottom();
    Future<void>.delayed(const Duration(milliseconds: 120), _animateToBottom);
  }

  Map<String, dynamic> _decodeIncomingPayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return const {};
  }

  String _extractVisibleText(String raw) {
    final decoded = _decodeIncomingPayload(raw);
    final fromPayload = decoded['message']?.toString() ?? '';
    if (fromPayload.trim().isNotEmpty) return fromPayload.trim();
    return raw.trim();
  }

  String _formatVoiceDuration(int? durationMs) {
    final totalSeconds = ((durationMs ?? 0) / 1000).round();
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _messagePreview(_BluetoothChatMessage m) {
    if (m.text.trim().isNotEmpty) return m.text.trim();
    if ((m.caption ?? '').trim().isNotEmpty) return m.caption!.trim();
    if (m.audioBytes != null) return 'Nota de voz';
    if (m.photoBytes != null) return 'Foto';
    return 'Mensaje';
  }

  String _resolveReplyPreview(_BluetoothChatMessage m) {
    final direct = m.replyToPreview?.trim() ?? '';
    if (direct.isNotEmpty) return direct;
    final refId = m.replyToMessageId?.trim() ?? '';
    if (refId.isEmpty) return '';
    final idx = _messages.lastIndexWhere((x) => x.messageId == refId);
    if (idx < 0) return '';
    return _messagePreview(_messages[idx]);
  }

  void _startRecordingUiTicker() {
    _recordingTicker?.cancel();
    _recordingTicker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final startedAt = _recordingStartedAt;
      if (!mounted || startedAt == null) return;
      setState(() {
        _recordingElapsedMs = DateTime.now()
            .difference(startedAt)
            .inMilliseconds;
      });
    });
  }

  String get _historyKey => 'bt_history_device_${widget.deviceId.trim()}';

  Future<void> _loadLocalHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw == null || raw.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loadingHistory = false;
        });
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        if (!mounted) return;
        setState(() {
          _loadingHistory = false;
        });
        return;
      }
      final loaded = decoded
          .map((item) => _BluetoothChatMessage.fromJson(item))
          .whereType<_BluetoothChatMessage>()
          .toList();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(loaded);
        _loadingHistory = false;
      });
      _animateToBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
      });
    }
  }

  Future<void> _saveLocalHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode(_messages.map((m) => m.toJson()).toList());
      await prefs.setString(_historyKey, payload);
    } catch (_) {}
  }

  Future<void> _clearChatHistory() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Vaciar chat'),
        content: const Text(
          'Se eliminarán todos los mensajes de este chat en este dispositivo.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Vaciar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _messages.clear();
      _showAttachMenu = false;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (_) {}
  }

  _BluetoothChatMessage? _parseIncomingMessage(String raw) {
    final visibleText = _extractVisibleText(raw);
    if (visibleText.isEmpty) return null;
    if (visibleText.startsWith('btcall::') ||
        visibleText.startsWith('btcallvoice::') ||
        visibleText.startsWith('btvoicecall::') ||
        visibleText.startsWith('btack::') ||
        visibleText.startsWith('btseen::') ||
        visibleText.startsWith('btctl::')) {
      return null;
    }
    if (visibleText.startsWith('btmsg::')) {
      try {
        final payload = visibleText.replaceFirst('btmsg::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final id = map['id']?.toString() ?? _newBtMessageId();
        final type = map['type']?.toString() ?? 'text';
        if (type == 'photo') {
          final bytesRaw = map['bytes']?.toString() ?? '';
          if (bytesRaw.isEmpty) return null;
          final bytes = base64Decode(bytesRaw);
          return _BluetoothChatMessage(
            messageId: id,
            text: '',
            isMe: false,
            isDelivered: true,
            isSeen: true,
            sentAt: DateTime.now(),
            photoBytes: bytes,
            audioBytes: null,
            audioDurationMs: null,
            caption: map['caption']?.toString().trim().isEmpty == true
                ? null
                : map['caption']?.toString().trim(),
            replyToMessageId: map['replyToMessageId']?.toString(),
            replyToPreview: map['replyToPreview']?.toString(),
          );
        }
        if (type == 'voice') {
          final bytesRaw = map['bytes']?.toString() ?? '';
          if (bytesRaw.isEmpty) return null;
          final bytes = base64Decode(bytesRaw);
          final durationMs = int.tryParse(map['durationMs']?.toString() ?? '');
          return _BluetoothChatMessage(
            messageId: id,
            text: '',
            isMe: false,
            isDelivered: true,
            isSeen: true,
            sentAt: DateTime.now(),
            photoBytes: null,
            audioBytes: bytes,
            audioDurationMs: durationMs,
            caption: null,
            replyToMessageId: map['replyToMessageId']?.toString(),
            replyToPreview: map['replyToPreview']?.toString(),
          );
        }
        final text = map['text']?.toString() ?? '';
        if (text.trim().isEmpty) return null;
        return _BluetoothChatMessage(
          messageId: id,
          text: text.trim(),
          isMe: false,
          isDelivered: true,
          isSeen: true,
          sentAt: DateTime.now(),
          photoBytes: null,
          audioBytes: null,
          audioDurationMs: null,
          caption: null,
          replyToMessageId: map['replyToMessageId']?.toString(),
          replyToPreview: map['replyToPreview']?.toString(),
        );
      } catch (_) {
        return null;
      }
    }
    if (visibleText.startsWith('btphoto::')) {
      try {
        final payload = visibleText.replaceFirst('btphoto::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final bytesRaw = map['bytes']?.toString() ?? '';
        if (bytesRaw.isEmpty) return null;
        final bytes = base64Decode(bytesRaw);
        return _BluetoothChatMessage(
          messageId: _newBtMessageId(),
          text: '',
          isMe: false,
          isDelivered: true,
          isSeen: true,
          sentAt: DateTime.now(),
          photoBytes: bytes,
          audioBytes: null,
          audioDurationMs: null,
          caption: map['caption']?.toString().trim().isEmpty == true
              ? null
              : map['caption']?.toString().trim(),
        );
      } catch (_) {
        return null;
      }
    }
    if (visibleText.startsWith('btvoice::')) {
      try {
        final payload = visibleText.replaceFirst('btvoice::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final bytesRaw = map['bytes']?.toString() ?? '';
        if (bytesRaw.isEmpty) return null;
        final bytes = base64Decode(bytesRaw);
        final durationMs = int.tryParse(map['durationMs']?.toString() ?? '');
        return _BluetoothChatMessage(
          messageId: _newBtMessageId(),
          text: '',
          isMe: false,
          isDelivered: true,
          isSeen: true,
          sentAt: DateTime.now(),
          photoBytes: null,
          audioBytes: bytes,
          audioDurationMs: durationMs,
          caption: null,
        );
      } catch (_) {
        return null;
      }
    }
    return _BluetoothChatMessage(
      messageId: _newBtMessageId(),
      text: visibleText,
      isMe: false,
      isDelivered: true,
      isSeen: true,
      sentAt: DateTime.now(),
      photoBytes: null,
      audioBytes: null,
      audioDurationMs: null,
      caption: null,
    );
  }

  Future<void> _onTapPhoto() async {
    if (_sending) return;
    try {
      final selected = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 65,
      );
      if (selected == null || !mounted) return;
      setState(() {
        _pendingPhoto = selected;
        _showAttachMenu = false;
      });
      _focusNode.requestFocus();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final incomingBubbleColor = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFE5E5EA);
    final incomingTextColor = isDark
        ? CupertinoColors.white
        : const Color(0xFF1C1C1E);
    final reactionBgColor = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF2F2F7);
    final reactionBorderColor = isDark
        ? const Color(0xFF3A3A3C)
        : const Color(0xFFD1D1D6);
    final inviteCardBg = isDark
        ? const Color(0xFF1E2D3A)
        : const Color(0xFFEAF7FF);
    final inviteTextColor = isDark
        ? CupertinoColors.white
        : const Color(0xFF1C1C1E);
    final composerPanelColor = isDark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFF2F2F7);
    final composerFieldColor = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF2F2F7);
    final composerTextColor = isDark
        ? CupertinoColors.white
        : const Color(0xFF1C1C1E);
    final composerPlaceholderColor = isDark
        ? const Color(0xFF8E8E93)
        : const Color(0xFF8E8E93);
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    if (keyboardVisible && !_wasKeyboardVisible) {
      _wasKeyboardVisible = true;
      _ensureBottomVisibleAfterKeyboard();
    } else if (!keyboardVisible && _wasKeyboardVisible) {
      _wasKeyboardVisible = false;
    }

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        previousPageTitle: 'Mensajes',
        middle: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ProfileAvatar(
                  imageBase64: _peerAvatarBase64,
                  imageBase64Hash: _peerAvatarHash,
                  label: widget.peerName,
                  size: 24,
                ),
                const SizedBox(width: 6),
                Text(widget.peerName),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _peerPresence == 'background'
                        ? const Color(0xFFFF9500)
                        : CupertinoColors.activeGreen,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _peerPresence == 'background'
                      ? 'En segundo plano'
                      : 'En linea',
                  style: TextStyle(
                    fontSize: 11,
                    color: _peerPresence == 'background'
                        ? const Color(0xFFFF9500)
                        : CupertinoColors.activeGreen,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 44),
              onPressed: () => _openWalkieTalkie(isInitiator: true),
              child: const Icon(
                CupertinoIcons.waveform_path,
                color: CupertinoColors.systemBlue,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: () => _openVoiceCall(isInitiator: true),
              child: const Icon(
                CupertinoIcons.phone_fill,
                color: CupertinoColors.systemGreen,
                size: 30,
              ),
            ),
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  if (_showVoiceCallInvite)
                    CupertinoButton(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      onPressed: () => _openVoiceCall(isInitiator: false),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: inviteCardBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              CupertinoIcons.phone_fill,
                              size: 18,
                              color: Color(0xFF0A84FF),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${widget.peerName} te llama por Bluetooth',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: inviteTextColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_showWalkieInvite && _peerInBluetoothCall)
                    CupertinoButton(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      onPressed: () => _openWalkieTalkie(isInitiator: false),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: inviteCardBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              CupertinoIcons.waveform_circle_fill,
                              size: 18,
                              color: Color(0xFF0A84FF),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${widget.peerName} quiere hablar contigo por walkie talkie',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: inviteTextColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_connecting)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: CupertinoActivityIndicator(),
                    ),
                  Expanded(
                    child: _loadingHistory
                        ? const Center(
                            child: CupertinoActivityIndicator(radius: 14),
                          )
                        : _messages.isEmpty
                        ? const Center(
                            child: Text(
                              'Listo para enviar mensajes por Bluetooth.',
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(12, 16, 12, 84),
                            itemCount: _messages.length + (_peerTyping ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (_peerTyping && index == _messages.length) {
                                return Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    right: 4,
                                    bottom: 8,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: incomingBubbleColor,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: const _TypingDots(),
                                    ),
                                  ),
                                );
                              }
                              final message = _messages[index];
                              final isLastOutgoing = message.isMe &&
                                  !_messages
                                      .skip(index + 1)
                                      .any((m) => m.isMe);
                              final replyPreview = _resolveReplyPreview(message);
                              return Dismissible(
                                key: ValueKey('reply_${message.messageId}_$index'),
                                direction: DismissDirection.startToEnd,
                                dismissThresholds: const {
                                  DismissDirection.startToEnd: 0.24,
                                },
                                confirmDismiss: (_) async {
                                  if (!mounted) return false;
                                  setState(() {
                                    _replyToMessageId = message.messageId;
                                    _replyToPreview = _messagePreview(message);
                                  });
                                  return false;
                                },
                                background: Container(
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 16),
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: CupertinoColors.systemBlue.withValues(
                                        alpha: 0.16,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      CupertinoIcons.reply,
                                      color: CupertinoColors.systemBlue,
                                      size: 19,
                                    ),
                                  ),
                                ),
                                child: Row(
                                mainAxisAlignment: message.isMe
                                    ? MainAxisAlignment.end
                                    : MainAxisAlignment.start,
                                children: [
                                  Column(
                                    crossAxisAlignment: message.isMe
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                    children: [
                                      CupertinoContextMenu(
                                        actions: [
                                          CupertinoContextMenuAction(
                                            onPressed: () {},
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceEvenly,
                                              children: [
                                                for (final emoji
                                                    in _quickReactions)
                                                  GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () async {
                                                      Navigator.of(context).pop();
                                                      await _setMessageReaction(
                                                        message,
                                                        emoji,
                                                      );
                                                    },
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 2,
                                                          ),
                                                      child: Text(
                                                        emoji,
                                                        style: const TextStyle(
                                                          fontSize: 24,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          CupertinoContextMenuAction(
                                            trailingIcon: CupertinoIcons.doc_on_doc,
                                            onPressed: () async {
                                              final navigator = Navigator.of(
                                                context,
                                              );
                                              final copyText =
                                                  message.text.trim().isNotEmpty
                                                  ? message.text.trim()
                                                  : ((message.caption ?? '')
                                                        .trim()
                                                        .isNotEmpty
                                                    ? message.caption!.trim()
                                                    : (message.audioBytes != null
                                                          ? 'Nota de voz'
                                                          : 'Mensaje'));
                                              await Clipboard.setData(
                                                ClipboardData(text: copyText),
                                              );
                                              if (!mounted) return;
                                              navigator.pop();
                                            },
                                            child: const Text('Copiar'),
                                          ),
                                          CupertinoContextMenuAction(
                                            onPressed: () async {
                                              Navigator.of(context).pop();
                                              await _setMessageReaction(
                                                message,
                                                null,
                                              );
                                            },
                                            child: const Text('Quitar reaccion'),
                                          ),
                                          CupertinoContextMenuAction(
                                            isDestructiveAction: true,
                                            trailingIcon: CupertinoIcons.delete,
                                            onPressed: message.isMe
                                                ? () async {
                                                    Navigator.of(context).pop();
                                                    await _deleteMessageForEveryone(
                                                      message,
                                                    );
                                                  }
                                                : null,
                                            child: Text(
                                              message.isMe
                                                  ? 'Eliminar para todos'
                                                  : 'Solo remitente',
                                            ),
                                          ),
                                        ],
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(top: 8),
                                              child: Container(
                                                margin: const EdgeInsets.only(
                                                  bottom: 4,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 10,
                                                    ),
                                                constraints: BoxConstraints(
                                                  maxWidth:
                                                      MediaQuery.of(
                                                        context,
                                                      ).size.width *
                                                      0.76,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: message.isMe
                                                      ? const Color(0xFF0A84FF)
                                                      : incomingBubbleColor,
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                                child:
                                                    message.photoBytes == null &&
                                                        message.audioBytes ==
                                                            null
                                                    ? Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (replyPreview
                                                              .isNotEmpty) ...[
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal: 8,
                                                                    vertical: 5,
                                                                  ),
                                                              margin:
                                                                  const EdgeInsets.only(
                                                                    bottom: 6,
                                                                  ),
                                                              decoration: BoxDecoration(
                                                                color: (message
                                                                            .isMe
                                                                        ? CupertinoColors
                                                                            .white
                                                                        : CupertinoColors
                                                                            .black)
                                                                    .withValues(
                                                                  alpha: 0.12,
                                                                ),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                  8,
                                                                ),
                                                              ),
                                                              child: Text(
                                                                replyPreview,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  color: message
                                                                          .isMe
                                                                      ? CupertinoColors
                                                                            .white
                                                                      : incomingTextColor,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                          Text(
                                                            message.text,
                                                            style: TextStyle(
                                                              fontSize: 16,
                                                              color: message.isMe
                                                                  ? CupertinoColors
                                                                        .white
                                                                  : incomingTextColor,
                                                            ),
                                                          ),
                                                        ],
                                                      )
                                                    : message.audioBytes != null
                                                    ? CupertinoButton(
                                                        padding: EdgeInsets.zero,
                                                        minimumSize: Size.zero,
                                                        onPressed: () =>
                                                            _playVoiceMessage(
                                                              message,
                                                            ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              _playingMessageId ==
                                                                      '${message.sentAt.millisecondsSinceEpoch}_${message.isMe}'
                                                                  ? CupertinoIcons
                                                                        .stop_fill
                                                                  : CupertinoIcons
                                                                        .play_fill,
                                                              color: message.isMe
                                                                  ? CupertinoColors
                                                                        .white
                                                                  : incomingTextColor,
                                                              size: 22,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Text(
                                                              _formatVoiceDuration(
                                                                message
                                                                    .audioDurationMs,
                                                              ),
                                                              style: TextStyle(
                                                                fontSize: 14,
                                                                color: message.isMe
                                                                    ? CupertinoColors
                                                                          .white
                                                                    : incomingTextColor,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      )
                                                    : Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (replyPreview
                                                              .isNotEmpty) ...[
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal: 8,
                                                                    vertical: 5,
                                                                  ),
                                                              margin:
                                                                  const EdgeInsets.only(
                                                                    bottom: 6,
                                                                  ),
                                                              decoration: BoxDecoration(
                                                                color: (message
                                                                            .isMe
                                                                        ? CupertinoColors
                                                                            .white
                                                                        : CupertinoColors
                                                                            .black)
                                                                    .withValues(
                                                                  alpha: 0.12,
                                                                ),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                  8,
                                                                ),
                                                              ),
                                                              child: Text(
                                                                replyPreview,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  color: message
                                                                          .isMe
                                                                      ? CupertinoColors
                                                                            .white
                                                                      : incomingTextColor,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                          ClipRRect(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  14,
                                                                ),
                                                            child: Image.memory(
                                                              message.photoBytes!,
                                                              width: 220,
                                                              height: 220,
                                                              fit: BoxFit.cover,
                                                            ),
                                                          ),
                                                          if ((message.caption ??
                                                                  '')
                                                              .trim()
                                                              .isNotEmpty) ...[
                                                            const SizedBox(
                                                              height: 6,
                                                            ),
                                                            Text(
                                                              message.caption!
                                                                  .trim(),
                                                              style: TextStyle(
                                                                fontSize: 14,
                                                                color: message.isMe
                                                                    ? CupertinoColors
                                                                          .white
                                                                    : incomingTextColor,
                                                              ),
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                              ),
                                            ),
                                            if ((message.reaction ?? '')
                                                .trim()
                                                .isNotEmpty)
                                              Positioned(
                                                top: -4,
                                                left: message.isMe ? -14 : null,
                                                right: message.isMe ? null : -14,
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 3,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: reactionBgColor,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                    border: Border.all(
                                                      color: reactionBorderColor,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    message.reaction!.trim(),
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (message.isMe && !message.isDelivered)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                            bottom: 6,
                                          ),
                                          child: const Text(
                                            'Enviando...',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF8E8E93),
                                            ),
                                          ),
                                        ),
                                      if (message.isMe &&
                                          message.isDelivered &&
                                          isLastOutgoing)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                            bottom: 6,
                                          ),
                                          child: Text(
                                            message.isSeen ? 'Visto' : 'Entregado',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF8E8E93),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) {
                  final keyboardVisible =
                      MediaQuery.of(context).viewInsets.bottom > 0;
                  if (!keyboardVisible) return;
                  if (details.delta.dy > 7) {
                    FocusScope.of(context).unfocus();
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_recordingVoice)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: composerPanelColor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Color(0xFFFF3B30),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatVoiceDuration(_recordingElapsedMs),
                              style: TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                                fontWeight: FontWeight.w600,
                                color: composerTextColor,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _RecordingSpectrum(
                                values: _recordingSpectrum,
                                color: const Color(0xFF0A84FF),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Grabando...',
                              style: TextStyle(
                                color: composerTextColor,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_pendingPhoto != null || _pendingVoiceBytes != null)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: composerPanelColor,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            if (_pendingPhoto != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.file(
                                  File(_pendingPhoto!.path),
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            if (_pendingVoiceBytes != null)
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                onPressed: _togglePendingVoicePreview,
                                child: Icon(
                                  _playingMessageId == 'draft_voice_preview'
                                      ? CupertinoIcons.stop_circle_fill
                                      : CupertinoIcons.play_circle_fill,
                                  size: 38,
                                  color: CupertinoColors.systemBlue,
                                ),
                              ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _pendingPhoto != null
                                    ? 'Foto adjunta'
                                    : 'Nota de voz: ${_formatVoiceDuration(_pendingVoiceDurationMs)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed: _sending
                                  ? null
                                  : () {
                                      setState(() {
                                        if (_playingMessageId ==
                                            'draft_voice_preview') {
                                          _audioPlayer.stop();
                                          _playingMessageId = null;
                                        }
                                        _pendingPhoto = null;
                                        _pendingVoiceBytes = null;
                                        _pendingVoiceDurationMs = null;
                                      });
                                    },
                              child: const Icon(
                                CupertinoIcons.xmark_circle_fill,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if ((_replyToPreview ?? '').trim().isNotEmpty)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: composerPanelColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              CupertinoIcons.reply,
                              size: 16,
                              color: CupertinoColors.systemBlue,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _replyToPreview!.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: composerTextColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              onPressed: () {
                                setState(() {
                                  _replyToMessageId = null;
                                  _replyToPreview = null;
                                });
                              },
                              child: const Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      height: _showAttachMenu ? 72 : 0,
                      padding: EdgeInsets.fromLTRB(
                        12,
                        _showAttachMenu ? 8 : 0,
                        12,
                        0,
                      ),
                      child: ClipRect(
                        child: Row(
                          children: [
                            _AttachTile(
                              icon: CupertinoIcons.photo_on_rectangle,
                              title: 'Fotos',
                              color: const Color(0xFF34C759),
                              onTap: _onTapPhoto,
                            ),
                            const SizedBox(width: 10),
                            _AttachTile(
                              icon: _recordingVoice
                                  ? CupertinoIcons.stop_circle_fill
                                  : CupertinoIcons.mic_fill,
                              title: _recordingVoice ? 'Detener' : 'Voz',
                              color: _recordingVoice
                                  ? const Color(0xFFFF3B30)
                                  : const Color(0xFF0A84FF),
                              onTap: _toggleVoiceRecording,
                            ),
                            const SizedBox(width: 10),
                            _AttachTile(
                              icon: CupertinoIcons.trash_fill,
                              title: 'Vaciar chat',
                              color: const Color(0xFFFF3B30),
                              onTap: _clearChatHistory,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                      child: Row(
                        children: [
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () async {
                              await _pulsePlusButton();
                              setState(() {
                                _showAttachMenu = !_showAttachMenu;
                              });
                            },
                            child: AnimatedScale(
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOutBack,
                              scale: _plusButtonPressed ? 0.86 : 1,
                              child: AnimatedRotation(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                turns: _showAttachMenu ? 0.125 : 0,
                                child: Icon(
                                  _showAttachMenu
                                      ? CupertinoIcons.xmark_circle_fill
                                      : CupertinoIcons.add_circled_solid,
                                  size: 30,
                                  color: CupertinoColors.systemBlue,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                color: composerFieldColor,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: CupertinoTextField(
                                controller: _controller,
                                focusNode: _focusNode,
                                onChanged: _onComposerChanged,
                                minLines: 1,
                                maxLines: 4,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _send(),
                                placeholder: 'iMessage',
                                style: TextStyle(color: composerTextColor),
                                placeholderStyle: TextStyle(
                                  color: composerPlaceholderColor,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                decoration: null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: _onPrimaryActionPressed,
                            child: AnimatedScale(
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOutBack,
                              scale: _stopButtonPressed ? 0.84 : 1,
                              child: _sending
                                  ? const CupertinoActivityIndicator(radius: 12)
                                  : Icon(
                                      _recordingVoice
                                          ? CupertinoIcons.stop_circle_fill
                                          : CupertinoIcons.arrow_up_circle_fill,
                                      color: _recordingVoice
                                          ? CupertinoColors.systemRed
                                          : CupertinoColors.systemBlue,
                                      size: _recordingVoice ? 36 : 34,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WalkieTalkieScreen extends StatefulWidget {
  const WalkieTalkieScreen({
    super.key,
    required this.service,
    required this.deviceId,
    required this.peerName,
    required this.sendStartSignalOnOpen,
    this.inviteId,
    this.isJoiner = false,
  });

  final BluetoothNearbyService service;
  final String deviceId;
  final String peerName;
  final bool sendStartSignalOnOpen;
  final String? inviteId;
  final bool isJoiner;

  @override
  State<WalkieTalkieScreen> createState() => _WalkieTalkieScreenState();
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final phase = (t - (index * 0.18)) % 1.0;
              final opacity = 0.35 + (phase < 0.5 ? phase : (1 - phase)) * 1.2;
              return Container(
                width: 6,
                height: 6,
                margin: EdgeInsets.only(right: index == 2 ? 0 : 4),
                decoration: BoxDecoration(
                  color: const Color(
                    0xFF8E8E93,
                  ).withValues(alpha: opacity.clamp(0.25, 1.0)),
                  shape: BoxShape.circle,
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class BluetoothVoiceCallScreen extends StatefulWidget {
  const BluetoothVoiceCallScreen({
    super.key,
    required this.service,
    required this.deviceId,
    required this.peerName,
    required this.isInitiator,
  });

  final BluetoothNearbyService service;
  final String deviceId;
  final String peerName;
  final bool isInitiator;

  @override
  State<BluetoothVoiceCallScreen> createState() =>
      _BluetoothVoiceCallScreenState();
}

class _BluetoothVoiceCallScreenState extends State<BluetoothVoiceCallScreen> {
  static const int _callChunkMs = 420;
  static const int _minBufferedChunksToStart = 1;
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  StreamSubscription<BluetoothIncomingMessage>? _incomingSub;
  final List<Uint8List> _incomingQueue = [];
  final List<String> _recentIncomingSignatures = [];
  bool _playingIncoming = false;
  bool _micEnabled = true;
  bool _speakerEnabled = true;
  bool _callActive = true;
  bool _peerAccepted = false;
  bool _captureLoopRunning = false;
  DateTime _callStartedAt = DateTime.now();
  Timer? _ticker;
  Timer? _handshakeTimer;
  int _elapsedMs = 0;
  int _txSeq = 0;
  final String _callId = DateTime.now().millisecondsSinceEpoch.toString();
  bool _endSignalHandled = false;

  @override
  void initState() {
    super.initState();
    _peerAccepted = !widget.isInitiator;
    _callStartedAt = DateTime.now();
    _incomingSub = widget.service.messagesStream.listen((event) {
      final raw = _extractBtEnvelopeVisibleText(event.message);
      if (!raw.startsWith('btvoicecall::')) return;
      try {
        final payload = raw.replaceFirst('btvoicecall::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString() ?? '';
        if (type == 'invite' && !widget.isInitiator) {
          _sendAcceptBurst();
          return;
        }
        if (type == 'accept') {
          if (!mounted) return;
          setState(() {
            _peerAccepted = true;
          });
          _handshakeTimer?.cancel();
          _handshakeTimer = null;
          _startCaptureLoop();
          return;
        }
        if (type == 'audio') {
          if (!_callActive) return;
          if (!_peerAccepted && mounted) {
            setState(() {
              _peerAccepted = true;
            });
          }
          _handshakeTimer?.cancel();
          _handshakeTimer = null;
          final bytesRaw = map['bytes']?.toString() ?? '';
          final durationRaw = map['durationMs']?.toString() ?? '0';
          if (bytesRaw.isEmpty) return;
          final signature =
              '${bytesRaw.length}:${bytesRaw.hashCode}:$durationRaw';
          if (_recentIncomingSignatures.contains(signature)) return;
          _recentIncomingSignatures.add(signature);
          if (_recentIncomingSignatures.length > 120) {
            _recentIncomingSignatures.removeAt(0);
          }
          _incomingQueue.add(base64Decode(bytesRaw));
          _playQueue();
          return;
        }
        if (type == 'end') {
          if (!mounted) return;
          setState(() {
            _callActive = false;
          });
          _endSignalHandled = true;
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
          return;
        }
      } catch (_) {}
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedMs = DateTime.now().difference(_callStartedAt).inMilliseconds;
      });
    });
    if (widget.isInitiator) {
      _startInviteHandshake();
    } else {
      _sendAcceptBurst();
      _startCaptureLoop();
    }
  }

  void _startInviteHandshake() {
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!_callActive || _peerAccepted) {
        _handshakeTimer?.cancel();
        _handshakeTimer = null;
        return;
      }
      widget.service.sendText(
        widget.deviceId,
        'btvoicecall::${jsonEncode({'type': 'invite', 'callId': _callId})}',
      );
    });
  }

  void _sendAcceptBurst() {
    for (var i = 0; i < 3; i++) {
      Future<void>.delayed(Duration(milliseconds: i * 220), () {
        if (!_callActive) return;
        widget.service.sendText(
          widget.deviceId,
          'btvoicecall::${jsonEncode({'type': 'accept', 'callId': _callId})}',
        );
      });
    }
  }

  Future<void> _startCaptureLoop() async {
    if (_captureLoopRunning) return;
    _captureLoopRunning = true;
    try {
      while (mounted && _callActive) {
        if (!_peerAccepted) {
          await Future<void>.delayed(const Duration(milliseconds: 220));
          continue;
        }
        if (!_micEnabled) {
          await Future<void>.delayed(const Duration(milliseconds: 220));
          continue;
        }
        final hasPermission = await _recorder.hasPermission();
        if (!hasPermission) {
          if (mounted && Platform.isMacOS) {
            debugPrint('Sin permiso de microfono en macOS para llamada BT');
          }
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        final dir = await _runtimeTempDir();
        final path =
            '${dir.path}/voice_call_chunk_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await File(path).parent.create(recursive: true);
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 48000,
            sampleRate: 16000,
          ),
          path: path,
        );
        await Future<void>.delayed(const Duration(milliseconds: _callChunkMs));
        final out = await _recorder.stop();
        if (out == null || out.isEmpty) continue;
        final file = File(out);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        final payload = jsonEncode({
          'type': 'audio',
          'callId': _callId,
          'seq': _txSeq++,
          'durationMs': _callChunkMs,
          'bytes': base64Encode(bytes),
        });
        await widget.service.sendText(widget.deviceId, 'btvoicecall::$payload');
      }
    } catch (_) {
    } finally {
      _captureLoopRunning = false;
    }
  }

  Future<void> _playQueue() async {
    if (_playingIncoming || _incomingQueue.isEmpty || !_speakerEnabled) return;
    if (_incomingQueue.length < _minBufferedChunksToStart) return;
    _playingIncoming = true;
    try {
      while (_incomingQueue.isNotEmpty && _speakerEnabled) {
        final bytes = _incomingQueue.removeAt(0);
        final dir = await _runtimeTempDir();
        final path =
            '${dir.path}/voice_call_in_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await File(path).parent.create(recursive: true);
        await File(path).writeAsBytes(bytes, flush: true);
        await _player.play(DeviceFileSource(path));
        await _player.onPlayerComplete.first;
      }
    } catch (_) {
    } finally {
      _playingIncoming = false;
      if (_speakerEnabled && _incomingQueue.isNotEmpty) {
        _playQueue();
      }
    }
  }

  String _fmt(int ms) {
    final sec = (ms / 1000).round();
    return '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _hangUp() async {
    if (!_callActive) return;
    setState(() {
      _callActive = false;
    });
    await widget.service.sendText(
      widget.deviceId,
      'btvoicecall::${jsonEncode({'type': 'end', 'callId': _callId})}',
    );
    _endSignalHandled = true;
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _callActive = false;
    if (!_endSignalHandled) {
      widget.service.sendText(
        widget.deviceId,
        'btvoicecall::${jsonEncode({'type': 'end', 'callId': _callId})}',
      );
    }
    _ticker?.cancel();
    _handshakeTimer?.cancel();
    _incomingSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? CupertinoColors.white
        : const Color(0xFF1C1C1E);
    final secondaryTextColor = isDark
        ? const Color(0xFFAEAEB2)
        : const Color(0xFF636366);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text('Llamada Bluetooth · ${widget.peerName}'),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 26),
            Text(
              _callActive
                  ? (_peerAccepted
                        ? 'Conectado por Bluetooth'
                        : 'Esperando que respondan...')
                  : 'Llamada finalizada',
              style: TextStyle(fontSize: 16, color: primaryTextColor),
            ),
            const SizedBox(height: 6),
            Text(
              _fmt(_elapsedMs),
              style: TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                color: secondaryTextColor,
              ),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CupertinoButton(
                  onPressed: () {
                    setState(() {
                      _micEnabled = !_micEnabled;
                    });
                  },
                  child: Icon(
                    _micEnabled
                        ? CupertinoIcons.mic_fill
                        : CupertinoIcons.mic_slash_fill,
                    size: 30,
                    color: _micEnabled
                        ? CupertinoColors.systemBlue
                        : CupertinoColors.systemGrey,
                  ),
                ),
                const SizedBox(width: 24),
                CupertinoButton(
                  onPressed: _hangUp,
                  child: const Icon(
                    CupertinoIcons.phone_down_fill,
                    size: 34,
                    color: CupertinoColors.systemRed,
                  ),
                ),
                const SizedBox(width: 24),
                CupertinoButton(
                  onPressed: () {
                    setState(() {
                      _speakerEnabled = !_speakerEnabled;
                      if (_speakerEnabled) _playQueue();
                    });
                  },
                  child: Icon(
                    _speakerEnabled
                        ? CupertinoIcons.speaker_3_fill
                        : CupertinoIcons.speaker_slash_fill,
                    size: 30,
                    color: _speakerEnabled
                        ? CupertinoColors.systemBlue
                        : CupertinoColors.systemGrey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 34),
          ],
        ),
      ),
    );
  }
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen> {
  static const bool _debugWalkieOverlay = true;
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  StreamSubscription<BluetoothIncomingMessage>? _incomingSub;
  StreamSubscription<List<Device>>? _devicesSub;
  List<Device> _liveNearbyDevices = const [];
  final List<Uint8List> _incomingQueue = [];
  final List<String> _recentIncomingSignatures = [];
  bool _playingIncoming = false;
  bool _pttRecording = false;
  DateTime? _pttStartedAt;
  int _elapsedMs = 0;
  Timer? _ticker;
  StreamSubscription<Amplitude>? _amplitudeSub;
  List<double> _spectrum = List<double>.filled(20, 0.08);
  String _activeInviteId = '';
  String _lockedPeerDeviceId = '';
  bool _peerReadyForPtt = false;
  String _debugLastEvent = '-';
  String _debugLastEventDeviceId = '-';
  Timer? _joinerAcceptRetryTimer;
  Timer? _initiatorStartRetryTimer;
  Timer? _peerDiscoveryRefreshTimer;
  int _joinerAcceptRetries = 0;
  int _initiatorStartRetries = 0;

  @override
  void initState() {
    super.initState();
    _activeInviteId = widget.inviteId?.trim() ?? '';
    _peerReadyForPtt = widget.isJoiner;
    _liveNearbyDevices = widget.service.currentDevices;
    _devicesSub = widget.service.devicesStream.listen((devices) {
      _liveNearbyDevices = devices;
    });
    _peerDiscoveryRefreshTimer = Timer.periodic(
      const Duration(milliseconds: 900),
      (_) async {
        if (!mounted) return;
        if (_peerReadyForPtt) return;
        try {
          await widget.service.refreshPresence();
        } catch (_) {}
      },
    );
    _incomingSub = widget.service.messagesStream.listen((event) {
      final eventDeviceId = event.deviceId.trim();
      if (eventDeviceId.isNotEmpty) {
        _lockedPeerDeviceId = eventDeviceId;
        _debugLastEventDeviceId = eventDeviceId;
      }
      final raw = _extractBtEnvelopeVisibleText(event.message);
      if (raw.startsWith('btcall::')) {
        try {
          final payload = raw.replaceFirst('btcall::', '');
          final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
          final type = map['type']?.toString() ?? '';
          _debugLastEvent = 'btcall:$type';
          final incomingInviteId = map['inviteId']?.toString().trim() ?? '';
          if (type == 'start' && _activeInviteId.isEmpty && incomingInviteId.isNotEmpty) {
            _activeInviteId = incomingInviteId;
          }
          if (type == 'accept' &&
              _activeInviteId.isNotEmpty &&
              incomingInviteId.isNotEmpty &&
              incomingInviteId != _activeInviteId) {
            return;
          }
          if (type == 'accept' && mounted) {
            setState(() {
              _peerReadyForPtt = true;
            });
            _joinerAcceptRetryTimer?.cancel();
            _joinerAcceptRetryTimer = null;
            _initiatorStartRetryTimer?.cancel();
            _initiatorStartRetryTimer = null;
          }
        } catch (_) {}
        return;
      }
      if (!raw.startsWith('btcallvoice::')) return;
      try {
        final payload = raw.replaceFirst('btcallvoice::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        _debugLastEvent = 'btcallvoice';
        final incomingInviteId = map['inviteId']?.toString().trim() ?? '';
        if (_activeInviteId.isNotEmpty &&
            incomingInviteId.isNotEmpty &&
            incomingInviteId != _activeInviteId) {
          return;
        }
        if (!_peerReadyForPtt && mounted) {
          setState(() {
            _peerReadyForPtt = true;
          });
          _joinerAcceptRetryTimer?.cancel();
          _joinerAcceptRetryTimer = null;
          _initiatorStartRetryTimer?.cancel();
          _initiatorStartRetryTimer = null;
        }
        final bytesRaw = map['bytes']?.toString() ?? '';
        final durationRaw = map['durationMs']?.toString() ?? '0';
        if (bytesRaw.isEmpty) return;
        final signature =
            '${bytesRaw.length}:${bytesRaw.hashCode}:$durationRaw';
        if (_recentIncomingSignatures.contains(signature)) return;
        _recentIncomingSignatures.add(signature);
        if (_recentIncomingSignatures.length > 80) {
          _recentIncomingSignatures.removeAt(0);
        }
        _incomingQueue.add(base64Decode(bytesRaw));
        _playQueue();
      } catch (_) {}
    });
    if (widget.sendStartSignalOnOpen) {
      final inviteId = _activeInviteId.isEmpty
          ? DateTime.now().microsecondsSinceEpoch.toString()
          : _activeInviteId;
      _activeInviteId = inviteId;
      _sendStartBurst();
      _startInitiatorRetryHandshake();
    }
    if (widget.isJoiner && _activeInviteId.isNotEmpty) {
      _sendAcceptBurst();
      _startJoinerRetryHandshake();
    }
  }

  void _sendStartBurst() {
    if (_activeInviteId.isEmpty) return;
    final payload =
        'btcall::${jsonEncode({'type': 'start', 'inviteId': _activeInviteId})}';
    for (var i = 0; i < 3; i++) {
      Future<void>.delayed(Duration(milliseconds: i * 220), () {
        _sendTextToPeerCandidates(payload);
      });
    }
  }

  void _sendAcceptBurst() {
    if (_activeInviteId.isEmpty) return;
    final payload =
        'btcall::${jsonEncode({'type': 'accept', 'inviteId': _activeInviteId})}';
    for (var i = 0; i < 3; i++) {
      Future<void>.delayed(Duration(milliseconds: i * 220), () {
        _sendTextToPeerCandidates(payload);
      });
    }
  }

  void _sendTextToPeerCandidates(String payload) {
    final targets = _candidateTargetDeviceIds();
    for (final target in targets) {
      widget.service.sendText(target, payload);
    }
  }

  List<String> _candidateTargetDeviceIds() {
    final fallback = widget.deviceId.trim();
    final out = <String>{};
    final fallbackLooksPhone = RegExp(r'^\+?[0-9]{6,}$').hasMatch(fallback);
    if (_lockedPeerDeviceId.trim().isNotEmpty) {
      out.add(_lockedPeerDeviceId.trim());
    }
    if (fallback.isNotEmpty && !fallbackLooksPhone) out.add(fallback);
    final target = _normalizePeerName(widget.peerName);
    for (final d in _liveNearbyDevices) {
      final id = d.deviceId.trim();
      if (id.isEmpty) continue;
      if (target.isNotEmpty && _normalizePeerName(d.deviceName) == target) {
        out.add(id);
      }
      if (_normalizePeerName(id) == target) {
        out.add(id);
      }
    }
    if (out.isEmpty && fallback.isNotEmpty) {
      out.add(fallback);
    }
    return out.toList();
  }

  String _debugPeerSummary() {
    final live = _liveNearbyDevices
        .map((d) => '${d.deviceName.trim().isEmpty ? d.deviceId.trim() : d.deviceName.trim()}(${d.deviceId.trim()})')
        .join(' | ');
    final candidates = _candidateTargetDeviceIds().join(', ');
    return 'inviteId=$_activeInviteId\n'
        'ready=$_peerReadyForPtt joiner=${widget.isJoiner}\n'
        'locked=$_lockedPeerDeviceId\n'
        'fallback=${widget.deviceId.trim()}\n'
        'candidates=$candidates\n'
        'lastEvent=$_debugLastEvent from=$_debugLastEventDeviceId\n'
        'livePeers=${live.isEmpty ? "-" : live}';
  }

  void _startJoinerRetryHandshake() {
    _joinerAcceptRetryTimer?.cancel();
    _joinerAcceptRetries = 0;
    _joinerAcceptRetryTimer = Timer.periodic(const Duration(milliseconds: 900), (
      timer,
    ) {
      if (!mounted || _peerReadyForPtt) {
        timer.cancel();
        _joinerAcceptRetryTimer = null;
        return;
      }
      if (_joinerAcceptRetries >= 14) {
        timer.cancel();
        _joinerAcceptRetryTimer = null;
        return;
      }
      _joinerAcceptRetries++;
      _sendAcceptBurst();
    });
  }

  void _startInitiatorRetryHandshake() {
    _initiatorStartRetryTimer?.cancel();
    _initiatorStartRetries = 0;
    _initiatorStartRetryTimer = Timer.periodic(const Duration(milliseconds: 900), (
      timer,
    ) {
      if (!mounted || _peerReadyForPtt) {
        timer.cancel();
        _initiatorStartRetryTimer = null;
        return;
      }
      if (_initiatorStartRetries >= 14) {
        timer.cancel();
        _initiatorStartRetryTimer = null;
        return;
      }
      _initiatorStartRetries++;
      _sendStartBurst();
    });
  }

  String _normalizePeerName(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9+]'), '');
  }

  Future<void> _startPtt() async {
    if (_pttRecording) return;
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) return;
    final dir = await _runtimeTempDir();
    final path =
        '${dir.path}/walkie_ptt_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 48000,
        sampleRate: 16000,
      ),
      path: path,
    );
    await _amplitudeSub?.cancel();
    _amplitudeSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 90))
        .listen((amp) {
          if (!mounted) return;
          final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
          setState(() {
            _spectrum = [..._spectrum.sublist(1), 0.08 + (normalized * 0.92)];
          });
        });
    if (!mounted) return;
    setState(() {
      _pttRecording = true;
      _pttStartedAt = DateTime.now();
      _elapsedMs = 0;
      _spectrum = List<double>.filled(20, 0.08);
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final started = _pttStartedAt;
      if (!mounted || started == null) return;
      setState(() {
        _elapsedMs = DateTime.now().difference(started).inMilliseconds;
      });
    });
  }

  Future<void> _stopPtt() async {
    if (!_pttRecording) return;
    final path = await _audioRecorder.stop();
    if (!mounted) return;
    final durationMs = _pttStartedAt == null
        ? 0
        : DateTime.now().difference(_pttStartedAt!).inMilliseconds;
    _pttStartedAt = null;
    _ticker?.cancel();
    _ticker = null;
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    setState(() {
      _pttRecording = false;
      _elapsedMs = 0;
      _spectrum = List<double>.filled(20, 0.08);
    });
    if (path == null || path.isEmpty || durationMs < 180) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    final payload = jsonEncode({
      'bytes': base64Encode(bytes),
      'durationMs': durationMs,
      'inviteId': _activeInviteId,
    });
    _sendTextToPeerCandidates('btcallvoice::$payload');
  }

  Future<void> _playQueue() async {
    if (_playingIncoming || _incomingQueue.isEmpty) return;
    _playingIncoming = true;
    try {
      while (_incomingQueue.isNotEmpty) {
        final bytes = _incomingQueue.removeAt(0);
        final dir = await _runtimeTempDir();
        final path =
            '${dir.path}/walkie_in_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await File(path).parent.create(recursive: true);
        await File(path).writeAsBytes(bytes, flush: true);
        await _audioPlayer.play(DeviceFileSource(path));
        await _audioPlayer.onPlayerComplete.first;
      }
    } catch (_) {
    } finally {
      _playingIncoming = false;
    }
  }

  String _fmt(int ms) {
    final sec = (ms / 1000).round();
    return '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _sendTextToPeerCandidates(
      'btcall::${jsonEncode({'type': 'end', 'inviteId': _activeInviteId})}',
    );
    _incomingSub?.cancel();
    _devicesSub?.cancel();
    _joinerAcceptRetryTimer?.cancel();
    _initiatorStartRetryTimer?.cancel();
    _peerDiscoveryRefreshTimer?.cancel();
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? CupertinoColors.white
        : const Color(0xFF1C1C1E);
    final secondaryTextColor = isDark
        ? const Color(0xFFAEAEB2)
        : const Color(0xFF636366);
    final debugTextColor = isDark
        ? const Color(0xFFE5E5EA)
        : const Color(0xFF1C1C1E);
    final debugBg = isDark ? const Color(0x22FF9500) : const Color(0x11FF9500);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        previousPageTitle: 'Chat',
        middle: Text('Walkie-talkie · ${widget.peerName}'),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 26),
            Text(
              _pttRecording
                  ? 'Hablando...'
                  : (_peerReadyForPtt
                        ? 'Mantén presionado para hablar'
                        : 'Esperando a que ${widget.peerName} entre al Walkie Talkie...'),
              style: TextStyle(fontSize: 15, color: secondaryTextColor),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _RecordingSpectrum(
                values: _spectrum,
                color: const Color(0xFF0A84FF),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _fmt(_elapsedMs),
              style: TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
                color: primaryTextColor,
              ),
            ),
            const Spacer(),
            if (_peerReadyForPtt)
              GestureDetector(
                onLongPressStart: (_) => _startPtt(),
                onLongPressEnd: (_) => _stopPtt(),
                onLongPressCancel: _stopPtt,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: _pttRecording ? 132 : 116,
                  height: _pttRecording ? 132 : 116,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _pttRecording
                        ? const Color(0xFFFF3B30)
                        : const Color(0xFF0A84FF),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (_pttRecording
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF0A84FF))
                                .withValues(alpha: 0.30),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    CupertinoIcons.mic_fill,
                    size: 52,
                    color: CupertinoColors.white,
                  ),
                ),
              )
            else
              const CupertinoActivityIndicator(radius: 16),
            const SizedBox(height: 36),
            if (_debugWalkieOverlay)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: debugBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x44FF9500)),
                ),
                child: Text(
                  _debugPeerSummary(),
                  style: TextStyle(
                    fontSize: 11,
                    color: debugTextColor,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BluetoothChatMessage {
  const _BluetoothChatMessage({
    required this.messageId,
    required this.text,
    required this.isMe,
    required this.isDelivered,
    required this.isSeen,
    required this.sentAt,
    required this.photoBytes,
    required this.audioBytes,
    required this.audioDurationMs,
    required this.caption,
    this.reaction,
    this.replyToMessageId,
    this.replyToPreview,
  });

  final String messageId;
  final String text;
  final bool isMe;
  final bool isDelivered;
  final bool isSeen;
  final DateTime sentAt;
  final Uint8List? photoBytes;
  final Uint8List? audioBytes;
  final int? audioDurationMs;
  final String? caption;
  final String? reaction;
  final String? replyToMessageId;
  final String? replyToPreview;

  _BluetoothChatMessage copyWith({
    String? messageId,
    String? text,
    bool? isMe,
    bool? isDelivered,
    bool? isSeen,
    DateTime? sentAt,
    Uint8List? photoBytes,
    Uint8List? audioBytes,
    int? audioDurationMs,
    String? caption,
    String? reaction,
    String? replyToMessageId,
    String? replyToPreview,
    bool clearReaction = false,
  }) {
    return _BluetoothChatMessage(
      messageId: messageId ?? this.messageId,
      text: text ?? this.text,
      isMe: isMe ?? this.isMe,
      isDelivered: isDelivered ?? this.isDelivered,
      isSeen: isSeen ?? this.isSeen,
      sentAt: sentAt ?? this.sentAt,
      photoBytes: photoBytes ?? this.photoBytes,
      audioBytes: audioBytes ?? this.audioBytes,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      caption: caption ?? this.caption,
      reaction: clearReaction ? null : (reaction ?? this.reaction),
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToPreview: replyToPreview ?? this.replyToPreview,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'text': text,
      'isMe': isMe,
      'isDelivered': isDelivered,
      'isSeen': isSeen,
      'sentAt': sentAt.toIso8601String(),
      'photoBytes': photoBytes == null ? null : base64Encode(photoBytes!),
      'audioBytes': audioBytes == null ? null : base64Encode(audioBytes!),
      'audioDurationMs': audioDurationMs,
      'caption': caption,
      'reaction': reaction,
      'replyToMessageId': replyToMessageId,
      'replyToPreview': replyToPreview,
    };
  }

  static _BluetoothChatMessage? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final sentAtRaw = map['sentAt']?.toString();
    final sentAt = sentAtRaw == null
        ? DateTime.now()
        : DateTime.tryParse(sentAtRaw) ?? DateTime.now();
    final photoRaw = map['photoBytes']?.toString();
    final audioRaw = map['audioBytes']?.toString();
    Uint8List? decodedPhoto;
    Uint8List? decodedAudio;
    if (photoRaw != null && photoRaw.isNotEmpty) {
      try {
        decodedPhoto = base64Decode(photoRaw);
      } catch (_) {
        decodedPhoto = null;
      }
    }
    if (audioRaw != null && audioRaw.isNotEmpty) {
      try {
        decodedAudio = base64Decode(audioRaw);
      } catch (_) {
        decodedAudio = null;
      }
    }
    return _BluetoothChatMessage(
      messageId: map['messageId']?.toString().trim().isNotEmpty == true
          ? map['messageId'].toString()
          : 'legacy_${sentAt.millisecondsSinceEpoch}',
      text: map['text']?.toString() ?? '',
      isMe: map['isMe'] == true,
      isDelivered: map['isDelivered'] == true || map['isMe'] != true,
      isSeen: map['isSeen'] == true || map['isMe'] != true,
      sentAt: sentAt,
      photoBytes: decodedPhoto,
      audioBytes: decodedAudio,
      audioDurationMs: map['audioDurationMs'] is int
          ? map['audioDurationMs'] as int
          : int.tryParse(map['audioDurationMs']?.toString() ?? ''),
      caption: map['caption']?.toString(),
      reaction: map['reaction']?.toString().trim().isEmpty == true
          ? null
          : map['reaction']?.toString(),
      replyToMessageId: map['replyToMessageId']?.toString(),
      replyToPreview: map['replyToPreview']?.toString(),
    );
  }
}

class ConversationSummary {
  ConversationSummary({
    required this.id,
    required this.peerPhone,
    required this.peerDisplayName,
    required this.peerAvatarUrl,
    required this.lastMessage,
    required this.lastMessageAt,
    required this.hasUnread,
  });

  final String id;
  final String peerPhone;
  final String peerDisplayName;
  final String? peerAvatarUrl;
  final String lastMessage;
  final DateTime? lastMessageAt;
  final bool hasUnread;
}

class NearbyChatMeta {
  NearbyChatMeta({
    required this.lastMessage,
    required this.lastMessageAt,
    required this.hasUnread,
    required this.peerPresence,
    required this.peerPresenceAt,
    required this.peerAvatarBase64,
    required this.peerAvatarHash,
  });

  final String lastMessage;
  final DateTime? lastMessageAt;
  final bool hasUnread;
  final String peerPresence;
  final DateTime? peerPresenceAt;
  final String? peerAvatarBase64;
  final String? peerAvatarHash;

  Map<String, dynamic> toJson() => {
    'lastMessage': lastMessage,
    'lastMessageAt': lastMessageAt?.toIso8601String(),
    'hasUnread': hasUnread,
    'peerPresence': peerPresence,
    'peerPresenceAt': peerPresenceAt?.toIso8601String(),
    'peerAvatarBase64': peerAvatarBase64,
    'peerAvatarHash': peerAvatarHash,
  };

  static NearbyChatMeta? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    return NearbyChatMeta(
      lastMessage: map['lastMessage']?.toString() ?? '',
      lastMessageAt: map['lastMessageAt'] == null
          ? null
          : DateTime.tryParse(map['lastMessageAt'].toString())?.toLocal(),
      hasUnread: map['hasUnread'] == true,
      peerPresence: map['peerPresence']?.toString() ?? 'online',
      peerPresenceAt: map['peerPresenceAt'] == null
          ? null
          : DateTime.tryParse(map['peerPresenceAt'].toString())?.toLocal(),
      peerAvatarBase64: map['peerAvatarBase64']?.toString(),
      peerAvatarHash: map['peerAvatarHash']?.toString(),
    );
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver({required this.onChanged});

  final Future<void> Function(AppLifecycleState state) onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChanged(state);
  }
}

class _IOSField extends StatelessWidget {
  const _IOSField({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD1D1D6)),
      ),
      child: child,
    );
  }
}

String _formatTime(DateTime timestamp) {
  final hour = timestamp.hour.toString().padLeft(2, '0');
  final minute = timestamp.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

Future<Directory> _runtimeTempDir() async {
  try {
    if (!Platform.isMacOS) {
      final dir = await getTemporaryDirectory();
      await dir.create(recursive: true);
      return dir;
    }
  } catch (_) {}
  final fallback = Directory('${Directory.systemTemp.path}/vmessages');
  await fallback.create(recursive: true);
  return fallback;
}

String _extractBtEnvelopeVisibleText(String raw) {
  final clean = raw.trim();
  if (clean.isEmpty) return '';
  try {
    final decoded = jsonDecode(clean);
    if (decoded is Map) {
      final message = decoded['message']?.toString().trim() ?? '';
      if (message.isNotEmpty) return message;
    }
  } catch (_) {}
  return clean;
}
