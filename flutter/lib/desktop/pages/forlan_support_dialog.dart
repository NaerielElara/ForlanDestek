import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show MyTheme, connect, isWindows;
import 'package:flutter_hbb/models/platform_model.dart' show bind;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:url_launcher/url_launcher.dart';

part 'forlan_support_session.dart';
part 'forlan_support_workspace.dart';

const _apiAddress = String.fromEnvironment('FORLAN_SUPPORT_API_URL');
const _apiCaCertificate = String.fromEnvironment('FORLAN_SUPPORT_CA_BASE64');
const _purchaseAddress = String.fromEnvironment(
  'FORLAN_SUPPORT_PURCHASE_URL',
  defaultValue: 'https://forlanyazilim.com/iletisim/',
);

class ForlanSupportEntry extends StatelessWidget {
  const ForlanSupportEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 12, 6),
      decoration: BoxDecoration(
        color: dark ? MyTheme.surface : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? MyTheme.stroke : const Color(0xFFDCE3ED),
        ),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.support_agent, color: MyTheme.accent),
        title: Text(
          'Forlan Destek',
          style: TextStyle(
            color: dark ? const Color(0xFFF4F7FC) : const Color(0xFF182230),
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          'Lisans, destek talepleri ve teknisyen mesajları',
          style: TextStyle(
            color: dark ? const Color(0xFFB6C2D2) : const Color(0xFF66758A),
            fontSize: 11,
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => const ForlanSupportDialog(),
        ),
      ),
    );
  }
}

class ForlanSupportDialog extends StatefulWidget {
  const ForlanSupportDialog({super.key});

  @override
  State<ForlanSupportDialog> createState() => _ForlanSupportDialogState();
}

class _ForlanSupportDialogState extends State<ForlanSupportDialog> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _session = ForlanSupportSession.instance;
  _SupportApi get _api => _session.api;
  String? _token;
  Map<String, dynamic>? _account;
  List<dynamic> _tickets = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _token = _session.token;
    _account = _session.account;
    _session.addListener(_onSessionChanged);
    if (_token != null) _refresh();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _token = _session.token;
      _account = _session.account;
      if (_token == null) _tickets = const [];
    });
    if (_token != null && !_busy) _refresh();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  bool get _apiConfigured {
    final uri = Uri.tryParse(_apiAddress);
    return uri != null &&
        uri.hasAuthority &&
        (uri.scheme == 'https' ||
            (uri.scheme == 'http' &&
                (uri.host == 'localhost' || uri.host == '127.0.0.1')));
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await _api.post('/api/auth/login', {
        'username': _username.text.trim(),
        'password': _password.text,
      });
      await _session.acceptLogin(
        response['access_token'] as String,
        Map<String, dynamic>.from(response['account'] as Map),
        refreshToken: response['refresh_token'] as String?,
      );
      _token = _session.token;
      _account = _session.account;
      await _loadTickets();
    } catch (error) {
      _error = _friendlyError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadTickets() async {
    final response = await _api.get('/api/tickets', _token!);
    _tickets = List<dynamic>.from(response as List);
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _loadTickets();
    } catch (error) {
      _error = _friendlyError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createTicket() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _NewSupportTicketDialog(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deviceId = (await bind.mainGetMyId()).replaceAll(RegExp(r'\D'), '');
      if (!RegExp(r'^[0-9]{3,12}$').hasMatch(deviceId)) {
        throw Exception(
            'Bağlantı kimliği henüz hazır değil. Lütfen tekrar deneyin.');
      }
      await _api.post('/api/tickets', {...result, 'device_id': deviceId},
          token: _token);
      await _loadTickets();
    } catch (error) {
      _error = _friendlyError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTicket(Map<String, dynamic> ticket) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SupportTicketThread(
        api: _api,
        token: _token!,
        ticket: ticket,
        isStaff: _isStaff,
      ),
    );
    if (mounted) _refresh();
  }

  bool get _isStaff =>
      _account?['role'] == 'admin' || _account?['role'] == 'technician';

  String _friendlyError(Object error) => error
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('ClientException: ', '');

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 680,
        height: 600,
        child: _account == null ? _buildWelcome() : _buildTicketPool(),
      ),
    );
  }

  Widget _buildWelcome() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Forlan Destek Merkezi',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              IconButton(
                tooltip: 'Kapat',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Lisanslı müşteriler destek kaydı açabilir ve teknisyen yanıtlarını buradan takip edebilir. Teknisyenler ve yöneticiler ortak talep havuzuna erişir.',
          ),
          const SizedBox(height: 20),
          if (!_apiConfigured)
            const _InfoBanner(
              text:
                  'Destek sunucusu henüz bu derleme için yapılandırılmadı. Güvenli bağlantı adresi eklendiğinde giriş açılır.',
              icon: Icons.lock_outline,
            ),
          if (_error != null) _InfoBanner(text: _error!, isError: true),
          TextField(
            controller: _username,
            enabled: _apiConfigured && !_busy,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: 'Kullanıcı adı',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: _apiConfigured && !_busy,
            obscureText: true,
            onSubmitted: (_) => _apiConfigured && !_busy ? _login() : null,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(
              labelText: 'Parola',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const Spacer(),
          Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(_purchaseAddress);
                  if (uri != null && uri.scheme == 'https') {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Lisans satın al'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _apiConfigured && !_busy ? _login : null,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: const Text('Giriş yap'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTicketPool() {
    final displayName = _account?['display_name'] ?? '';
    final licensed = _account?['licensed'] == true;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 12, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Hoş geldiniz, $displayName',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 3),
                    Text(_isStaff
                        ? 'Teknisyen talep havuzu'
                        : licensed
                            ? 'Lisanslı destek hesabı'
                            : 'Aktif destek lisansı bulunamadı'),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Yenile',
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              TextButton(
                onPressed: _busy ? null : _session.signOut,
                child: const Text('Çıkış'),
              ),
              IconButton(
                tooltip: 'Kapat',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: _InfoBanner(text: _error!, isError: true),
          ),
        Expanded(
          child: _busy && _tickets.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _tickets.isEmpty
                  ? const Center(
                      child: Text('Henüz destek kaydı bulunmuyor.'),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _tickets.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final ticket =
                            Map<String, dynamic>.from(_tickets[index] as Map);
                        final customer = ticket['customer_name'];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Icon(ticket['status'] == 'open'
                                  ? Icons.mark_email_unread_outlined
                                  : Icons.support_agent),
                            ),
                            title: Text(ticket['title']?.toString() ?? ''),
                            subtitle: Text([
                              ticket['category']?.toString() ?? '',
                              if (customer != null) customer.toString(),
                              _statusName(ticket['status']?.toString() ?? ''),
                            ].where((part) => part.isNotEmpty).join(' · ')),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _openTicket(ticket),
                          ),
                        );
                      },
                    ),
        ),
        if (!_isStaff && licensed)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _createTicket,
                icon: const Icon(Icons.add),
                label: const Text('Destek kaydı aç'),
              ),
            ),
          ),
      ],
    );
  }

  String _statusName(String status) => switch (status) {
        'open' => 'Yeni',
        'in_progress' => 'İşlemde',
        'waiting_customer' => 'Müşteri yanıtı bekleniyor',
        'resolved' => 'Çözüldü',
        'closed' => 'Kapalı',
        _ => status,
      };
}

