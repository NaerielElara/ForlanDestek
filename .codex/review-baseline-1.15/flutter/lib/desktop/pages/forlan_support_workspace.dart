part of 'forlan_support_dialog.dart';

final forlanSupportSelected = ValueNotifier<bool>(false);

class ForlanSupportTabLabel extends StatelessWidget {
  const ForlanSupportTabLabel({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: ForlanSupportSession.instance,
    builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.support_agent, size: 18), const SizedBox(width: 6), const Text('Destek'),
      if (ForlanSupportSession.instance.unreadCount > 0) Container(
        margin: const EdgeInsets.only(left: 5), padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFE65770), borderRadius: BorderRadius.circular(10)),
        child: Text('${ForlanSupportSession.instance.unreadCount}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700))),
    ]));
}

class ForlanCompanyLabel extends StatelessWidget {
  const ForlanCompanyLabel({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: ForlanSupportSession.instance, builder: (_, __) {
    final session = ForlanSupportSession.instance;
    final name = session.privileged ? (session.account?['display_name']?.toString()) : null;
    return Text(name ?? 'Bağlantı servisi', maxLines: 1, overflow: TextOverflow.ellipsis,
      style: TextStyle(color: name == null ? const Color(0xFFA6B5CE) : const Color(0xFFC1A6FF),
        fontSize: name == null ? 10 : 13, fontWeight: name == null ? FontWeight.w400 : FontWeight.w700,
        shadows: name == null ? null : const [Shadow(color: Color(0x99A17CF5), blurRadius: 12)]));
  });
}

class ForlanSupportWorkspace extends StatefulWidget {
  const ForlanSupportWorkspace({super.key});
  @override
  State<ForlanSupportWorkspace> createState() => _ForlanSupportWorkspaceState();
}

class _ForlanSupportWorkspaceState extends State<ForlanSupportWorkspace> {
  final _session = ForlanSupportSession.instance;
  final _code = TextEditingController(), _username = TextEditingController(), _password = TextEditingController();
  bool _staffLogin = false, _busy = false;
  String? _error;
  int? _selected;
  String _bucket = 'today';
  @override
  void initState() { super.initState(); _session.addListener(_changed); _refresh(); }
  void _changed() { if (mounted) setState(() {}); }
  @override
  void dispose() { _session.removeListener(_changed); _code.dispose(); _username.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _refresh() async {
    if (_session.token == null || _busy) return;
    try { await _session.refreshTickets(); } catch (e) { if (mounted) setState(() => _error = e.toString()); }
  }
  Future<void> _login() async {
    setState(() { _busy = true; _error = null; });
    try {
      final result = await _session.api.post(_staffLogin ? '/api/auth/login' : '/api/auth/license',
        _staffLogin ? {'username': _username.text.trim(), 'password': _password.text} : {'license_code': _code.text.trim()});
      if (_staffLogin && result['account']['role'] == 'customer') throw Exception('Müşteri girişi için lisans kodunuzu kullanın.');
      await _session.acceptLogin(result['access_token'] as String, Map<String, dynamic>.from(result['account'] as Map));
      _code.clear(); _password.clear();
      if (mounted) await showDialog<void>(context: context, builder: (_) => const _ForlanLicenseSuccess());
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _newTicket() async {
    final data = await showDialog<Map<String, String>>(context: context, builder: (_) => const _NewSupportTicketDialog());
    if (data == null || !mounted) return;
    setState(() { _busy = true; _error = null; });
    try {
      final id = (await bind.mainGetMyId()).replaceAll(RegExp(r'\D'), '');
      await _session.api.post('/api/tickets', {...data, 'device_id': id}, token: _session.token);
      await _session.refreshTickets(); _bucket = 'today';
    } catch (e) { if (mounted) setState(() => _error = e.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  bool _matches(Map<String, dynamic> t) {
    final status = t['status'];
    if (_bucket == 'resolved') return status == 'resolved';
    if (_bucket == 'closed') return status == 'closed';
    if (status == 'resolved' || status == 'closed' || t['customer_archived'] == true) return false;
    final created = DateTime.tryParse(t['created_at']?.toString() ?? '')?.toLocal();
    final now = DateTime.now(), today = DateTime(now.year, now.month, now.day);
    if (created == null) return _bucket == 'older';
    if (_bucket == 'today') return !created.isBefore(today);
    if (_bucket == 'yesterday') return created.isBefore(today) && !created.isBefore(today.subtract(const Duration(days: 1)));
    return created.isBefore(today.subtract(const Duration(days: 1)));
  }
  @override
  Widget build(BuildContext context) {
    if (_session.account == null) return _welcome();
    if (_selected != null) return _ForlanTicketDetail(key: ValueKey(_selected), ticketId: _selected!, onBack: () { setState(() => _selected = null); _refresh(); });
    final items = _session.tickets.where(_matches).toList();
    final staff = _session.account?['role'] != 'customer';
    final expires = DateTime.tryParse(_session.account?['license_expires_at']?.toString() ?? '');
    final days = expires?.difference(DateTime.now()).inDays;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(_session.account?['display_name']?.toString() ?? 'Destek merkezi', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        if (!staff) FilledButton.icon(onPressed: _busy || !_session.privileged ? null : _newTicket, icon: const Icon(Icons.add, size: 18), label: const Text('Kayıt aç')),
        IconButton(tooltip: 'Yenile', onPressed: _refresh, icon: const Icon(Icons.refresh, size: 20)),
        TextButton(onPressed: () { _session.signOut(); setState(() => _selected = null); }, child: const Text('Çıkış')),
      ])),
      if (days != null && days <= 14) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _InfoBanner(text: 'Lisansınızın bitmesine ${days < 0 ? 0 : days} gün kaldı. Süre uzatmak için bizimle iletişime geçebilirsiniz.', icon: Icons.schedule)),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _InfoBanner(text: _error!, isError: true)),
      SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
        for (final entry in const {'today':'Bugün', 'yesterday':'Dünden kalan', 'older':'Daha eski', 'resolved':'Tamamlanan', 'closed':'İptal'}.entries)
          Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(entry.value), selected: _bucket == entry.key, onSelected: (_) => setState(() => _bucket = entry.key))),
      ])),
      const SizedBox(height: 8),
      Expanded(child: items.isEmpty ? Center(child: Text('Bu listede destek kaydı yok.', style: TextStyle(color: Theme.of(context).hintColor))) : LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1000 ? 3 : constraints.maxWidth >= 650 ? 2 : 1;
        return GridView.builder(padding: const EdgeInsets.all(12), itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, mainAxisExtent: 152, crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemBuilder: (_, index) => _card(items[index]));
      })),
    ]);
  }
  Widget _card(Map<String, dynamic> ticket) {
    final color = ticket['category'] == 'Sistem' ? const Color(0xFF58CDB4) : const Color(0xFFAD90F2);
    final unread = (ticket['unread_count'] as num?)?.toInt() ?? 0;
    const states = {'open':'Yeni', 'in_progress':'İşlemde', 'waiting_customer':'Yanıt bekleniyor', 'resolved':'Tamamlandı', 'closed':'İptal'};
    return Material(color: color.withOpacity(.055), borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => setState(() => _selected = ticket['id'] as int), child: Container(
      padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(ticket['category'] == 'Sistem' ? Icons.dns_outlined : Icons.code, color: color, size: 18), const SizedBox(width: 7), Expanded(child: Text('${ticket['category']} · #${ticket['id']}', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700))), if (unread > 0) Badge(label: Text('$unread'))]),
        const SizedBox(height: 10), Text(ticket['title']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        const Spacer(), Text(ticket['customer_name']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 5), Text('${states[ticket['status']] ?? ticket['status']} · ${ticket['assigned_name'] ?? 'Havuzda'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11)),
      ]))));
  }
  Widget _welcome() => Center(child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.verified_user_outlined, color: Color(0xFFAD90F2), size: 26), const SizedBox(width: 8),
      Text(_staffLogin ? 'Yetkili girişi' : 'Lisansınızı etkinleştirin', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700))]),
    const SizedBox(height: 8), const Text('Destek kayıtları, mesajlar ve lisanslı bağlantı özellikleri.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)), const SizedBox(height: 12),
    if (_error != null) _InfoBanner(text: _error!, isError: true),
    if (_staffLogin) ...[
      TextField(controller: _username, decoration: const InputDecoration(labelText: 'Kullanıcı adı')), const SizedBox(height: 10),
      TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Parola'), onSubmitted: (_) => _busy ? null : _login()),
    ] else TextField(controller: _code, decoration: const InputDecoration(labelText: 'Lisans kodu', hintText: 'FLN-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX', prefixIcon: Icon(Icons.key)), onSubmitted: (_) => _busy ? null : _login()),
    const SizedBox(height: 10), FilledButton(style: FilledButton.styleFrom(foregroundColor: Colors.white), onPressed: _busy ? null : _login, child: Text(_busy ? 'Doğrulanıyor…' : 'Oturum aç')),
    Row(children: [Expanded(child: TextButton(onPressed: _busy ? null : () => setState(() { _staffLogin = !_staffLogin; _error = null; }), child: Text(_staffLogin ? 'Lisans koduyla giriş' : 'Teknisyen / yönetici', style: const TextStyle(fontSize: 11)))),
      Expanded(child: TextButton(onPressed: () => launchUrl(Uri.parse(_purchaseAddress), mode: LaunchMode.externalApplication), child: const Text('Lisans al / süre uzat', style: TextStyle(fontSize: 11))))]),
  ]))));
}

