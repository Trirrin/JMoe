import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import 'login_page.dart';
import 'profile_edit_page.dart';

/// 账号管理页：已登录显示账号信息 + 资产 + 签到 + 套餐（只读）；
/// 未登录引导去登录。
///
/// 说明：本页**不实现任何支付流程**。套餐列表仅作展示，
/// 点击后跳转官方网页，付款由官方站点完成。
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

  /// 解析后的签到状态（今天是否已签、连续天数、本月日历）
  DailyStatus? _dailyStatus;
  List<Map<String, dynamic>> _plans = const [];
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (AppState.instance.loggedIn) _loadAssets();
  }

  /// 从已登录会话（AppState.member）读取资产。
  ///
  /// 说明：官方 `coin` 接口即使携带 JWT 也返回「請先登入會員」，
  /// 实测资产字段随 `login` 响应一起返回，因此这里以本地会话为准。
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

    // 会员：ad_free 为 true 即已去广告；ad_free_before 是到期时间
    _vip = (m['ad_free'] == true || '${m['ad_free']}' == '1');
    final before = '${m['ad_free_before'] ?? ''}';
    _vipExpire = (before.isEmpty || before.startsWith('0000'))
        ? null
        : before;

    // 签到信息 + 套餐（只读）
    final uid = '${m['uid'] ?? ''}';
    final results = await Future.wait([
      JmService.instance.fetchPlans(),
      if (uid.isNotEmpty) JmService.instance.fetchDaily(uid),
    ]);
    if (!mounted) return;
    setState(() {
      _dailyStatus = JmService.parseDaily(_daily);
      _plans = results[0] as List<Map<String, dynamic>>;
      _daily = results.length > 1 ? results[1] as Map<String, dynamic>? : null;
      _assetsLoading = false;
    });
  }

  Future<void> _checkIn() async {
    final d = _daily;
    if (d == null || _checking) return;
    // 已签到：不再发请求，直接提示
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
    // 默认占位图（nopic-Male.gif / nopic-Female.gif）不当作头像，
    // 直接回落到人形图标，避免显示成一张灰色小图。
    if (p.startsWith('nopic')) return null;
    if (p.startsWith('http')) return p;
    final host = JmService.instance.imgHost ?? '';
    // 服务端 photo 是纯文件名（如 xxxxx.jpg），需拼 /media/user/
    return '$host/media/user/$p';
  }

  /// 跳转官方网页（不做站内支付）。
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
        // 扣除状态栏高度：刷新图标从状态栏下方出现
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

            // ---- 资产卡片 ----
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

            // ---- 签到 ----
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
                    // 连续天数提示
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
                        // 已签到 → 禁用
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
                    // 本月签到日历
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
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: _dailyStatus!.days.map((d) {
                          final isToday = d.date ==
                              DateTime.now().day.toString().padLeft(2, '0');
                          return Container(
                            width: 30,
                            height: 30,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: d.signed
                                  ? scheme.primary
                                  : scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                              border: isToday
                                  ? Border.all(
                                      color: scheme.primary, width: 1.5)
                                  : null,
                            ),
                            child: Text(
                              '${int.tryParse(d.date) ?? d.date}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: d.signed
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            // ---- 套餐（只读） ----
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
                    leading: const Icon(Icons.favorite_border),
                    title: Text(L.t('cloudFavorites')),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(L.t('history')),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.of(context).pop(),
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
    final price = '${p['price'] ?? ''}';
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
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '¥$price',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
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
