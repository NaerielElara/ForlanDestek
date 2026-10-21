part of 'forlan_support_dialog.dart';

const _messageSoundOption = 'forlan-support-message-sound';

class _SupportApiException implements Exception {
  const _SupportApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
}

class ForlanSupportSession extends ChangeNotifier {
  ForlanSupportSession._();
  static final instance = ForlanSupportSession._();
  final api = _SupportApi(_apiAddress);
  String? token;
  Map<String, dynamic>? account;
  Set<int> changedTickets = {};
  List<Map<String, dynamic>> tickets = [];
  int eventRevision = 0;
  DateTime? freeConnectionExpires, waitingUntil;
  String? freeSessionId;
  int transferUsed = 0, transferLimit = 0;
  void updateConnectionState(Map<String, dynamic> event) {
    final waiting = int.tryParse(event['waiting_until']?.toString() ?? '');
    final expires = int.tryParse(event['expires']?.toString() ?? '');
    if (waiting != null) waitingUntil = DateTime.fromMillisecondsSinceEpoch(waiting * 1000);
    if (event['active']?.toString() == 'true' && event['premium']?.toString() == 'false' && expires != null) {
      freeSessionId = event['session_id']?.toString();
      freeConnectionExpires = DateTime.fromMillisecondsSinceEpoch(expires * 1000);
      waitingUntil = null;
      transferUsed = int.tryParse(event['transfer_used']?.toString() ?? '') ?? transferUsed;
      transferLimit = int.tryParse(event['transfer_limit']?.toString() ?? '') ?? transferLimit;
    } else if (event['active']?.toString() == 'false' && event['session_id']?.toString() == freeSessionId) {
      if (freeConnectionExpires != null && !DateTime.now().isBefore(freeConnectionExpires!)) waitingUntil = freeConnectionExpires!.add(const Duration(minutes: 1));
      freeConnectionExpires = null; freeSessionId = null;
      transferUsed = 0; transferLimit = 0;
    }
    notifyListeners();
  }
  int get unreadCount => tickets.fold(0, (total, ticket) => total + ((ticket['unread_count'] as num?)?.toInt() ?? 0));
  bool get staff => account?['role'] == 'admin' || account?['role'] == 'technician';
  bool get privileged => account?['licensed'] == true || staff;
  bool get supportEnabled => staff || (account?['licensed'] == true && account?['support_enabled'] == true);
  Future<void> refreshTickets() async {
    final accessToken = token;
    if (accessToken == null || !supportEnabled) return;
    final result = await api.get('/api/tickets', accessToken);
    if (token != accessToken) return;
    tickets = (result as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
    notifyListeners();
  }
  Timer? _timer;
  int _cursor = 0;
  bool _polling = false;
  String? _refreshToken;
  bool _restoring = false;

  Future<void> restore() async {
    if (_restoring) return;
    _restoring = true;
    String? restoringToken;
    try {
      if (_refreshToken == null) {
        final saved = bind.mainGetLocalOption(key: 'forlan-support-session');
        if (saved.isEmpty) return;
        final record = jsonDecode(saved) as Map;
        _refreshToken = record['refresh_token'] as String?;
      }
      if (_refreshToken == null) return;
      restoringToken = _refreshToken;
      final id = (await bind.mainGetMyId()).replaceAll(RegExp(r'\D'), '');
      if (!RegExp(r'^[0-9]{3,12}$').hasMatch(id)) return;
      final response = await api.post('/api/auth/restore', {
        'refresh_token': restoringToken,
        'device_id': id,
      });
      if (_refreshToken != restoringToken) return;
      await acceptLogin(response['access_token'] as String,
          Map<String, dynamic>.from(response['account'] as Map),
          refreshToken: response['refresh_token'] as String?, restoringToken: restoringToken);
    } on _SupportApiException catch (error) {
      if (error.statusCode == 401 && _refreshToken == restoringToken) signOut();
    } on FormatException {
      signOut();
    } catch (_) {
      // A startup network interruption must not erase the saved activation.
    } finally {
      _restoring = false;
      if (_refreshToken != null) {
        _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => _poll());
      }
    }
  }

  Future<void> acceptLogin(
      String accessToken, Map<String, dynamic> user, {String? refreshToken, String? restoringToken}) async {
    final support = user['role'] == 'admin' || user['role'] == 'technician' || (user['licensed'] == true && user['support_enabled'] == true);
    final snapshot = support ? await api.get('/api/events', accessToken) : null;
    if (restoringToken != null && _refreshToken != restoringToken) return;
    _timer?.cancel();
    _cursor = snapshot?['cursor'] as int? ?? 0;
    token = accessToken;
    _refreshToken = refreshToken;
    account = user;
    tickets = [];
    try {
      final saved = jsonEncode({'access_token': accessToken, 'refresh_token': refreshToken});
      await bind.mainSetLocalOption(key: 'forlan-support-session', value: saved);
      if (bind.mainGetLocalOption(key: 'forlan-support-session') != saved) {
        throw const FormatException('Oturum bu Windows hesabına kaydedilemedi. Yeniden deneyin.');
      }
    } catch (_) {
      signOut();
      rethrow;
    }
    changedTickets = {};
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    try {
      await refreshTickets();
    } on _SupportApiException catch (error) {
      if (error.statusCode == 401) { signOut(); rethrow; }
    } catch (_) {
      // Ticket polling resumes when the connection recovers.
    }
    notifyListeners();
  }