class _ForlanLicenseSuccess extends StatefulWidget {
  const _ForlanLicenseSuccess();
  @override
  State<_ForlanLicenseSuccess> createState() => _ForlanLicenseSuccessState();
}
class _ForlanLicenseSuccessState extends State<_ForlanLicenseSuccess> with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..forward();
  @override
  void dispose() { _animation.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(content: SizedBox(width: 300, height: 190, child: AnimatedBuilder(animation: _animation, builder: (_, __) => Stack(alignment: Alignment.center, children: [
    Positioned.fill(child: CustomPaint(painter: _ForlanConfetti(_animation.value))),
    Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.check_circle, size: 48, color: Color(0xFF58CDB4)), const SizedBox(height: 12), const Text('Başarılı', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)), const SizedBox(height: 8), Text(ForlanSupportSession.instance.account?['display_name']?.toString() ?? '')]),
  ]))), actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Devam et'))]);
}
class _ForlanConfetti extends CustomPainter {
  _ForlanConfetti(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    if (progress >= 1) return;
    for (int i = 0; i < 42; i++) {
      final dx = ((i * 37 % 100) / 100 - .5) * size.width * progress * 1.6;
      final dy = -(40 + i % 9 * 8) * progress + 160 * progress * progress;
      final paint = Paint()..color = [const Color(0xFF58CDB4), const Color(0xFFAD90F2), const Color(0xFFF0C674)][i % 3].withOpacity(1 - progress);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width / 2 + dx, size.height / 2 + dy, 5, 8), const Radius.circular(1)), paint);
    }
  }
  @override
  bool shouldRepaint(_ForlanConfetti old) => old.progress != progress;
}

