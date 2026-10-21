part of 'forlan_support_dialog.dart';

const _messageSoundOption = 'forlan-support-message-sound';
const _connectionSoundOption = 'forlan-support-connection-sound';

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
  void updateConnectionState(Map<String, dynamic> event) {
    final waiting = int.tryParse(event['waiting_until']?.toString() ?? '');
    final expires = int.tryParse(event['expires']?.toString() ?? '');
    if (waiting != null) waitingUntil = DateTime.fromMillisecondsSinceEpoch(waiting * 1000);
    if (event['active']?.toString() == 'true' && event['premium']?.toString() == 'false' && expires != null) {
      freeSessionId = event['session_id']?.toString();
      freeConnectionExpires = DateTime.fromMillisecondsSinceEpoch(expires * 1000);
      waitingUntil = null;
    } else if (event['active']?.toString() == 'false' && event['session_id']?.toString() == freeSessionId) {
      if (freeConnectionExpires != null && !DateTime.now().isBefore(freeConnectionExpires!)) waitingUntil = freeConnectionExpires!.add(const Duration(minutes: 1));
      freeConnectionExpires = null; freeSessionId = null;
    }
    notifyListeners();
  }
  int get unreadCount => tickets.fold(0, (total, ticket) => total + ((ticket['unread_count'] as num?)?.toInt() ?? 0));
  bool get privileged => account?['licensed'] == true || account?['role'] == 'admin' || account?['role'] == 'technician';
  Future<void> refreshTickets() async {
    final accessToken = token;
    if (accessToken == null) return;
    final result = await api.get('/api/tickets', accessToken);
    if (token != accessToken) return;
    tickets = (result as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
    notifyListeners();
  }
  Timer? _timer;
  int _cursor = 0;
  bool _polling = false;

  Future<void> acceptLogin(
      String accessToken, Map<String, dynamic> user) async {
    final snapshot = await api.get('/api/events', accessToken);
    _timer?.cancel();
    _cursor = snapshot['cursor'] as int;
    token = accessToken;
    account = user;
    try {
      await bind.mainSetLocalOption(key: 'forlan-support-session', value: accessToken);
      await refreshTickets();
    } catch (_) {
      signOut();
      rethrow;
    }
    changedTickets = {};
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    notifyListeners();
  }

  void signOut() {
    _timer?.cancel();
    _timer = null;
    token = null;
    account = null;
    tickets = [];
    bind.mainSetLocalOption(key: 'forlan-support-session', value: '');
    changedTickets = {};
    notifyListeners();
  }

  Future<void> _poll() async {
    final accessToken = token;
    if (_polling || accessToken == null) return;
    _polling = true;
    try {
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
      final profile = await api.get('/api/me', accessToken);
      if (token != accessToken) return;
      account = Map<String, dynamic>.from(profile as Map);
      await refreshTickets();
      if (changed.isNotEmpty) {
        changedTickets = changed;
        eventRevision++;
        notifyListeners();
      }
    } on _SupportApiException catch (error) {
      if (error.statusCode == 401 && token == accessToken) signOut();
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
      if (bind.mainGetLocalOption(key: _connectionSoundOption) != 'N') {
        sound = 'connection';
      }
    } else if (kind == 'ticket_created' || kind == 'message') {
      title = kind == 'ticket_created'
          ? 'Yeni destek talebi'
          : 'Destek kaydı #${event['ticket_id']} · Yeni mesaj';
      body =
          '$sender: ${kind == 'message' ? event['message'] ?? '' : ticketTitle}';
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
            const Text('Oturumunuz açıkken yeni talepler ve gelen mesajlar.'),
        value: bind.mainGetLocalOption(key: _messageSoundOption) != 'N',
        onChanged: (enabled) => _set(_messageSoundOption, enabled),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Teknisyen bağlantı isteği sesi'),
        subtitle:
            const Text('Yalnızca lisanslı hesabınızın açık destek kaydı için.'),
        value: bind.mainGetLocalOption(key: _connectionSoundOption) != 'N',
        onChanged: (enabled) => _set(_connectionSoundOption, enabled),
      ),
    ]);
  }
}
