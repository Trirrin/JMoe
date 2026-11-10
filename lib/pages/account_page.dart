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
      // 顺序很重要：必须先写 _daily，再解析（早期写反了，
      // 导致 _dailyStatus 永远基于上一轮的 null 计算）
      _daily = results.length > 1 ? results[1] as Map<String, dynamic>? : null;
      _dailyStatus = JmService.parseDaily(_daily);
      _plans = results[0] as List<Map<String, dynamic>>;
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
    // 服务端 photo 是纯文件名（如 xxxxx.jpg），需拼 /media/user/。
    //
    // **必须用主站域名，不能用图片 CDN**：实测 cdn-msp*.jmapiproxy*.cc
    // 等图片 CDN 对 /media/user/ 返回 0 字节，头像永远加载不出来。
    return '${JmApi.instance.baseUrl}media/user/$p';
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
                      _buildCalendar(theme),
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
                  // 「云端收藏 / 历史」入口已移除：书架页已有同功能，
                  // 账号页重复摆一处只是噪音。改为「我的评论」。
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
                  // 修改密码与「编辑资料」同级：都是账号级操作，
                  // 不该埋在资料表单最底部
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

  /// 本月签到日历：按星期对齐的 7 列日历格（**周日在前**）。
  ///
  /// 原来的实现是「一串 30 个方块直接 Wrap」，既看不出星期，也容易
  /// 因为解析漏项而只剩几格。这里改成标准日历：空白占位对齐 1 号所在星期，
  /// 每格显示日号，已签到高亮、今日描边。
  ///
  /// 列顺序按「日 一 二 三 四 五 六」：服务端 `bonus` 标记落在每周的
  /// 周日 + 周一，周日排在首列时奖励节点正好首尾相邻，更符合直觉。
  Widget _buildCalendar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final days = _dailyStatus?.days ?? const <DailyDay>[];
    if (days.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    // DateTime.weekday：1=周一 … 7=周日。
    // 换成「周日在前」的列序号：周日 → 0，周一 → 1 … 周六 → 6
    int colOf(DateTime d) => d.weekday % 7;
    final firstCol = colOf(DateTime(now.year, now.month, 1));
    final todayDay = now.day;

    const cols = 7;
    final cells = <Widget>[
      // 星期表头（周日起）
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
      // 1 号之前的空位
      for (var i = 0; i < firstCol; i++) const SizedBox(height: 34),
      // 每一天
      for (final d in days)
        _calendarCell(theme, d, int.tryParse(d.date) ?? 0, todayDay),
      // 补足最后一行，保证网格对齐
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
    // 注意：服务端的 `bonus` 标记落在每月 01/07/08/14/15/21/22/28/29
    // （每周的周日 + 周一），本质是「3 天 / 7 天奖励节点」的周期刻度。
    // 早期版本在这里画了个小圆点，结果整列周日全是点，看着像 bug ——
    // 而且没有图例，用户无法理解。奖励规则标题里已经写明，这里不再画点。
    //
    // 形状用**正圆**（不是圆角方块）：日历日期用圆形是通行做法，
    // 圆角矩形在小尺寸下会显得像按钮而不是日期。
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
    // 官方字段语义（payment 接口实测）：
    //   months      套餐时长（1/3/6/12 个月）
    //   price       每月单价（如 6 个月 = 22.33）
    //   total       该套餐总价（如 6 个月 = 134）—— 这才是用户要付的钱
    //   original    原价（无折扣时等于 total）
    //   days / exp  有效天数 / 赠品经验
    // 早期把 price 当总价显示成「¥22.33」，看起来像每月价格，
    // 与「3/6/12 个月」的量级完全对不上。这里以 total 为准。
    final months = int.tryParse('${p['months'] ?? ''}') ?? 0;
    final perMonth = '${p['price'] ?? ''}';
    final total = '${p['total'] ?? p['original'] ?? ''}';
    final days = '${p['days'] ?? ''}';
    final exp = '${p['exp'] ?? ''}';
    final features =
        (p['features'] as List?)?.whereType<Object>().map((e) => '$e').toList() ??
            const <String>[];
    // 不显示「最热」角标、也不做选中态高亮 —— 纯只读列表，
    // 高亮反而让人以为「这个已被选中/已购买」。
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
                      // 换算成「每月多少钱」，方便横向比较不同时长
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