class _ForlanTicketDetail extends StatefulWidget {
  const _ForlanTicketDetail({super.key, required this.ticketId, required this.onBack});
  final int ticketId;
  final VoidCallback onBack;
  @override
  State<_ForlanTicketDetail> createState() => _ForlanTicketDetailState();
}
class _ForlanTicketDetailState extends State<_ForlanTicketDetail> {
  final _session = ForlanSupportSession.instance;
  final _message = TextEditingController();
  Map<String, dynamic>? _ticket;
  List<dynamic> _history = [];
  bool _busy = false, _historyVisible = false, _queued = false;
  int _revision = 0;
  String? _error;
  @override
  void initState() { super.initState(); _revision = _session.eventRevision; _session.addListener(_event); _load(); }
  @override
  void dispose() { _session.removeListener(_event); _message.dispose(); super.dispose(); }
  void _event() {
    if (_session.eventRevision == _revision) return;
    _revision = _session.eventRevision;
    if (!_session.changedTickets.contains(widget.ticketId)) return;
    if (_busy) { _queued = true; return; }
    _load();
  }
  Future<void> _load() async {
    if (_session.token == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final data = await _session.api.get('/api/tickets/${widget.ticketId}', _session.token!);
      final history = await _session.api.get('/api/tickets/${widget.ticketId}/history', _session.token!);
      if (!mounted) return;
      setState(() { _ticket = Map<String, dynamic>.from(data as Map); _history = history as List; });
      await _session.api.post('/api/tickets/${widget.ticketId}/read', {}, token: _session.token);
      await _session.refreshTickets();
    } catch (e) { if (mounted) setState(() => _error = e.toString()); }
    finally { if (mounted) { setState(() => _busy = false); if (_queued) { _queued = false; _load(); } } }
  }
  Future<void> _action(String path, Map<String, dynamic> body, {bool patch = false, bool connectAfter = false}) async {
    if (_busy || _session.token == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final result = patch ? await _session.api.patch('/api/tickets/${widget.ticketId}/$path', body, token: _session.token!) : await _session.api.post('/api/tickets/${widget.ticketId}/$path', body, token: _session.token);
      if (connectAfter && mounted) connect(context, result['device_id'] as String);
      if (path == 'messages') _message.clear();
      if (mounted) setState(() => _busy = false);
      await _load();
    } catch (e) { if (mounted) setState(() => _error = e.toString()); }
    finally { if (mounted) { setState(() => _busy = false); if (_queued) { _queued = false; _load(); } } }
  }
  Future<void> _cancel() async {
    final note = await _askNote('Kaydı iptal et', 'İptal gerekçesi');
    if (note != null && note.trim().isNotEmpty) await _action('status', {'status': 'closed', 'note': note}, patch: true);
  }
  Future<String?> _askNote(String title, String label) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: Text(title), content: SizedBox(width: 400, child: TextField(controller: controller, maxLength: 10000, minLines: 3, maxLines: 6, decoration: InputDecoration(labelText: label))), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')), FilledButton(onPressed: () { if (controller.text.trim().isNotEmpty) Navigator.pop(ctx, controller.text.trim()); }, child: const Text('Onayla'))]));
    controller.dispose(); return value;
  }
  Future<void> _transfer() async {
    if (_session.token == null) return;
    List<dynamic> people;
    try { people = await _session.api.get('/api/technicians', _session.token!) as List; }
    catch (e) { if (mounted) setState(() => _error = e.toString()); return; }
    if (!mounted) return;
    final note = TextEditingController();
    int? selected;
    final result = await showDialog<Map<String, dynamic>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, change) => AlertDialog(title: const Text('Teknisyene aktar'), content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<int>(value: selected, isExpanded: true, decoration: const InputDecoration(labelText: 'Teknisyen'), items: people.where((p) => p['id'] != _session.account?['id']).map((p) => DropdownMenuItem<int>(value: p['id'] as int, child: Text(p['display_name'] as String))).toList(), onChanged: (v) => change(() => selected = v)),
      const SizedBox(height: 12), TextField(controller: note, minLines: 3, maxLines: 5, maxLength: 10000, decoration: const InputDecoration(labelText: 'Aktarım notu')),
    ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')), FilledButton(onPressed: () { if (selected != null && note.text.trim().isNotEmpty) Navigator.pop(ctx, {'action': 'transfer', 'technician_id': selected, 'note': note.text.trim()}); }, child: const Text('Aktar'))])));
    note.dispose(); if (result != null) await _action('assignment', result);
  }
  @override
  Widget build(BuildContext context) {
    final ticket = _ticket;
    if (ticket == null) return Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator());
    final staff = _session.account?['role'] != 'customer';
    final own = ticket['assigned_to'] == null || ticket['assigned_to'] == _session.account?['id'] || _session.account?['role'] == 'admin';
    final closed = ticket['status'] == 'resolved' || ticket['status'] == 'closed';
    final messages = ticket['messages'] as List? ?? [];
    final color = ticket['category'] == 'Sistem' ? const Color(0xFF58CDB4) : const Color(0xFFAD90F2);
    final assigned = _session.tickets.where((t) => t['id'] == widget.ticketId).map((t) => t['assigned_name']).firstOrNull;
    return Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [IconButton(onPressed: widget.onBack, tooltip: 'Kayıtlara dön', icon: const Icon(Icons.arrow_back)), Expanded(child: Text(ticket['title']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))), if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))]),
      Text('${ticket['category']} · #${ticket['id']} · ${assigned ?? 'Havuzda'}', style: TextStyle(color: color, fontSize: 12)), const SizedBox(height: 6),
      if (staff && !closed) Wrap(spacing: 6, runSpacing: 4, children: [
        FilledButton.icon(onPressed: _busy || !own || ticket['device_id'] == null ? null : () => _action('connection-request', {}, connectAfter: true), icon: const Icon(Icons.desktop_windows, size: 16), label: const Text('Bağlan')),
        if (ticket['assigned_to'] == null) TextButton(onPressed: _busy ? null : () => _action('assignment', {'action': 'claim'}), child: const Text('Üstlen')),
        if (ticket['assigned_to'] != null && own) ...[TextButton(onPressed: _busy ? null : () => _action('assignment', {'action': 'release'}), child: const Text('Havuza bırak')), TextButton(onPressed: _busy ? null : _transfer, child: const Text('Aktar'))],
        TextButton(onPressed: _busy || !own ? null : () => _action('status', {'status': 'resolved'}, patch: true), child: const Text('Tamamlandı')),
        TextButton(onPressed: _busy || !own ? null : _cancel, child: const Text('İptal et')),
      ]),
      if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFFF8B96))),
      Row(children: [TextButton(onPressed: () => setState(() => _historyVisible = false), child: const Text('Konuşma')), TextButton(onPressed: () => setState(() => _historyVisible = true), child: const Text('İşlem geçmişi'))]),
      Expanded(child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: _historyVisible ? _history.map((h) => ListTile(dense: true, title: Text(h['action']?.toString() ?? ''), subtitle: Text('${h['actor_name'] ?? ''} · ${h['details']}'))).toList() : [
        Container(padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: color.withOpacity(.08), borderRadius: BorderRadius.circular(12)), child: SelectableText(ticket['description']?.toString() ?? '')),
        ...messages.map((m) => Container(padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 8), decoration: BoxDecoration(color: MyTheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: MyTheme.stroke)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(m['sender_name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), const SizedBox(height: 6), SelectableText(m['message']?.toString() ?? '')]))),
      ])),
      if (!_historyVisible) Row(children: [Expanded(child: TextField(controller: _message, minLines: 1, maxLines: 3, maxLength: 10000, decoration: const InputDecoration(hintText: 'Mesajınızı yazın', counterText: ''))), IconButton(onPressed: _busy ? null : () { if (_message.text.trim().isNotEmpty) _action('messages', {'message': _message.text.trim()}); }, tooltip: 'Gönder', icon: const Icon(Icons.send))]),
    ]));
  }
}

class ForlanUsageNotice extends StatefulWidget {
  const ForlanUsageNotice({super.key});
  @override
  State<ForlanUsageNotice> createState() => _ForlanUsageNoticeState();
}
class _ForlanUsageNoticeState extends State<ForlanUsageNotice> {
  Timer? _timer;
  @override
  void initState() { super.initState(); _timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); }); }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: ForlanSupportSession.instance, builder: (_, __) {
    final session = ForlanSupportSession.instance;
    final deadline = session.freeConnectionExpires ?? session.waitingUntil;
    if (deadline == null || deadline.isBefore(DateTime.now())) return const SizedBox.shrink();
    final remaining = deadline.difference(DateTime.now()).inSeconds;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Text('${session.freeConnectionExpires == null ? 'Yeni bağlantı için bekleme' : 'Lisanssız bağlantı kalan süre'}: ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}', style: const TextStyle(color: Color(0xFFF0C674), fontWeight: FontWeight.w600, fontSize: 12)));
  });
}
