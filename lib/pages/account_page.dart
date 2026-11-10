import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import 'change_password_page.dart';
import 'login_page.dart';
import 'my_comments_page.dart';
import 'profile_edit_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _busy = false;
  bool _assetsLoading = true;

  num? _coin;
  num? _exp;
  num? _level;
  String? _levelName;
  num? _nextExp;
  num? _expPercent;
  num? _favoritesMax;
  String? _charge;
  String? _vipExpire;
  bool _vip = false;

  Map<String, dynamic>? _daily;

  DailyStatus? _dailyStatus;
  List<Map<String, dynamic>> _plans = const [];
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (AppState.instance.loggedIn) _loadAssets();
  }

  Future<void> _loadAssets() async {
    setState(() => _assetsLoading = true);
    final m = AppState.instance.member ?? const <String, dynamic>{};

    num? asNum(dynamic v) => v == null ? null : num.tryParse('$v');

    _coin = asNum(m['coin']);
    _exp = asNum(m['exp']);
    _level = asNum(m['level']);
    _levelName = '${m['level_name'] ?? ''}'.isEmpty
        ? null
        : '${m['level_name']}';
    _nextExp = asNum(m['nextLevelExp']) ?? asNum(m['next_level_exp']);
    _expPercent = asNum(m['expPercent']) ?? asNum(m['exp_percent']);
    _favoritesMax = asNum(m['album_favorites_max']);
    _charge = '${m['charge'] ?? ''}'.isEmpty ? null : '${m['charge']}';

    _vip = (m['ad_free'] == true || '${m['ad_free']}' == '1');
    final before = '${m['ad_free_before'] ?? ''}';
    _vipExpire = (before.isEmpty || before.startsWith('0000'))
        ? null
        : before;

    final uid = '${m['uid'] ?? ''}';
    final results = await Future.wait([
      JmService.instance.fetchPlans(),
      if (uid.isNotEmpty) JmService.instance.fetchDaily(uid),
    ]);
    if (!mounted) return;
    setState(() {
      _daily = results.length > 1 ? results[1] as Map<String, dynamic>? : null;
      _dailyStatus = JmService.parseDaily(_daily);
      _plans = results[0] as List<Map<String, dynamic>>;
      _assetsLoading = false;
    });
  }

  Future<void> _checkIn() async {
    final d = _daily;
    if (d == null || _checking) return;
    if (_dailyStatus?.todaySigned == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.t('alreadyCheckedIn')),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return;
    }
    final dailyId = '${d['daily_id'] ?? ''}';
    final uid = '${AppState.instance.member?['uid'] ?? ''}';
    if (dailyId.isEmpty || uid.isEmpty) return;
    setState(() => _checking = true);
    final ok = await JmService.instance.dailyCheck(
      userId: uid,
      dailyId: dailyId,
    );
    if (!mounted) return;
    setState(() => _checking = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? L.t('checkInSuccess') : L.t('checkInFailed')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ),
    );
    if (ok) await _loadAssets();
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      await JmService.instance.logout();
      await AppState.instance.saveSession(null, null);
      JmApi.instance.jwtToken = null;
      JmApi.instance.cookieValue = null;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
  }

  String? get _avatar {
    final p = AppState.instance.avatarPath;
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('nopic')) return null;
    if (p.startsWith('http')) return p;
    return '${JmApi.instance.baseUrl}media/user/$p';
  }

  Future<void> _openOfficial() async {
    final uri = Uri.parse('https://18comic.vip');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppState.instance;

    if (!state.loggedIn) {
      return Scaffold(
        appBar: AppBar(title: Text(L.t('accountManage'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_circle_outlined,
                    size: 72, color: scheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                  L.t('notLoggedIn'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  L.t('settingsAccountGuest'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                    );
                    if (mounted) {
                      setState(() {});
                      if (AppState.instance.loggedIn) _loadAssets();
                    }
                  },
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: Text(L.t('login')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(L.t('accountManage'))),
      body: RefreshIndicator(
        onRefresh: _loadAssets,
        edgeOffset: MediaQuery.of(context).padding.top,
        child: ListView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Center(
              child: CircleAvatar(
                radius: 38,
                backgroundColor: scheme.primaryContainer,
                backgroundImage:
                    _avatar == null ? null : NetworkImage(_avatar!),
                child: _avatar == null
                    ? Icon(Icons.person,
                        size: 38, color: scheme.onPrimaryContainer)
                    : null,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                state.userName.isEmpty ? L.t('guest') : state.userName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (_levelName != null || _level != null) ...[
              const SizedBox(height: 4),
              Center(
                child: Text(
                  '${_levelName ?? ''}${_level != null ? ' Lv.${_level!.round()}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),

            if (_assetsLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: _assetCard(
                      theme,
                      icon: Icons.monetization_on_rounded,
                      label: L.t('jcoin'),
                      value: _coin == null ? '--' : _fmtNum(_coin!),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _assetCard(
                      theme,
                      icon: Icons.auto_awesome_rounded,
                      label: L.t('experience'),
                      value: _exp == null ? '--' : _fmtNum(_exp!),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _assetCard(
                      theme,
                      icon: Icons.card_membership_rounded,
                      label: L.t('membership'),
                      value: _vip ? L.t('active') : L.t('inactive'),
                      highlight: _vip,
                    ),
                  ),
                ],
              ),

            if (_vipExpire != null) ...[
              const SizedBox(height: 8),
              Text(
                L.tp('vipExpireAt', {'t': _vipExpire!}),
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
            if (_expPercent != null || _nextExp != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_expPercent ?? 0) / 100,
                  minHeight: 4,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                L.tp('expProgress', {
                  'cur': _exp == null ? '-' : _exp!.round(),
                  'next': _nextExp == null ? '-' : _nextExp!.round(),
                }),
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            if (_favoritesMax != null || _charge != null) ...[
              const SizedBox(height: 6),
              Text(
                [
                  if (_favoritesMax != null)
                    L.tp('favoritesLimit', {'n': _favoritesMax!.round()}),
                  if (_charge != null) L.tp('chargeProgress', {'v': _charge!}),
                ].join('  ·  '),
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],

            if (_daily != null) ...[
              const SizedBox(height: 18),
              _sectionTitle(theme, L.t('dailyCheckIn')),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ('${_daily!['event_name'] ?? ''}'.isNotEmpty)
                      Text(
                        '${_daily!['event_name']}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      L.tp('dailyReward', {
                        'd3': '${_daily!['three_days_coin'] ?? '-'}',
                        'd7': '${_daily!['seven_days_coin'] ?? '-'}',
                      }),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if ((_dailyStatus?.streakDays ?? 0) > 0 ||
                        (_dailyStatus?.signedCount ?? 0) > 0) ...[
                      Text(
                        L.tp('dailyStreak', {
                          'n': '${_dailyStatus?.streakDays ?? 0}',
                          'c': '${_dailyStatus?.signedCount ?? 0}',
                        }),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _checking ||
                                (_dailyStatus?.todaySigned == true)
                            ? null
                            : _checkIn,
                        icon: _checking
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _dailyStatus?.todaySigned == true
                                    ? Icons.check_circle_rounded
                                    : Icons.event_available_rounded,
                                size: 18,
                              ),
                        label: Text(
                          _dailyStatus?.todaySigned == true
                              ? L.t('checkedInToday')
                              : L.t('checkIn'),
                        ),
                      ),
                    ),
                    if ((_dailyStatus?.days.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 14),
                      Text(
                        L.t('thisMonthCheckIn'),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildCalendar(theme),
                    ],
                  ],
                ),
              ),
            ],

            if (_plans.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionTitle(theme, L.t('membershipPlans')),
              const SizedBox(height: 4),
              Text(
                L.t('plansReadonlyTip'),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 8),
              ..._plans.map((p) => _planTile(theme, p)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openOfficial,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(L.t('openOfficialSite')),
                ),
              ),
            ],

            const SizedBox(height: 22),
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(L.t('myComments')),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const MyCommentsPage(),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(L.t('editProfile')),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () async {
                      final changed = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => const ProfileEditPage(),
                        ),
                      );
                      if (changed == true && mounted) setState(() {});
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_outline_rounded),
                    title: Text(L.t('changePassword')),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ChangePasswordPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            OutlinedButton.icon(
              onPressed: _busy ? null : _logout,
              icon: const Icon(Icons.logout_rounded, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              label: Text(L.t('logout')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final days = _dailyStatus?.days ?? const <DailyDay>[];
    if (days.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    int colOf(DateTime d) => d.weekday % 7;
    final firstCol = colOf(DateTime(now.year, now.month, 1));
    final todayDay = now.day;

    const cols = 7;
    final cells = <Widget>[
      for (final w in const ['日', '一', '二', '三', '四', '五', '六'])
        SizedBox(
          height: 20,
          child: Center(
            child: Text(
              w,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      for (var i = 0; i < firstCol; i++) const SizedBox(height: 34),
      for (final d in days)
        _calendarCell(theme, d, int.tryParse(d.date) ?? 0, todayDay),
      for (var i = 0; i < (cols - (firstCol + days.length) % cols) % cols; i++)
        const SizedBox(height: 34),
    ];

    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      childAspectRatio: 1,
      children: cells,
    );
  }

  Widget _calendarCell(ThemeData theme, DailyDay d, int day, int today) {
    final scheme = theme.colorScheme;
    final isToday = day == today;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: d.signed ? scheme.primary : scheme.surfaceContainerHighest,
        border: isToday
            ? Border.all(color: scheme.primary, width: 1.5)
            : null,
      ),
      child: Text(
        day <= 0 ? '' : '$day',
        style: TextStyle(
          fontSize: 11,
          fontWeight: isToday || d.signed
              ? FontWeight.w700
              : FontWeight.w500,
          color: d.signed ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _assetCard(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    bool highlight = false,
  }) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon,
              size: 18,
              color: highlight ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _planTile(ThemeData theme, Map<String, dynamic> p) {
    final scheme = theme.colorScheme;
    final name = '${p['name'] ?? ''}';
    final months = int.tryParse('${p['months'] ?? ''}') ?? 0;
    final perMonth = '${p['price'] ?? ''}';
    final total = '${p['total'] ?? p['original'] ?? ''}';
    final days = '${p['days'] ?? ''}';
    final exp = '${p['exp'] ?? ''}';
    final features =
        (p['features'] as List?)?.whereType<Object>().map((e) => '$e').toList() ??
            const <String>[];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (months > 1 && perMonth.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            L.tp('planPerMonth', {'p': perMonth}),
                            style: TextStyle(
                              fontSize: 10.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '¥$total',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                    if (months > 0)
                      Text(
                        L.tp('planMonthsN', {'n': '$months'}),
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              L.tp('planMeta', {'days': days, 'exp': exp}),
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            if (features.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...features.map(
                (f) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_circle_outline_rounded,
                          size: 13, color: scheme.primary),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          f,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtNum(num v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return '${v.round()}';
  }
}
