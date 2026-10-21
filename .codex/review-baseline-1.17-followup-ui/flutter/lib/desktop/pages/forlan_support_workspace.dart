part of 'forlan_support_dialog.dart';

final forlanSupportSelected = ValueNotifier<bool>(false);

Future<void> showForlanLicenseDialog(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (_) => const _ForlanLicenseDialog(),
  );
  if (accepted == true && context.mounted) {
    await showDialog<void>(context: context, builder: (_) => const _ForlanLicenseSuccess());
  }
}

class ForlanLicenseAction extends StatelessWidget {
  const ForlanLicenseAction({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: ForlanSupportSession.instance,
    builder: (_, __) {
      final session = ForlanSupportSession.instance;
      final expires = DateTime.tryParse(session.account?['license_expires_at']?.toString() ?? '');
      final days = expires?.difference(DateTime.now()).inDays;
      final expiring = session.privileged && !session.staff && days != null && days <= 14;
      final label = session.token == null ? 'Giriş yap / Lisansı etkinleştir' : session.staff ? 'Yetkili hesap' : '${session.account?['license_kind'] == 'trial' ? 'Deneme lisansı' : 'Lisans etkin'}${expiring ? ' · ${days < 0 ? 0 : days} gün kaldı' : ''}';
      return TextButton.icon(
        onPressed: () => showForlanLicenseDialog(context),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 24),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: expiring ? const Color(0xFFF0C674) : session.privileged ? const Color(0xFF6BDBC1) : const Color(0xFFC1A6FF),
          alignment: Alignment.centerLeft,
        ),
        icon: Icon(session.privileged ? Icons.verified_outlined : Icons.key_rounded, size: 13),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
      );
    },
  );
}

