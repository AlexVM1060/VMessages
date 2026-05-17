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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  await _initLocalNotifications();
  runApp(const VMessagesApp());
}

final lnp.FlutterLocalNotificationsPlugin _localNotifications =
    lnp.FlutterLocalNotificationsPlugin();

Future<void> _initLocalNotifications() async {
  const initSettings = lnp.InitializationSettings(
    iOS: lnp.DarwinInitializationSettings(),
    macOS: lnp.DarwinInitializationSettings(),
  );
  await _localNotifications.initialize(settings: initSettings);
}

class VMessagesApp extends StatelessWidget {
  const VMessagesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      title: 'VMessages',
      theme: CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: CupertinoColors.systemBlue,
        scaffoldBackgroundColor: CupertinoColors.systemGroupedBackground,
      ),
      home: RootSessionGate(),
    );
  }
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
        .select('access_code')
        .eq('id', user.id)
        .maybeSingle();

    if (profile?['access_code']?.toString() == code) return;

    await Supabase.instance.client.from('profiles').upsert({
      'id': user.id,
      'phone': phone,
      'display_name': phone,
      'access_code': code,
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
        .select('access_code')
        .eq('id', user.id)
        .maybeSingle();
    await Supabase.instance.client.from('profiles').upsert({
      'id': user.id,
      'phone': phone,
      'display_name': phone,
      'access_code': profile?['access_code'],
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
  bool _btBootstrapping = false;
  String? _btError;
  List<Device> _nearbyDevices = const [];
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
  bool _btNotifDedupeLoaded = false;
  bool get _isApplePeerSupported => Platform.isIOS || Platform.isMacOS;

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
              .select('id,phone,display_name')
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
    _startIosBluetoothKeepAlive();
    _loadNearbyChatMeta();
    _loadBtNotificationDedupeCache();
    _requestNotificationPermissions();
    _subscribeMessageNotifications();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _homeRefreshFallbackTimer?.cancel();
    _iosBluetoothKeepAliveTimer?.cancel();
    _btIncomingSub?.cancel();
    if (_messageNotificationsChannel != null) {
      _client.removeChannel(_messageNotificationsChannel!);
    }
    _stopIncomingCallTone();
    _incomingCallTonePlayer.dispose();
    if (_isApplePeerSupported) {
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
        setState(() {
          _nearbyDevices = devices;
        });
      });
      _btIncomingSub?.cancel();
      _btIncomingSub = _bluetoothService.messagesStream.listen((
        incoming,
      ) async {
        final body = _extractBtVisibleText(incoming.message);
        if (body.isEmpty) return;
        if (await _handleIncomingBtCallInvite(
          body: body,
          incomingDeviceId: incoming.deviceId,
        )) {
          return;
        }
        if (_isBluetoothControlPayload(body)) return;
        final resolvedId = _resolveNearbyDeviceId(incoming.deviceId);
        await _appendNearbyIncomingToHistory(deviceId: resolvedId, body: body);
        await _showBluetoothMessageNotificationIfNeeded(
          deviceId: resolvedId,
          body: body,
          rawIncoming: incoming.message,
        );
        final updated = NearbyChatMeta(
          lastMessage: body.startsWith('btphoto::') ? '📷 Foto' : body,
          lastMessageAt: DateTime.now(),
          hasUnread: true,
        );
        if (!mounted) return;
        setState(() {
          _nearbyMetaByDeviceId[resolvedId] = updated;
        });
        await _saveNearbyChatMeta();
      });
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

  String _buildBluetoothNotificationKey({
    required String deviceId,
    required String body,
    required String rawIncoming,
  }) {
    final cleanBody = body.trim();
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

  void _startIosBluetoothKeepAlive() {
    if (!Platform.isIOS) return;
    _iosBluetoothKeepAliveTimer?.cancel();
    _iosBluetoothKeepAliveTimer = Timer.periodic(const Duration(seconds: 45), (
      _,
    ) async {
      await _refreshAdvertising();
    });
  }

  Future<void> _refreshAdvertising({bool force = false}) async {
    if (!_isApplePeerSupported) return;
    final inactivitySeconds = DateTime.now()
        .difference(_bluetoothService.lastActivityAt)
        .inSeconds;
    final shouldSkip =
        !force &&
        (_bluetoothService.hasConnectedPeers || inactivitySeconds < 40);
    if (shouldSkip) return;
    try {
      final phone =
          _client.auth.currentUser?.userMetadata?['phone']?.toString() ??
          'iPhone';
      await _bluetoothService.stop();
      await _bluetoothService.start(displayName: phone);
    } catch (_) {}
  }

  late final WidgetsBindingObserver _lifecycleObserver = _LifecycleObserver(
    onChanged: (state) async {
      _appLifecycleState = state;
      if (!mounted) return;
      if (!_isApplePeerSupported) return;
      if (state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive) {
        await _refreshAdvertising(force: true);
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
      if (_incomingBtCallDialogOpen || !mounted) return true;
      _incomingBtCallDialogOpen = true;
      _startIncomingCallTone();
      if (!mounted) return true;
      final resolvedId = _resolveNearbyDeviceId(incomingDeviceId);
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
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/incoming_call_ringtone.wav';
    final file = File(path);
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
      );
    });
    await _saveNearbyChatMeta();
  }

  String _btHistoryKey(String deviceId) =>
      'bt_history_device_${deviceId.trim()}';

  Future<void> _appendNearbyIncomingToHistory({
    required String deviceId,
    required String body,
  }) async {
    if (_isBluetoothControlPayload(body)) return;
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
        if (map['action']?.toString() == 'delete') {
          final messageId = map['messageId']?.toString() ?? '';
          if (messageId.isNotEmpty) {
            list.removeWhere((item) {
              if (item is! Map) return false;
              final row = Map<String, dynamic>.from(item);
              return row['messageId']?.toString() == messageId;
            });
            await prefs.setString(key, jsonEncode(list));
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
          list.add({
            'messageId': messageId,
            'text': '',
            'isMe': false,
            'sentAt': sentAt,
            'photoBytes': photoBytes,
            'audioBytes': null,
            'audioDurationMs': null,
            'caption': caption,
          });
        } else if (type == 'voice') {
          final audioBytes = map['bytes']?.toString();
          final audioDurationMs = int.tryParse(
            map['durationMs']?.toString() ?? '',
          );
          list.add({
            'messageId': messageId,
            'text': '',
            'isMe': false,
            'sentAt': sentAt,
            'photoBytes': null,
            'audioBytes': audioBytes,
            'audioDurationMs': audioDurationMs,
            'caption': null,
          });
        } else {
          final text = map['text']?.toString() ?? '';
          if (text.trim().isEmpty) return;
          list.add({
            'messageId': messageId,
            'text': text.trim(),
            'isMe': false,
            'sentAt': sentAt,
            'photoBytes': null,
            'audioBytes': null,
            'audioDurationMs': null,
            'caption': null,
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
        middle: const Text('Mensajes'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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

            if (conversationIds.isEmpty && _nearbyDevices.isEmpty) {
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
        const Center(
          child: Text('Sin chats aun. Toca el icono para iniciar uno.'),
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
    return _nearbyDevices.map(_buildNearbyConversationTile).toList();
  }

  Widget _buildNearbyConversationTile(Device device) {
    final peerLabel = device.deviceName.isEmpty
        ? device.deviceId
        : device.deviceName;
    final meta = _nearbyMetaByDeviceId[device.deviceId.trim()];
    final subtitle = meta?.lastMessage.trim().isNotEmpty == true
        ? meta!.lastMessage
        : 'Dispositivo cercano';
    final time = meta?.lastMessageAt == null
        ? ''
        : _formatTime(meta!.lastMessageAt!);
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
            ),
          ),
        );
        await _loadNearbyChatMeta();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xFFD1D1D6),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                peerLabel.characters.first.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFF1C1C1E),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peerLabel,
                    style: const TextStyle(
                      fontSize: 16,
                      color: CupertinoColors.black,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CupertinoColors.systemGrey,
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
                  style: const TextStyle(
                    color: CupertinoColors.systemGrey2,
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
                    color: const Color(0x1A0A84FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        CupertinoIcons.dot_radiowaves_left_right,
                        size: 12,
                        color: CupertinoColors.systemBlue,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Cercano',
                        style: TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemBlue,
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
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xFFD1D1D6),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                summary.peerDisplayName.characters.first.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFF1C1C1E),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.peerDisplayName,
                    style: const TextStyle(
                      fontSize: 16,
                      color: CupertinoColors.black,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    summary.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CupertinoColors.systemGrey,
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
                  style: const TextStyle(
                    color: CupertinoColors.systemGrey2,
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

class _ConversationScreenState extends State<ConversationScreen> {
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

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _subscribeToRealtime();
    _fallbackTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchMessages(silent: true);
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _scrollController.dispose();
    if (_messagesChannel != null) {
      _client.removeChannel(_messagesChannel!);
    }
    super.dispose();
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
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFE9E9EE),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF1C1C1E),
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
  bool get hasConnectedPeers => _devices.any(
    (d) => d.state.toString().toLowerCase().contains('connected'),
  );
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
      await _macBridge.sendMessage(deviceID: deviceId, message: text);
      return;
    }
    await _nearby.sendMessage(deviceId, text);
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
    this.autoOpenVoiceCall = false,
    this.autoOpenVoiceCallAsInitiator = false,
  });

  final BluetoothNearbyService service;
  final String deviceId;
  final String peerName;
  final bool autoOpenVoiceCall;
  final bool autoOpenVoiceCallAsInitiator;

  @override
  State<BluetoothConversationScreen> createState() =>
      _BluetoothConversationScreenState();
}

class _BluetoothConversationScreenState
    extends State<BluetoothConversationScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  final List<_BluetoothChatMessage> _messages = [];
  StreamSubscription<BluetoothIncomingMessage>? _incomingSub;
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
  bool _showVoiceCallInvite = false;
  final List<Uint8List> _incomingCallQueue = [];
  final List<String> _recentWalkieAudioSignatures = [];
  bool _playingIncomingCallAudio = false;
  bool _loadingHistory = true;
  String _newBtMessageId() =>
      'bt_${DateTime.now().microsecondsSinceEpoch}_${DateTime.now().millisecondsSinceEpoch % 1000}';

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
    _loadLocalHistory();
    _incomingSub = widget.service.messagesStream.listen((event) {
      if (!mounted) return;
      if (_handleCallSignal(event.message)) return;
      if (_handleDeleteControl(event.message)) return;
      final incoming = _parseIncomingMessage(event.message);
      if (incoming == null) return;
      if (_isDuplicateLastIncoming(incoming)) return;
      setState(() {
        _messages.add(incoming.copyWith(isMe: false, sentAt: DateTime.now()));
      });
      _saveLocalHistory();
      _animateToBottom();
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

  Future<void> _connectIfNeeded() async {
    setState(() {
      _connecting = true;
    });
    try {
      await widget.service.invite(widget.deviceId, deviceName: widget.peerName);
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
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
        await widget.service.sendText(
          widget.deviceId,
          'btmsg::${jsonEncode({'id': id, 'type': 'text', 'text': text})}',
        );
        if (!mounted) return;
        setState(() {
          _messages.add(
            _BluetoothChatMessage(
              messageId: id,
              text: text,
              isMe: true,
              sentAt: DateTime.now(),
              photoBytes: null,
              audioBytes: null,
              audioDurationMs: null,
              caption: null,
            ),
          );
        });
      }
      if (!mounted) return;
      setState(() {
        _pendingPhoto = null;
        _pendingVoiceBytes = null;
        _pendingVoiceDurationMs = null;
      });
      _saveLocalHistory();
      _controller.clear();
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
    final payload = jsonEncode({
      'id': id,
      'type': 'photo',
      'bytes': base64Encode(bytes),
      'caption': caption,
    });
    await widget.service.sendText(widget.deviceId, 'btmsg::$payload');
    if (!mounted) return;
    setState(() {
      _messages.add(
        _BluetoothChatMessage(
          messageId: id,
          text: '',
          isMe: true,
          sentAt: DateTime.now(),
          photoBytes: bytes,
          audioBytes: null,
          audioDurationMs: null,
          caption: caption.trim().isEmpty ? null : caption.trim(),
        ),
      );
    });
    _saveLocalHistory();
  }

  Future<void> _sendVoiceNote() async {
    final voice = _pendingVoiceBytes;
    if (voice == null) return;
    final id = _newBtMessageId();
    final payload = jsonEncode({
      'id': id,
      'type': 'voice',
      'bytes': base64Encode(voice),
      'durationMs': _pendingVoiceDurationMs ?? 0,
    });
    await widget.service.sendText(widget.deviceId, 'btmsg::$payload');
    if (!mounted) return;
    setState(() {
      _messages.add(
        _BluetoothChatMessage(
          messageId: id,
          text: '',
          isMe: true,
          sentAt: DateTime.now(),
          photoBytes: null,
          audioBytes: voice,
          audioDurationMs: _pendingVoiceDurationMs,
          caption: null,
        ),
      );
    });
    _saveLocalHistory();
  }

  Future<void> _toggleVoiceRecording() async {
    if (_sending) return;
    if (_recordingVoice) {
      await _stopVoiceRecording();
      return;
    }
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) return;
    final dir = await getTemporaryDirectory();
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
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/play_voice_$messageId.m4a';
    final file = File(path);
    await file.writeAsBytes(message.audioBytes!, flush: true);
    await _audioPlayer.stop();
    await _audioPlayer.play(DeviceFileSource(path));
    if (!mounted) return;
    setState(() {
      _playingMessageId = messageId;
    });
  }

  bool _handleCallSignal(String raw) {
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
          setState(() {
            _showWalkieInvite = true;
            _peerInBluetoothCall = true;
          });
        } else if (type == 'end') {
          setState(() {
            _showWalkieInvite = false;
            _peerInBluetoothCall = false;
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

  bool _handleDeleteControl(String raw) {
    final visibleText = _extractVisibleText(raw);
    if (!visibleText.startsWith('btctl::')) return false;
    try {
      final payload = visibleText.replaceFirst('btctl::', '');
      final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      if (map['action']?.toString() != 'delete') return true;
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
    await widget.service.sendText(
      widget.deviceId,
      'btctl::${jsonEncode({'action': 'delete', 'messageId': message.messageId})}',
    );
  }

  Future<void> _openWalkieTalkie({required bool isInitiator}) async {
    if (isInitiator) {
      await widget.service.sendText(
        widget.deviceId,
        'btcall::${jsonEncode({'type': 'start'})}',
      );
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => WalkieTalkieScreen(
          service: widget.service,
          deviceId: widget.deviceId,
          peerName: widget.peerName,
          sendStartSignalOnOpen: false,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _showWalkieInvite = false;
      _peerInBluetoothCall = false;
    });
  }

  Future<void> _openVoiceCall({required bool isInitiator}) async {
    if (isInitiator) {
      await widget.service.sendText(
        widget.deviceId,
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
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/bt_call_in_${DateTime.now().microsecondsSinceEpoch}.m4a';
        final file = File(path);
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
            sentAt: DateTime.now(),
            photoBytes: bytes,
            audioBytes: null,
            audioDurationMs: null,
            caption: map['caption']?.toString().trim().isEmpty == true
                ? null
                : map['caption']?.toString().trim(),
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
            sentAt: DateTime.now(),
            photoBytes: null,
            audioBytes: bytes,
            audioDurationMs: durationMs,
            caption: null,
          );
        }
        final text = map['text']?.toString() ?? '';
        if (text.trim().isEmpty) return null;
        return _BluetoothChatMessage(
          messageId: id,
          text: text.trim(),
          isMe: false,
          sentAt: DateTime.now(),
          photoBytes: null,
          audioBytes: null,
          audioDurationMs: null,
          caption: null,
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
        middle: Text(widget.peerName),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: () => _openVoiceCall(isInitiator: true),
              child: const Icon(
                CupertinoIcons.phone_fill,
                color: CupertinoColors.systemGreen,
              ),
            ),
            const SizedBox(width: 10),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: () => _openWalkieTalkie(isInitiator: true),
              child: Icon(
                CupertinoIcons.waveform_circle_fill,
                color: CupertinoColors.systemBlue,
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
                          color: const Color(0xFFEAF7FF),
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
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF1C1C1E),
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
                          color: const Color(0xFFEAF7FF),
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
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF1C1C1E),
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
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final message = _messages[index];
                              return Row(
                                mainAxisAlignment: message.isMe
                                    ? MainAxisAlignment.end
                                    : MainAxisAlignment.start,
                                children: [
                                  CupertinoContextMenu(
                                    actions: [
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
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      constraints: BoxConstraints(
                                        maxWidth:
                                            MediaQuery.of(context).size.width *
                                            0.76,
                                      ),
                                      decoration: BoxDecoration(
                                        color: message.isMe
                                            ? const Color(0xFF0A84FF)
                                            : const Color(0xFFE5E5EA),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child:
                                          message.photoBytes == null &&
                                              message.audioBytes == null
                                          ? Text(
                                              message.text,
                                              style: TextStyle(
                                                fontSize: 16,
                                                color: message.isMe
                                                    ? CupertinoColors.white
                                                    : const Color(0xFF1C1C1E),
                                              ),
                                            )
                                          : message.audioBytes != null
                                          ? CupertinoButton(
                                              padding: EdgeInsets.zero,
                                              minimumSize: Size.zero,
                                              onPressed: () =>
                                                  _playVoiceMessage(message),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    _playingMessageId ==
                                                            '${message.sentAt.millisecondsSinceEpoch}_${message.isMe}'
                                                        ? CupertinoIcons
                                                              .stop_fill
                                                        : CupertinoIcons
                                                              .play_fill,
                                                    color: message.isMe
                                                        ? CupertinoColors.white
                                                        : const Color(
                                                            0xFF1C1C1E,
                                                          ),
                                                    size: 22,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    _formatVoiceDuration(
                                                      message.audioDurationMs,
                                                    ),
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      color: message.isMe
                                                          ? CupertinoColors
                                                                .white
                                                          : const Color(
                                                              0xFF1C1C1E,
                                                            ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                          : Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  child: Image.memory(
                                                    message.photoBytes!,
                                                    width: 220,
                                                    height: 220,
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                                if ((message.caption ?? '')
                                                    .trim()
                                                    .isNotEmpty) ...[
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    message.caption!.trim(),
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      color: message.isMe
                                                          ? CupertinoColors
                                                                .white
                                                          : const Color(
                                                              0xFF1C1C1E,
                                                            ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                    ),
                                  ),
                                ],
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
                          color: const Color(0xFFF2F2F7),
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
                              style: const TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1C1C1E),
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
                            const Text(
                              'Grabando...',
                              style: TextStyle(
                                color: Color(0xFF1C1C1E),
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
                          color: const Color(0xFFF2F2F7),
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
                              const Icon(
                                CupertinoIcons.waveform_circle_fill,
                                size: 38,
                                color: CupertinoColors.systemBlue,
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
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
                            onPressed: _recordingVoice
                                ? _stopVoiceRecording
                                : (_sending ? null : _send),
                            child: _sending
                                ? const CupertinoActivityIndicator(radius: 12)
                                : const Icon(
                                    CupertinoIcons.arrow_up_circle_fill,
                                    size: 34,
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
  });

  final BluetoothNearbyService service;
  final String deviceId;
  final String peerName;
  final bool sendStartSignalOnOpen;

  @override
  State<WalkieTalkieScreen> createState() => _WalkieTalkieScreenState();
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
  static const int _callChunkMs = 1100;
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
      final raw = event.message.trim();
      if (!raw.startsWith('btvoicecall::')) return;
      try {
        final payload = raw.replaceFirst('btvoicecall::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        final type = map['type']?.toString() ?? '';
        if (type == 'accept') {
          if (!mounted) return;
          setState(() {
            _peerAccepted = true;
          });
          _startCaptureLoop();
          return;
        }
        if (type == 'audio') {
          if (!_callActive) return;
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
    if (!widget.isInitiator) {
      widget.service.sendText(
        widget.deviceId,
        'btvoicecall::${jsonEncode({'type': 'accept', 'callId': _callId})}',
      );
      _startCaptureLoop();
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
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/voice_call_chunk_${DateTime.now().microsecondsSinceEpoch}.m4a';
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
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/voice_call_in_${DateTime.now().microsecondsSinceEpoch}.m4a';
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
    _incomingSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              style: const TextStyle(fontSize: 16, color: Color(0xFF1C1C1E)),
            ),
            const SizedBox(height: 6),
            Text(
              _fmt(_elapsedMs),
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                color: Color(0xFF636366),
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
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  StreamSubscription<BluetoothIncomingMessage>? _incomingSub;
  final List<Uint8List> _incomingQueue = [];
  final List<String> _recentIncomingSignatures = [];
  bool _playingIncoming = false;
  bool _pttRecording = false;
  DateTime? _pttStartedAt;
  int _elapsedMs = 0;
  Timer? _ticker;
  StreamSubscription<Amplitude>? _amplitudeSub;
  List<double> _spectrum = List<double>.filled(20, 0.08);

  @override
  void initState() {
    super.initState();
    _incomingSub = widget.service.messagesStream.listen((event) {
      final raw = event.message.trim();
      if (!raw.startsWith('btcallvoice::')) return;
      try {
        final payload = raw.replaceFirst('btcallvoice::', '');
        final map = Map<String, dynamic>.from(jsonDecode(payload) as Map);
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
      widget.service.sendText(
        widget.deviceId,
        'btcall::${jsonEncode({'type': 'start'})}',
      );
    }
  }

  Future<void> _startPtt() async {
    if (_pttRecording) return;
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) return;
    final dir = await getTemporaryDirectory();
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
    });
    await widget.service.sendText(widget.deviceId, 'btcallvoice::$payload');
  }

  Future<void> _playQueue() async {
    if (_playingIncoming || _incomingQueue.isEmpty) return;
    _playingIncoming = true;
    try {
      while (_incomingQueue.isNotEmpty) {
        final bytes = _incomingQueue.removeAt(0);
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/walkie_in_${DateTime.now().microsecondsSinceEpoch}.m4a';
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
    widget.service.sendText(
      widget.deviceId,
      'btcall::${jsonEncode({'type': 'end'})}',
    );
    _incomingSub?.cancel();
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              _pttRecording ? 'Hablando...' : 'Mantén presionado para hablar',
              style: const TextStyle(fontSize: 15, color: Color(0xFF636366)),
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
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
                color: Color(0xFF1C1C1E),
              ),
            ),
            const Spacer(),
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
            ),
            const SizedBox(height: 36),
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
    required this.sentAt,
    required this.photoBytes,
    required this.audioBytes,
    required this.audioDurationMs,
    required this.caption,
  });

  final String messageId;
  final String text;
  final bool isMe;
  final DateTime sentAt;
  final Uint8List? photoBytes;
  final Uint8List? audioBytes;
  final int? audioDurationMs;
  final String? caption;

  _BluetoothChatMessage copyWith({
    String? messageId,
    String? text,
    bool? isMe,
    DateTime? sentAt,
    Uint8List? photoBytes,
    Uint8List? audioBytes,
    int? audioDurationMs,
    String? caption,
  }) {
    return _BluetoothChatMessage(
      messageId: messageId ?? this.messageId,
      text: text ?? this.text,
      isMe: isMe ?? this.isMe,
      sentAt: sentAt ?? this.sentAt,
      photoBytes: photoBytes ?? this.photoBytes,
      audioBytes: audioBytes ?? this.audioBytes,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      caption: caption ?? this.caption,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'text': text,
      'isMe': isMe,
      'sentAt': sentAt.toIso8601String(),
      'photoBytes': photoBytes == null ? null : base64Encode(photoBytes!),
      'audioBytes': audioBytes == null ? null : base64Encode(audioBytes!),
      'audioDurationMs': audioDurationMs,
      'caption': caption,
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
      sentAt: sentAt,
      photoBytes: decodedPhoto,
      audioBytes: decodedAudio,
      audioDurationMs: map['audioDurationMs'] is int
          ? map['audioDurationMs'] as int
          : int.tryParse(map['audioDurationMs']?.toString() ?? ''),
      caption: map['caption']?.toString(),
    );
  }
}

class ConversationSummary {
  ConversationSummary({
    required this.id,
    required this.peerPhone,
    required this.peerDisplayName,
    required this.lastMessage,
    required this.lastMessageAt,
    required this.hasUnread,
  });

  final String id;
  final String peerPhone;
  final String peerDisplayName;
  final String lastMessage;
  final DateTime? lastMessageAt;
  final bool hasUnread;
}

class NearbyChatMeta {
  NearbyChatMeta({
    required this.lastMessage,
    required this.lastMessageAt,
    required this.hasUnread,
  });

  final String lastMessage;
  final DateTime? lastMessageAt;
  final bool hasUnread;

  Map<String, dynamic> toJson() => {
    'lastMessage': lastMessage,
    'lastMessageAt': lastMessageAt?.toIso8601String(),
    'hasUnread': hasUnread,
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