class _SupportApi {
  _SupportApi(String baseAddress) : _baseAddress = baseAddress.trim();
  final String _baseAddress;
  final http.Client _client = _createClient();

  static http.Client _createClient() {
    if (_apiCaCertificate.isEmpty) return http.Client();
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(base64Decode(_apiCaCertificate));
    return IOClient(HttpClient(context: context));
  }

  Uri _uri(String path) {
    final base = Uri.parse(_baseAddress);
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            (base.host == 'localhost' || base.host == '127.0.0.1'))) {
      throw const FormatException('Güvenli HTTPS destek adresi gerekli.');
    }
    final relative = Uri.parse(path);
    return base.replace(
      path: '${base.path.replaceAll(RegExp(r'/$'), '')}${relative.path}',
      query: relative.hasQuery ? relative.query : null,
    );
  }

  Future<dynamic> get(String path, String token) async {
    final response = await _client.get(_uri(path), headers: {
      'Authorization': 'Bearer $token'
    }).timeout(const Duration(seconds: 15));
    return _decode(response);
  }

  Future<dynamic> post(String path, Map<String, dynamic> data,
      {String? token}) async {
    final response = await _client
        .post(_uri(path),
            headers: {
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(data))
        .timeout(const Duration(seconds: 15));
    return _decode(response);
  }

  Future<dynamic> patch(String path, Map<String, dynamic> data,
      {required String token}) async {
    final response = await _client
        .patch(_uri(path),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(data))
        .timeout(const Duration(seconds: 15));
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final dynamic data =
        response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = data is Map ? data['detail'] : null;
      throw _SupportApiException(response.statusCode,
          message?.toString() ?? 'İstek başarısız (${response.statusCode})');
    }
    return data;
  }
}

class _NewSupportTicketDialog extends StatefulWidget {
  const _NewSupportTicketDialog();

  @override
  State<_NewSupportTicketDialog> createState() =>
      _NewSupportTicketDialogState();
}

class _NewSupportTicketDialogState extends State<_NewSupportTicketDialog> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  String _category = 'Yazılım';

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Destek kaydı aç'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(labelText: 'Kategori'),
              items: const [
                DropdownMenuItem(value: 'Yazılım', child: Text('Yazılım')),
                DropdownMenuItem(value: 'Sistem', child: Text('Sistem')),
              ],
              onChanged: (value) =>
                  setState(() => _category = value ?? _category),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Konu'),
            ),
            TextField(
              controller: _description,
              maxLength: 10000,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Sorun açıklaması'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          onPressed: () {
            if (_title.text.trim().length < 3 ||
                _description.text.trim().isEmpty) return;
            Navigator.pop(context, {
              'category': _category,
              'title': _title.text.trim(),
              'description': _description.text.trim(),
            });
          },
          child: const Text('Kaydı gönder'),
        ),
      ],
    );
  }
}