class ForlanLicenseDetails extends StatelessWidget {
  const ForlanLicenseDetails({super.key});
  @override
  Widget build(BuildContext context) {
    final session = ForlanSupportSession.instance;
    final expires = DateTime.tryParse(session.account?['license_expires_at']?.toString() ?? '')?.toLocal();
    final limit = (session.account?['device_limit'] as num?)?.toInt() ?? 0;
    final role = session.staff ? (session.account?['role'] == 'admin' ? 'Yönetici' : 'Teknisyen') : session.supportEnabled ? 'Destek dahil lisans' : 'Kullanım lisansı';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(session.account?['display_name']?.toString() ?? 'Lisansınız henüz etkinleştirilmedi.', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      if (session.token != null) ...[
        const SizedBox(height: 8),
        Text('${session.account?['license_kind'] == 'trial' ? 'Deneme · ' : ''}$role', style: const TextStyle(color: Color(0xFFC1A6FF), fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(session.privileged ? 'Süre ve dosya kotası olmadan, birden fazla bağlantı.' : 'Lisansınız etkin değil. Ücretsiz kullanım sınırları geçerli.', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        if (session.privileged && session.freeConnectionExpires?.isAfter(DateTime.now()) == true)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('Bu açık bağlantı başlatıldığı andaki ücretsiz sınırlarla devam eder. Lisanslı kullanım için bağlantıyı kapatıp yeniden bağlanın.', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))),
        if (!session.staff) ...[
          const SizedBox(height: 8),
          if (expires != null) Text('Bitiş: ${expires.day.toString().padLeft(2, '0')}.${expires.month.toString().padLeft(2, '0')}.${expires.year}', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text('Cihaz hakkı: ${limit == 0 ? 'Sınırsız' : limit}', style: const TextStyle(fontSize: 12)),
          if (!session.supportEnabled) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Bu lisans uzaktan bağlantı kullanımını kapsar; Forlan destek hizmeti dahil değildir.', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))),
        ],
      ],
    ]);
  }
}

class _ForlanLicenseDialog extends StatefulWidget {
  const _ForlanLicenseDialog();
  @override
  State<_ForlanLicenseDialog> createState() => _ForlanLicenseDialogState();
}

class _ForlanLicenseDialogState extends State<_ForlanLicenseDialog> {
  final _session = ForlanSupportSession.instance;
  final _code = TextEditingController(), _username = TextEditingController(), _password = TextEditingController();
  bool _staffLogin = false, _busy = false, _changeAccount = false;
  String? _error;
  @override
  void dispose() { _code.dispose(); _username.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _login() async {
    setState(() { _busy = true; _error = null; });
    try {
      final id = (await bind.mainGetMyId()).replaceAll(RegExp(r'\D'), '');
      if (!_staffLogin && !RegExp(r'^[0-9]{3,12}$').hasMatch(id)) throw Exception('Bağlantı kimliği hazırlanıyor. Servis hazır olduğunda tekrar deneyin.');
      final version = await bind.mainGetVersion();
      final result = await _session.api.post(_staffLogin ? '/api/auth/login' : '/api/auth/license', {
        if (_staffLogin) ...{'username': _username.text.trim(), 'password': _password.text}
        else 'license_code': _code.text.trim(),
        if (RegExp(r'^[0-9]{3,12}$').hasMatch(id)) 'device_id': id,
        'device_name': Platform.localHostname.length > 160 ? Platform.localHostname.substring(0, 160) : Platform.localHostname,
        'app_version': version.length > 40 ? version.substring(0, 40) : version,
      });
      if (_staffLogin && result['account']['role'] == 'customer') throw Exception('Müşteri girişi için lisans kodunuzu kullanın.');
      await _session.acceptLogin(result['access_token'] as String, Map<String, dynamic>.from(result['account'] as Map));
      if (mounted) Navigator.pop(context, true);
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [const Icon(Icons.verified_user_outlined, color: Color(0xFFC1A6FF), size: 24), const SizedBox(width: 9), Expanded(child: Text(_session.token != null && !_changeAccount ? 'Lisans ve hesap' : 'Giriş yap / Lisansı etkinleştir', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))), IconButton(onPressed: _busy ? null : () => Navigator.pop(context), tooltip: 'Kapat', icon: const Icon(Icons.close, size: 20))]),
      const SizedBox(height: 14),
      if (_session.token != null && !_changeAccount) ...[
        const ForlanLicenseDetails(),
        const SizedBox(height: 18),
        OutlinedButton.icon(onPressed: () => setState(() => _changeAccount = true), icon: const Icon(Icons.key, size: 18), label: const Text('Farklı hesap / lisans kullan')),
      ] else ...[
        Row(children: [
          Expanded(child: _mode('Lisans kodu', !_staffLogin, () => setState(() { _staffLogin = false; _error = null; }))),
          const SizedBox(width: 8),
          Expanded(child: _mode('Yetkili girişi', _staffLogin, () => setState(() { _staffLogin = true; _error = null; }))),
        ]),
        const SizedBox(height: 14),
        Text(_staffLogin ? 'Teknisyen veya yönetici hesabınızla giriş yapın.' : 'Kullanım hakkınız lisansınıza göre etkinleşir. Destek dahilse talepler ve mesajlar da açılır.', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        const SizedBox(height: 16),
        if (_error != null) ...[_InfoBanner(text: _error!, isError: true), const SizedBox(height: 12)],
        if (_staffLogin) ...[
          TextField(controller: _username, enabled: !_busy, autofocus: true, decoration: const InputDecoration(labelText: 'Kullanıcı adı', prefixIcon: Icon(Icons.person_outline))), const SizedBox(height: 12),
          TextField(controller: _password, enabled: !_busy, obscureText: true, decoration: const InputDecoration(labelText: 'Parola', prefixIcon: Icon(Icons.lock_outline)), onSubmitted: (_) => _busy ? null : _login()),
        ] else TextField(controller: _code, enabled: !_busy, autofocus: true, decoration: const InputDecoration(labelText: 'Lisans kodu', hintText: 'FLN-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX', prefixIcon: Icon(Icons.key)), onSubmitted: (_) => _busy ? null : _login()),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _busy ? null : _login, style: FilledButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(0, 44)), icon: _busy ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.login, size: 18), label: Text(_busy ? 'Doğrulanıyor…' : _staffLogin ? 'Giriş yap' : 'Lisansı etkinleştir')),
      ],
      const SizedBox(height: 6),
      TextButton.icon(onPressed: () => launchUrl(Uri.parse(_purchaseAddress), mode: LaunchMode.externalApplication), icon: const Icon(Icons.open_in_new, size: 15), label: const Text('Lisans al / süre uzat', style: TextStyle(fontSize: 12))),
    ]))),
  );
  Widget _mode(String label, bool selected, VoidCallback onTap) => TextButton(onPressed: _busy ? null : onTap, style: TextButton.styleFrom(backgroundColor: selected ? const Color(0xFFAD90F2).withOpacity(.16) : null, foregroundColor: selected ? const Color(0xFFC1A6FF) : Theme.of(context).hintColor), child: Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)));
}

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
  bool _busy = false;
  String? _error;
  int? _selected;
  final _search = TextEditingController();
  bool _archive = false, _searchVisible = false;
  String _scope = 'all';
  bool get _staff => _session.account?['role'] != 'customer';
  bool _closed(Map<String, dynamic> ticket) => ticket['status'] == 'resolved' || ticket['status'] == 'closed';
  @override
  void initState() { super.initState(); _session.addListener(_changed); _refresh(); }
  void _changed() { if (mounted) setState(() {}); }
  @override
  void dispose() { _session.removeListener(_changed); _search.dispose(); super.dispose(); }
  Future<void> _refresh() async {
    if (!_session.supportEnabled || _busy) return;
    try { await _session.refreshTickets(); } catch (e) { if (mounted) setState(() => _error = e.toString()); }
  }
  Future<void> _newTicket() async {
    final data = await showDialog<Map<String, String>>(context: context, builder: (_) => const _NewSupportTicketDialog());
    if (data == null || !mounted) return;
    setState(() { _busy = true; _error = null; });
    try {
      final id = (await bind.mainGetMyId()).replaceAll(RegExp(r'\D'), '');
      final result = await _session.api.post('/api/tickets', {...data, 'device_id': id}, token: _session.token);
      await _session.refreshTickets();
      if (mounted) setState(() => _selected = result['id'] as int);
    } catch (e) { if (mounted) setState(() => _error = e.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  bool _matches(Map<String, dynamic> t) {
    if (_closed(t) != (_staff && _archive)) return false;
    if (t['customer_archived'] == true && !_archive) return false;
    if (_staff && _scope == 'mine' && t['assigned_to'] != _session.account?['id']) return false;
    if (_staff && _scope == 'pool' && t['assigned_to'] != null) return false;
    final query = _search.text.trim().toLowerCase();
    return !_staff || query.isEmpty || '${t['title']} ${t['customer_name']} ${t['category']} ${t['id']}'.toLowerCase().contains(query);
  }
  @override
  Widget build(BuildContext context) {
    if (!_session.supportEnabled) return const SizedBox.shrink();
    if (_selected != null && (_staff || _session.tickets.any((t) => t['id'] == _selected && !_closed(t)))) {
      return _ForlanTicketDetail(key: ValueKey(_selected), ticketId: _selected!, onBack: () { setState(() => _selected = null); _refresh(); });
    }
    final items = _session.tickets.where(_matches).toList();
    final activeCount = _session.tickets.where((t) => !_closed(t) && t['customer_archived'] != true).length;
    final archiveCount = _session.tickets.where(_closed).length;
    final expires = DateTime.tryParse(_session.account?['license_expires_at']?.toString() ?? '');
    final days = expires?.difference(DateTime.now()).inDays;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 6, 6), child: Row(children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(color: const Color(0xFFAD90F2).withOpacity(.12), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.support_agent, color: Color(0xFFC1A6FF), size: 21)),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_staff ? 'Destek havuzu' : 'Destek taleplerim', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Text(_staff ? '$activeCount aktif kayıt' : activeCount == 0 ? 'Bir sorununuz olduğunda buradayız.' : '$activeCount aktif talep · Mesajlarınız burada', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        if (!_staff) FilledButton.icon(onPressed: _busy || !_session.supportEnabled ? null : _newTicket, icon: const Icon(Icons.add, size: 17), label: const Text('Kayıt aç')),
        if (_staff) IconButton(tooltip: 'Kayıt ara', onPressed: () => setState(() { _searchVisible = !_searchVisible; if (!_searchVisible) _search.clear(); }), icon: Icon(_searchVisible ? Icons.search_off : Icons.search, size: 20)),
        IconButton(tooltip: 'Yenile', onPressed: _refresh, icon: const Icon(Icons.refresh, size: 20)),
      ])),
      if (!_staff && days != null && days <= 14) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _InfoBanner(text: 'Lisansınızın bitmesine ${days < 0 ? 0 : days} gün kaldı. Süre uzatmak için bizimle iletişime geçebilirsiniz.', icon: Icons.schedule)),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _InfoBanner(text: _error!, isError: true)),
      if (_staff) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 8, 6), child: Row(children: [
        _listToggle('Aktif', activeCount, !_archive, () => setState(() => _archive = false)), const SizedBox(width: 5),
        _listToggle('Arşiv', archiveCount, _archive, () => setState(() => _archive = true)), const Spacer(),
        PopupMenuButton<String>(tooltip: 'Kayıtları filtrele', initialValue: _scope, onSelected: (value) => setState(() => _scope = value), itemBuilder: (_) => const [
          PopupMenuItem(value: 'all', child: Text('Tüm kayıtlar')),
          PopupMenuItem(value: 'mine', child: Text('Üstlendiğim kayıtlar')),
          PopupMenuItem(value: 'pool', child: Text('Havuzdaki kayıtlar')),
        ], child: Padding(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.filter_list, size: 17), const SizedBox(width: 4), Text(const {'all': 'Tümü', 'mine': 'Benim', 'pool': 'Havuz'}[_scope]!, style: const TextStyle(fontSize: 11)), const Icon(Icons.expand_more, size: 16)]))),
      ])),
      if (_staff && _searchVisible) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: TextField(controller: _search, autofocus: true, onChanged: (_) => setState(() {}), decoration: const InputDecoration(isDense: true, hintText: 'Firma, konu veya kayıt numarası…', prefixIcon: Icon(Icons.search, size: 18), contentPadding: EdgeInsets.symmetric(vertical: 9, horizontal: 12)))),
      Expanded(child: items.isEmpty ? _empty() : LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1080 ? 3 : constraints.maxWidth >= 520 ? 2 : 1;
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final ticket in items) { groups.putIfAbsent(_dayLabel(ticket), () => []).add(ticket); }
        return ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), children: [
          for (final group in groups.entries) ...[
            if (_staff) Padding(padding: const EdgeInsets.fromLTRB(1, 6, 0, 7), child: Text('${group.key} · ${group.value.length}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11, fontWeight: FontWeight.w600))),
            for (var start = 0; start < group.value.length; start += columns) Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var offset = 0; offset < columns; offset++) ...[
                if (offset > 0) const SizedBox(width: 8),
                Expanded(child: start + offset < group.value.length ? SizedBox(height: 126, child: _card(group.value[start + offset])) : const SizedBox.shrink()),
              ],
            ])),
          ],
        ]);
      })),
    ]);
  }
  Widget _listToggle(String label, int count, bool selected, VoidCallback onTap) => TextButton(
    style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8), backgroundColor: selected ? const Color(0xFFAD90F2).withOpacity(.16) : Colors.transparent, foregroundColor: selected ? const Color(0xFFCBB6FF) : Theme.of(context).hintColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
    onPressed: onTap, child: Text('$label  $count', style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)));
  String _dayLabel(Map<String, dynamic> ticket) {
    if (_archive) return ticket['status'] == 'resolved' ? 'Tamamlanan' : 'İptal edilen';
    final created = DateTime.tryParse(ticket['created_at']?.toString() ?? '')?.toLocal();
    final now = DateTime.now(), today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    if (created == null) return 'Önceki günlerden';
    if (!created.isBefore(today)) return 'Bugün';
    if (!created.isBefore(DateTime(now.year, now.month, now.day - 1))) return 'Dünden kalan';
    return 'Önceki günlerden';
  }
  Widget _empty() => Center(child: Padding(padding: const EdgeInsets.all(18), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(_staff ? Icons.task_alt : Icons.chat_bubble_outline, size: 32, color: const Color(0xFFAD90F2).withOpacity(.8)),
    const SizedBox(height: 10), Text(_staff ? (_search.text.isNotEmpty || _scope != 'all' ? 'Bu filtreye uygun kayıt yok.' : _archive ? 'Henüz arşivlenmiş kayıt yok.' : 'Destek havuzu güncel.') : 'Aktif destek talebiniz yok.', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
    const SizedBox(height: 5), Text(_staff ? 'Yeni kayıtlar geldiğinde burada görünecek.' : 'Kayıt açın; teknisyen yanıtlarını buradan takip edin.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
  ])));
  Widget _card(Map<String, dynamic> ticket) {
    final color = ticket['category'] == 'Sistem' ? const Color(0xFF58CDB4) : const Color(0xFFAD90F2);
    final unread = (ticket['unread_count'] as num?)?.toInt() ?? 0;
    const states = {'open':'Yeni', 'in_progress':'İşlemde', 'waiting_customer':'Yanıt bekleniyor', 'resolved':'Tamamlandı', 'closed':'İptal'};
    return Material(color: color.withOpacity(.055), borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => setState(() => _selected = ticket['id'] as int), child: Container(
      padding: const EdgeInsets.all(11), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(ticket['category'] == 'Sistem' ? Icons.dns_outlined : Icons.code, color: color, size: 18), const SizedBox(width: 7), Expanded(child: Text('${ticket['category']} · #${ticket['id']}', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700))), if (unread > 0) Badge(label: Text('$unread'))]),
        const SizedBox(height: 7), Text(ticket['title']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const Spacer(), if (_staff) Text(ticket['customer_name']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 5), Text('${states[ticket['status']] ?? ticket['status']} · ${ticket['assigned_name'] ?? 'Havuzda'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11)),
      ]))));
  }

}