  void signOut() {
    _timer?.cancel();
    _timer = null;
    token = null;
    _refreshToken = null;
    account = null;
    tickets = [];
    bind.mainSetLocalOption(key: 'forlan-support-session', value: '');
    changedTickets = {};
    forlanSupportSelected.value = false;
    notifyListeners();
  }

  Future<void> _poll() async {
    if (token == null && _refreshToken != null) { await restore(); return; }
    final accessToken = token;
    if (_polling || accessToken == null) return;
    _polling = true;
    try {
      final profile = await api.get('/api/me', accessToken);
      if (token != accessToken) return;
      final previouslySupported = supportEnabled;
      account = Map<String, dynamic>.from(profile as Map);
      if (!supportEnabled) {
        tickets = [];
        changedTickets = {};
        _cursor = 0;
        forlanSupportSelected.value = false;
        notifyListeners();
        return;
      }
      if (!previouslySupported) {
        final snapshot = await api.get('/api/events', accessToken);
        if (token != accessToken) return;
        _cursor = snapshot['cursor'] as int;
      }
      final response = await api.get('/api/events?after=$_cursor', accessToken);
      if (token != accessToken) return;
      final events = List<dynamic>.from(response['events'] as List);
      final changed = <int>{};
      for (final value in events) {
        if (token != accessToken) return;
        final event = Map<String, dynamic>.from(value as Map);
        await _notify(event);
        changed.add(event['ticket_id'] as int);
      }
      if (token != accessToken) return;
      _cursor = response['cursor'] as int;
      await refreshTickets();
      if (changed.isNotEmpty) {
        changedTickets = changed;
        eventRevision++;
        notifyListeners();
      }
    } on _SupportApiException catch (error) {
      if (error.statusCode == 401 && token == accessToken) {
        if (_refreshToken != null) {
          await restore();
        } else {
          signOut();
        }
      }
    } catch (_) {
      // Keep the cursor until a later poll succeeds after a network interruption.
    } finally {
      _polling = false;
    }
  }

  Future<void> _notify(Map<String, dynamic> event) async {
    if (!isWindows || bind.mainGetAppNameSync() != 'ForlanDestek') return;
    final kind = event['kind'];
    final sender = event['sender_name']?.toString() ?? 'Forlan Destek';
    final ticketTitle = event['ticket_title']?.toString() ?? 'Destek kaydı';
    String title;
    String body;
    String sound = '';
    if (kind == 'connection_request') {
      title = 'Teknisyen bağlantı isteği';
      body = '$sender, "$ticketTitle" kaydı için bilgisayarınıza bağlanıyor.';
    } else if (kind == 'ticket_created' ||
        kind == 'message' ||
        kind == 'technician_notification' ||
        kind == 'ticket_status') {
      title = kind == 'ticket_created'
          ? 'Yeni destek talebi'
          : kind == 'technician_notification'
              ? 'Teknisyen bildirimi'
              : kind == 'ticket_status'
                  ? 'Destek kaydı #${event['ticket_id']} · Durum güncellendi'
                  : 'Destek kaydı #${event['ticket_id']} · Yeni mesaj';
      body = kind == 'technician_notification'
          ? '$sender: $ticketTitle · ${event['message'] ?? ''}'
          : '$sender: ${kind == 'message' || kind == 'ticket_status' ? event['message'] ?? ticketTitle : ticketTitle}';
      if (bind.mainGetLocalOption(key: _messageSoundOption) != 'N') {
        sound = 'message';
      }
    } else {
      return;
    }
    final preview = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    await bind.mainSetLocalOption(
      key: 'forlan-support-notification',
      value: jsonEncode({
        'title': title,
        'body':
            preview.length > 200 ? '${preview.substring(0, 200)}…' : preview,
        'sound': sound,
      }),
    );
  }
}

class ForlanSupportSoundSettings extends StatefulWidget {
  const ForlanSupportSoundSettings({super.key});
  @override
  State<ForlanSupportSoundSettings> createState() =>
      _ForlanSupportSoundSettingsState();
}

class _ForlanSupportSoundSettingsState
    extends State<ForlanSupportSoundSettings> {
  Future<void> _set(String key, bool enabled) async {
    await bind.mainSetLocalOption(key: key, value: enabled ? '' : 'N');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Destek talebi ve mesaj sesi'),
        subtitle:
            const Text('Yeni kayıtlar, mesajlar ve destek bildirimleri. Bağlantı istekleri sessizdir.'),
        value: bind.mainGetLocalOption(key: _messageSoundOption) != 'N',
        onChanged: (enabled) => _set(_messageSoundOption, enabled),
      ),
    ]);
  }
}