class _SupportTicketThread extends StatefulWidget {
  const _SupportTicketThread({
    required this.api,
    required this.token,
    required this.ticket,
    required this.isStaff,
  });

  final _SupportApi api;
  final String token;
  final Map<String, dynamic> ticket;
  final bool isStaff;

  @override
  State<_SupportTicketThread> createState() => _SupportTicketThreadState();
}

class _SupportTicketThreadState extends State<_SupportTicketThread> {
  final _message = TextEditingController();
  Map<String, dynamic>? _details;
  bool _busy = true;
  String? _error;
  bool _refreshQueued = false;

  @override
  void initState() {
    super.initState();
    ForlanSupportSession.instance.addListener(_onSupportEvent);
    _load();
  }

  @override
  void dispose() {
    _message.dispose();
    ForlanSupportSession.instance.removeListener(_onSupportEvent);
    super.dispose();
  }

  void _onSupportEvent() {
    if (!mounted ||
        !ForlanSupportSession.instance.changedTickets
            .contains(widget.ticket['id'])) return;
    if (_busy) {
      _refreshQueued = true;
      return;
    }
    setState(() => _busy = true);
    _load();
  }

  void _refreshIfQueued() {
    if (!mounted || !_refreshQueued) return;
    _refreshQueued = false;
    setState(() => _busy = true);
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.api
          .get('/api/tickets/${widget.ticket['id']}', widget.token);
      if (mounted) {
        setState(() => _details = Map<String, dynamic>.from(result as Map));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refreshIfQueued();
      }
    }
  }

  Future<void> _requestConnection() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.post(
        '/api/tickets/${widget.ticket['id']}/connection-request',
        {},
        token: widget.token,
      );
      if (mounted) {
        connect(context, result['device_id'] as String);
      }
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshIfQueued();
    }
  }

  Future<void> _send() async {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.post(
        '/api/tickets/${widget.ticket['id']}/messages',
        {'message': message},
        token: widget.token,
      );
      _message.clear();
      await _load();
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshIfQueued();
    }
  }

  Future<void> _setStatus(String? value) async {
    if (value == null) return;
    setState(() => _busy = true);
    try {
      final result = await widget.api.patch(
        '/api/tickets/${widget.ticket['id']}/status',
        {'status': value},
        token: widget.token,
      );
      _details?['status'] = result['status'];
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshIfQueued();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ticket = _details ?? widget.ticket;
    final messages =
        List<dynamic>.from(_details?['messages'] as List? ?? const []);
    return AlertDialog(
      title: Text(ticket['title']?.toString() ?? 'Destek kaydı'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${ticket['category'] ?? ''} · ${ticket['status'] ?? ''}'),
            const SizedBox(height: 8),
            Flexible(
              flex: 2,
              child: SingleChildScrollView(
                child: SelectableText(ticket['description']?.toString() ?? ''),
              ),
            ),
            if (widget.isStaff)
              DropdownButton<String>(
                value: const [
                  'open',
                  'in_progress',
                  'waiting_customer',
                  'resolved',
                  'closed'
                ].contains(ticket['status'])
                    ? ticket['status'] as String
                    : 'open',
                items: const [
                  DropdownMenuItem(value: 'open', child: Text('Yeni')),
                  DropdownMenuItem(
                      value: 'in_progress', child: Text('İşlemde')),
                  DropdownMenuItem(
                      value: 'waiting_customer',
                      child: Text('Müşteri yanıtı bekleniyor')),
                  DropdownMenuItem(value: 'resolved', child: Text('Çözüldü')),
                  DropdownMenuItem(value: 'closed', child: Text('Kapalı')),
                ],
                onChanged: _busy ? null : _setStatus,
              ),
            const Divider(),
            Expanded(
              flex: 4,
              child: _busy && _details == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message =
                            Map<String, dynamic>.from(messages[index] as Map);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(message['sender_name']?.toString() ?? ''),
                          subtitle: SelectableText(
                              message['message']?.toString() ?? ''),
                        );
                      },
                    ),
            ),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _message,
                    maxLength: 10000,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Mesajınızı yazın',
                      counterText: '',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Gönder',
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (widget.isStaff &&
            ticket['device_id'] != null &&
            !const ['resolved', 'closed'].contains(ticket['status']))
          FilledButton.icon(
            onPressed: _busy ? null : _requestConnection,
            icon: const Icon(Icons.desktop_windows_outlined),
            label: const Text('Müşteriye bağlan'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Kapat'),
        ),
      ],
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text, this.isError = false, this.icon});
  final String text;
  final bool isError;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color =
        isError ? Theme.of(context).colorScheme.error : MyTheme.accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon ?? (isError ? Icons.error_outline : Icons.info_outline),
              color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