class _ForlanLicenseSuccess extends StatefulWidget {
  const _ForlanLicenseSuccess();
  @override
  State<_ForlanLicenseSuccess> createState() => _ForlanLicenseSuccessState();
}
class _ForlanLicenseSuccessState extends State<_ForlanLicenseSuccess> with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  Timer? _close;
  bool _started = false, _reducedMotion = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reducedMotion = MediaQuery.of(context).disableAnimations;
    if (_reducedMotion) { _animation.value = 1; } else { _animation.forward(); }
    _close = Timer(Duration(milliseconds: _reducedMotion ? 1800 : 3000), () { if (mounted) Navigator.pop(context); });
  }
  @override
  void dispose() { _close?.cancel(); _animation.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Dialog(backgroundColor: Colors.transparent, elevation: 0, insetPadding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 430), child: ClipRRect(borderRadius: BorderRadius.circular(24), child: AnimatedBuilder(animation: _animation, builder: (_, __) {
    final entrance = _reducedMotion ? 1.0 : const Interval(0, .28, curve: Curves.easeOutCubic).transform(_animation.value);
    return Container(height: 320, decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF212B43), Color(0xFF111929)]), border: Border.all(color: const Color(0xFFAD90F2).withOpacity(.35))), child: Stack(alignment: Alignment.center, children: [
      Positioned.fill(child: CustomPaint(painter: _ForlanConfetti(_animation.value, reducedMotion: _reducedMotion))),
      Opacity(opacity: entrance, child: Transform.translate(offset: Offset(0, 12 * (1 - entrance)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 26), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        SizedBox(width: 94, height: 94, child: CustomPaint(painter: _ForlanSuccessSeal(_reducedMotion ? 1 : _animation.value))),
        const SizedBox(height: 18), const Text('Başarıyla giriş yaptınız', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFF5F3FF), fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -.35)),
        const SizedBox(height: 8), Text('Hoş geldiniz, ${ForlanSupportSession.instance.account?['display_name'] ?? ''}', textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFC3B6E8), fontSize: 14)),
        const SizedBox(height: 20), TextButton(onPressed: () => Navigator.pop(context), child: const Text('Devam et', style: TextStyle(color: Color(0xFF6BDBC1), fontWeight: FontWeight.w600))),
      ])))),
    ]));
  }))));
}
class _ForlanConfetti extends CustomPainter {
  _ForlanConfetti(this.progress, {this.reducedMotion = false});
  final double progress;
  final bool reducedMotion;
  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * .36);
    canvas.drawCircle(origin, size.width * .38, Paint()..shader = const RadialGradient(colors: [Color(0x22AD90F2), Color(0x00111929)]).createShader(Rect.fromCircle(center: origin, radius: size.width * .38)));
    if (progress >= 1 || reducedMotion) return;
    final random = math.Random(47);
    const colors = [Color(0xFF6BDBC1), Color(0xFFC2A5FF), Color(0xFF5DABFF), Color(0xFFF0D298)];
    for (var i = 0; i < 72; i++) {
      final delay = random.nextDouble() * .16;
      final angle = -math.pi * (.08 + random.nextDouble() * .84);
      final speed = 120 + random.nextDouble() * 260;
      final spin = (random.nextDouble() - .5) * math.pi * 9;
      final width = 3 + random.nextDouble() * 3, height = 5 + random.nextDouble() * 5;
      final t = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (t == 0) continue;
      final fade = 1 - const Interval(.4, 1, curve: Curves.easeIn).transform(t);
      canvas.save();
      canvas.translate(origin.dx + math.cos(angle) * speed * t, origin.dy + math.sin(angle) * speed * t + 245 * t * t);
      canvas.rotate(spin * t);
      canvas.scale(.3 + .7 * math.cos(spin * t).abs(), 1);
      final paint = Paint()..color = colors[i % colors.length].withOpacity(fade * .9);
      if (i % 5 == 0) { canvas.drawCircle(Offset.zero, width / 2, paint); } else { canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: width, height: height), const Radius.circular(1.2)), paint); }
      canvas.restore();
    }
  }
  @override
  bool shouldRepaint(_ForlanConfetti old) => old.progress != progress || old.reducedMotion != reducedMotion;
}
class _ForlanSuccessSeal extends CustomPainter {
  _ForlanSuccessSeal(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), radius = size.shortestSide * .38;
    final seal = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(center, radius, Paint()..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF243D42), Color(0xFF263149)]).createShader(seal));
    canvas.drawCircle(center, radius + 6, Paint()..color = const Color(0xFF6BDBC1).withOpacity(.09)..style = PaintingStyle.stroke..strokeWidth = 8);
    canvas.drawCircle(center, radius + 6, Paint()..color = const Color(0xFF6BDBC1).withOpacity(.18)..style = PaintingStyle.stroke..strokeWidth = 1);
    final reveal = const Interval(.08, .5, curve: Curves.easeOutCubic).transform(progress);
    canvas.drawArc(seal.inflate(6), -math.pi / 2, math.pi * 2 * reveal, false, Paint()..color = const Color(0xFF6BDBC1)..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    final path = Path()..moveTo(center.dx - 14, center.dy)..lineTo(center.dx - 3, center.dy + 11)..lineTo(center.dx + 18, center.dy - 13);
    final metrics = path.computeMetrics().first;
    final check = const Interval(.2, .55, curve: Curves.easeOutCubic).transform(progress);
    canvas.drawPath(metrics.extractPath(0, metrics.length * check), Paint()..color = const Color(0xFF9DEBD8)..strokeWidth = 4.2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
  }
  @override
  bool shouldRepaint(_ForlanSuccessSeal old) => old.progress != progress;
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
  String? _error, _feedback;
  bool get _staff => _session.account?['role'] != 'customer';
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
    if (!_session.supportEnabled || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final data = await _session.api.get('/api/tickets/${widget.ticketId}', _session.token!);
      final history = _staff ? await _session.api.get('/api/tickets/${widget.ticketId}/history', _session.token!) : const [];
      if (!mounted) return;
      setState(() { _ticket = Map<String, dynamic>.from(data as Map); _history = history as List; });
      await _session.api.post('/api/tickets/${widget.ticketId}/read', {}, token: _session.token);
      await _session.refreshTickets();
    } on _SupportApiException catch (e) {
      if (!_staff && e.statusCode == 404) {
        await _session.refreshTickets();
        if (mounted) widget.onBack();
      } else if (mounted) { setState(() => _error = e.toString()); }
    } catch (e) { if (mounted) setState(() => _error = e.toString()); }
    finally { if (mounted) { setState(() => _busy = false); if (_queued) { _queued = false; _load(); } } }
  }
  Future<void> _action(String path, Map<String, dynamic> body, {bool patch = false, bool connectAfter = false}) async {
    if (_busy || _session.token == null) return;
    setState(() { _busy = true; _error = null; _feedback = null; });
    try {
      final result = patch ? await _session.api.patch('/api/tickets/${widget.ticketId}/$path', body, token: _session.token!) : await _session.api.post('/api/tickets/${widget.ticketId}/$path', body, token: _session.token);
      if (connectAfter && mounted) connect(context, result['device_id'] as String);
      if (path == 'messages') _message.clear();
      if (mounted) setState(() => _busy = false);
      await _load();
      if (mounted && path == 'assignment' && body['action'] == 'transfer') setState(() => _feedback = 'Bildirim gönderildi. Kaydın sorumluluğu sizde kalır.');
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
    people = people.where((p) => p['id'] != _session.account?['id']).toList();
    if (people.isEmpty) { setState(() => _error = 'Bildirim gönderebileceğiniz başka aktif teknisyen yok.'); return; }
    final note = TextEditingController();
    int? selected;
    final result = await showDialog<Map<String, dynamic>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, change) => AlertDialog(title: const Text('Teknisyene bildir'), content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Seçtiğiniz teknisyene özel bir bildirim ve not gönderilir. Bu kayıt sizde kalır; çalışmaya devam edebilirsiniz.', style: TextStyle(fontSize: 12)), const SizedBox(height: 14),
      DropdownButtonFormField<int>(value: selected, isExpanded: true, decoration: const InputDecoration(labelText: 'Teknisyen'), items: people.map((p) => DropdownMenuItem<int>(value: p['id'] as int, child: Text(p['display_name'] as String))).toList(), onChanged: (v) => change(() => selected = v)),
      const SizedBox(height: 12), TextField(controller: note, minLines: 3, maxLines: 5, maxLength: 10000, decoration: const InputDecoration(labelText: 'Teknisyene not', hintText: 'İlgilenmesini istediğiniz konuyu yazın…'), onChanged: (_) => change(() {})),
    ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')), FilledButton(onPressed: selected == null || note.text.trim().isEmpty ? null : () => Navigator.pop(ctx, {'action': 'transfer', 'technician_id': selected, 'note': note.text.trim()}), child: const Text('Bildirim gönder'))])));
    note.dispose(); if (result != null) await _action('assignment', result);
  }
  @override
  Widget build(BuildContext context) {
    final ticket = _ticket;
    if (ticket == null) return Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator());
    final own = ticket['assigned_to'] == null || ticket['assigned_to'] == _session.account?['id'] || _session.account?['role'] == 'admin';
    final closed = ticket['status'] == 'resolved' || ticket['status'] == 'closed';
    final messages = ticket['messages'] as List? ?? [];
    final notifications = ticket['technician_notifications'] as List? ?? [];
    final color = ticket['category'] == 'Sistem' ? const Color(0xFF58CDB4) : const Color(0xFFAD90F2);
    final assigned = _session.tickets.where((t) => t['id'] == widget.ticketId).map((t) => t['assigned_name']).firstOrNull;
    final canMessage = !closed && (!_staff || own);
    return Padding(padding: const EdgeInsets.fromLTRB(10, 5, 10, 10), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [IconButton(onPressed: widget.onBack, tooltip: 'Kayıtlara dön', icon: const Icon(Icons.arrow_back, size: 20)), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ticket['title']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2), Text('${ticket['category']} · #${ticket['id']} · ${assigned ?? 'Teknisyen bekleniyor'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 11)),
      ])), if (_busy) const Padding(padding: EdgeInsets.symmetric(horizontal: 7), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
        if (_staff) IconButton(onPressed: () => setState(() => _historyVisible = !_historyVisible), tooltip: _historyVisible ? 'Konuşmaya dön' : 'İşlem geçmişi', icon: Icon(_historyVisible ? Icons.chat_bubble_outline : Icons.history, size: 20)),
      ]),
      if (_staff && !closed) Row(children: [
        FilledButton.icon(onPressed: _busy || !own || ticket['device_id'] == null ? null : () => _action('connection-request', {}, connectAfter: true), icon: const Icon(Icons.desktop_windows, size: 16), label: const Text('Bağlan')),
        const SizedBox(width: 6),
        if (ticket['assigned_to'] == null) TextButton(onPressed: _busy ? null : () => _action('assignment', {'action': 'claim'}), child: const Text('Üstlen')),
        if (ticket['assigned_to'] != null && own) TextButton.icon(onPressed: _busy ? null : _transfer, icon: const Icon(Icons.notifications_active_outlined, size: 16), label: const Text('Teknisyene bildir', style: TextStyle(fontSize: 12))),
        const Spacer(),
        PopupMenuButton<String>(tooltip: 'Kayıt işlemleri', enabled: !_busy && own, onSelected: (action) {
          if (action == 'release') _action('assignment', {'action': 'release'});
          if (action == 'resolved') _action('status', {'status': 'resolved'}, patch: true);
          if (action == 'waiting_customer') _action('status', {'status': 'waiting_customer'}, patch: true);
          if (action == 'closed') _cancel();
        }, itemBuilder: (_) => [
          const PopupMenuItem(value: 'resolved', child: Row(children: [Icon(Icons.task_alt, size: 18, color: Color(0xFF58CDB4)), SizedBox(width: 8), Text('Tamamlandı') ])),
          const PopupMenuItem(value: 'waiting_customer', child: Text('Müşteri yanıtını bekle')),
          if (ticket['assigned_to'] != null) const PopupMenuItem(value: 'release', child: Text('Havuza bırak')),
          const PopupMenuItem(value: 'closed', child: Text('Not bırakarak iptal et', style: TextStyle(color: Color(0xFFFF8B96)))),
        ], icon: const Icon(Icons.more_horiz, size: 22)),
      ]),
      if (_staff && !own && !closed) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('Bu kayıt $assigned tarafından yürütülüyor.', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor))),
      if (!_staff) Padding(padding: const EdgeInsets.only(left: 5, bottom: 5), child: Text(ticket['status'] == 'waiting_customer' ? 'Teknisyeniniz yanıtınızı bekliyor.' : ticket['status'] == 'in_progress' ? 'Teknisyeniniz talebinizle ilgileniyor.' : 'Talebiniz teknisyen havuzuna iletildi.', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor))),
      if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFFF8B96))),
      if (_feedback != null) Text(_feedback!, style: const TextStyle(color: Color(0xFF6BDBC1), fontSize: 11)),
      Expanded(child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: _staff && _historyVisible ? _history.map<Widget>(_historyEntry).toList() : [
        Container(padding: const EdgeInsets.all(11), margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: color.withOpacity(.06), borderRadius: BorderRadius.circular(11), border: Border.all(color: color.withOpacity(.17))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Sorun açıklaması', style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700)), const SizedBox(height: 5), SelectableText(ticket['description']?.toString() ?? '', style: const TextStyle(fontSize: 12))])),
        if (_staff) for (final note in notifications) Container(padding: const EdgeInsets.all(11), margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: const Color(0xFFAD90F2).withOpacity(.12), borderRadius: BorderRadius.circular(11), border: Border.all(color: const Color(0xFFAD90F2).withOpacity(.3))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Size özel teknisyen notu · ${note['sender_name'] ?? ''}', style: const TextStyle(color: Color(0xFFC1A6FF), fontSize: 11, fontWeight: FontWeight.w700)), const SizedBox(height: 5), SelectableText(note['message']?.toString() ?? '', style: const TextStyle(fontSize: 12))])),
        ...messages.map<Widget>(_messageBubble),
      ])),
      if (!_historyVisible && !closed) Row(children: [Expanded(child: TextField(controller: _message, enabled: canMessage && !_busy, minLines: 1, maxLines: 2, maxLength: 10000, decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), hintText: canMessage ? 'Mesajınızı yazın…' : 'Kaydı yürüten teknisyen yanıtlayabilir.', counterText: ''))), const SizedBox(width: 6), IconButton.filled(onPressed: _busy || !canMessage ? null : () { if (_message.text.trim().isNotEmpty) _action('messages', {'message': _message.text.trim()}); }, tooltip: 'Mesajı gönder', icon: const Icon(Icons.arrow_upward, size: 20))]),
    ]));
  }
  Widget _messageBubble(dynamic message) {
    final mine = message['sender_id'] == _session.account?['id'];
    final created = DateTime.tryParse(message['created_at']?.toString() ?? '')?.toLocal();
    final stamp = created == null ? '' : '${created.day.toString().padLeft(2, '0')}.${created.month.toString().padLeft(2, '0')} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: FractionallySizedBox(widthFactor: .88, child: Container(padding: const EdgeInsets.all(11), margin: const EdgeInsets.only(bottom: 8), decoration: BoxDecoration(color: mine ? const Color(0xFF1E3445) : MyTheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: mine ? const Color(0xFF58CDB4).withOpacity(.2) : MyTheme.stroke)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(mine ? 'Siz' : message['sender_name']?.toString() ?? 'Teknisyen', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11))), const SizedBox(width: 5), Text(stamp, style: TextStyle(fontSize: 9, color: Theme.of(context).hintColor))]),
      const SizedBox(height: 5), SelectableText(message['message']?.toString() ?? '', style: const TextStyle(fontSize: 12)),
    ]))));
  }
  Widget _historyEntry(dynamic entry) {
    const actions = {'ticket_created': 'Kayıt oluşturuldu', 'ticket_status_changed': 'Kayıt durumu güncellendi', 'ticket_claim': 'Kayıt üstlenildi', 'ticket_release': 'Kayıt havuza bırakıldı', 'ticket_transfer': 'Kayıt devredildi', 'ticket_technician_notified': 'Teknisyene bildirim gönderildi', 'ticket_connection_requested': 'Bağlantı istendi', 'ticket_message_added': 'Mesaj gönderildi'};
    final details = entry['details'] as Map? ?? {};
    final note = details['note']?.toString();
    final status = details['status']?.toString();
    const states = {'open': 'Yeni', 'in_progress': 'İşlemde', 'waiting_customer': 'Müşteri yanıtı bekleniyor', 'resolved': 'Tamamlandı', 'closed': 'İptal edildi'};
    return ListTile(dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4), leading: const Icon(Icons.radio_button_checked, size: 14, color: Color(0xFFAD90F2)), title: Text(actions[entry['action']] ?? entry['action']?.toString() ?? '', style: const TextStyle(fontSize: 12)), subtitle: Text([entry['actor_name']?.toString() ?? '', if (status != null) states[status] ?? status, if (note != null && note.isNotEmpty) note].where((s) => s.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 11)));
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
    final active = deadline != null && deadline.isAfter(DateTime.now());
    if (session.privileged && !active) return const SizedBox.shrink();
    final remaining = active ? deadline.difference(DateTime.now()).inSeconds : 0;
    final limit = session.transferLimit > 0 ? session.transferLimit : 30 * 1024 * 1024;
    final usage = (session.transferUsed / (1024 * 1024)).toStringAsFixed(session.transferUsed == 0 ? 0 : 1);
    final text = active
        ? session.freeConnectionExpires == null
            ? 'Yeni bağlantı için bekleme: ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}'
            : 'Kalan süre ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')} · Dosya gönderimi: $usage / ${limit ~/ (1024 * 1024)} MB'
        : 'Lisanssız kullanım: 5 dk bağlantı · 1 dk ara · Oturumda toplam 30 MB dosya gönderimi';
    return Container(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3), decoration: BoxDecoration(color: const Color(0xFFF0C674).withOpacity(.06), borderRadius: BorderRadius.circular(9)), child: Row(children: [
      const Icon(Icons.info_outline, size: 15, color: Color(0xFFF0C674)), const SizedBox(width: 7),
      Expanded(child: Text(text, style: const TextStyle(color: Color(0xFFF0C674), fontWeight: FontWeight.w500, fontSize: 11))),
      TextButton(onPressed: () => showForlanLicenseDialog(context), style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6), tapTargetSize: MaterialTapTargetSize.shrinkWrap), child: const Text('Lisans', style: TextStyle(fontSize: 11))),
    ]));
  });
}
