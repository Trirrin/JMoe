import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/host_store.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../widgets/app_toast.dart';

/// 启动线路页：并发测速 → 展示结果 → 用户可自行选线进入。
///
/// 规则：
///  * 测速完成后开始 10 秒倒计时；**用户一旦手动选线即取消计时**
///  * 只有测速成功的线路可选（失败项不可点击）
///  * 全部失败时禁止进入，提示用户检查网络并重试
///  * 支持「重新测速」
class StartupHostPage extends StatefulWidget {
  final VoidCallback onReady;

  const StartupHostPage({super.key, required this.onReady});

  @override
  State<StartupHostPage> createState() => _StartupHostPageState();
}

class _HostResult {
  final String host;
  final String label;
  final int? latency;

  /// 线路固定编号（1 起），来自线路表的原始顺序，**永不随测速结果改变**。
  final int order;

  /// 是否为图片源（图片源与 API 线路分两组展示）
  final bool isImage;

  _HostResult(this.host, this.label, this.latency, this.order,
      {this.isImage = false});

  bool get ok => latency != null;
}

class _StartupHostPageState extends State<StartupHostPage> {
  final List<_HostResult> _results = [];

  /// 图片源测速结果（单独一组，与 API 线路并列展示）
  final List<_HostResult> _imgResults = [];

  /// 选中的图片源（默认第一个）
  String? _selectedImg;

  /// 最快的图片源（测速完成后计算，用于打「最快」标记）
  String? _bestImg;

  bool _testing = true;
  String? _selected;
  String? _best;

  Timer? _countdown;
  int _secondsLeft = 3;
  bool _userInteracted = false;
  bool _entering = false;

  bool get _anyOk => _results.any((r) => r.ok);

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// 固定线路快进：若用户开启了「跳过启动页」，
  /// 直接用**上次进入所用的线路**连接并进入主界面。
  ///
  /// 设计要点（按用户要求）：
  ///  * 「跳过启动页」是**独立开关**，不绑定某条具体线路
  ///  * 跳过后使用「最后一次进入的线路」（lastHost），没有则用 apiHost
  ///  * 该线路连不通时**回落到正常启动页**，避免用户被死线路卡住
  Future<bool> _tryPinnedShortcut() async {
    if (!HostStore.instance.skipStartup) return false;
    final api = JmApi.instance;
    api.lang = AppState.instance.lang;
    final preferred =
        AppState.instance.apiHost.isNotEmpty
            ? AppState.instance.apiHost
            : (AppState.instance.lastHost ?? '');
    if (preferred.isEmpty) return false;
    await api.loadHostList();
    if (!mounted) return false;
    // 确保候选表里有这条线路（可能是用户自定义的）
    if (!api.hosts.any((h) => h[0] == preferred)) {
      api.hosts = [
        ...api.hosts,
        [preferred, preferred],
      ];
    }
    // 轻量探活：能通就直接进，失败则回落到正常启动页
    final ms = await api.measure(preferred);
    if (!mounted) return false;
    if (ms == null) {
      AppToast.show(
        context,
        L.t('pinnedHostUnreachable'),
        icon: Icons.wifi_off_rounded,
        accent: Theme.of(context).colorScheme.error,
      );
      return false;
    }
    await api.switchHostQuiet(preferred);
    await AppState.instance.setLastHost(preferred);
    if (!mounted) return false;
    widget.onReady();
    return true;
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _countdown?.cancel();
    setState(() {
      _testing = true;
      _results.clear();
      _imgResults.clear();
      _selected = null;
      _selectedImg = null;
      _best = null;
      _userInteracted = false;
      _secondsLeft = 3;
    });

    // 开了「跳过启动页」→ 直接用上次的线路进（失败会回落到正常流程）
    if (await _tryPinnedShortcut()) return;
    if (!mounted) return;

    final api = JmApi.instance;
    api.lang = AppState.instance.lang;

    await api.loadHostList();
    if (!mounted) return;

    // 合并自定义线路：用户添加的线路要出现在这里，
    // 否则「启动时也能看到」这个诉求就不成立。
    final hosts = HostStore.instance.mergeWith(api.hosts);
    setState(() {
      for (var idx = 0; idx < hosts.length; idx++) {
        final h = hosts[idx];
        final raw = h.length > 1 ? h[1] : h[0];
        _results.add(_HostResult(
          h[0],
          JmProtocol.localizeHostLabel(raw, AppState.instance.uiLang),
          null,
          idx + 1,
        ));
      }
      // 图片源：与 API 线路并列测速。
      // 默认选中**第一个**（按用户要求），之后测速完成也不改选，
      // 免得用户刚想选就被自动切换打乱。
      final imgHosts = JmService.instance.imgHostCandidates;
      for (var idx = 0; idx < imgHosts.length; idx++) {
        _imgResults.add(_HostResult(
          imgHosts[idx],
          'IMG ${idx + 1}',
          null,
          idx + 1,
          isImage: true,
        ));
      }
      if (_imgResults.isNotEmpty) _selectedImg = _imgResults.first.host;
    });

    await Future.wait([
      // API 线路测速
      ...hosts.map((h) async {
        final ms = await api.measure(h[0]);
        if (!mounted) return;
        final raw = h.length > 1 ? h[1] : h[0];
        final label = JmProtocol.localizeHostLabel(
          raw,
          AppState.instance.uiLang,
        );
        setState(() {
          final i = _results.indexWhere((r) => r.host == h[0]);
          if (i >= 0) {
            final old = _results[i];
            _results[i] = _HostResult(old.host, label, ms, old.order);
          }
        });
      }),
      // 图片源测速
      ..._imgResults.map((r) async {
        final ms = await JmService.instance.measureImgHost(r.host);
        if (!mounted) return;
        setState(() {
          final i = _imgResults.indexWhere((e) => e.host == r.host);
          if (i >= 0) {
            final old = _imgResults[i];
            _imgResults[i] = _HostResult(
              old.host,
              old.label,
              ms,
              old.order,
              isImage: true,
            );
          }
        });
      }),
    ]);
    if (!mounted) return;

    setState(() {
      _testing = false;
      // API 线路：列表顺序保持原顺序（编号固定），只算最快项并选中
      _best = _anyOk
          ? (_results.where((r) => r.ok).toList()
                ..sort((a, b) =>
                    (a.latency ?? 99999).compareTo(b.latency ?? 99999)))
              .first
              .host
          : null;
      _selected = _best;
      // 图片线路：测速完成后**改选最快的**（默认先选第一个，测完再切换）。
      // 用户要求：「图片线路默认选第一个，测完速再选最快的」。
      final okImgs = _imgResults.where((r) => r.ok).toList()
        ..sort((a, b) =>
            (a.latency ?? 99999).compareTo(b.latency ?? 99999));
      if (okImgs.isNotEmpty) _selectedImg = okImgs.first.host;
      // 记录最快的图片源，用于给它打「最快」标记
      _bestImg = okImgs.isNotEmpty ? okImgs.first.host : null;
    });

    if (_best != null) {
      // 只选中，不切换：等用户点「应用」或倒计时结束再应用
      // 若用户关闭了「启动页自动进入」，则不启动倒计时
      if (AppState.instance.autoEnterStartup) {
        _startCountdown();
      } else {
        setState(() => _secondsLeft = -1);
      }
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    if (_userInteracted || !_anyOk) return;
    setState(() => _secondsLeft = 3);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _userInteracted) {
        timer.cancel();
        return;
      }
      final left = _secondsLeft - 1;
      setState(() => _secondsLeft = left);
      if (left <= 0) {
        timer.cancel();
        _enter();
      }
    });
  }

  Future<void> _enter() async {
    _countdown?.cancel();
    if (_entering) return;
    if (!_anyOk) return;
    final host = _selected ?? _best;
    if (host == null) return;
    _entering = true;
    await JmApi.instance.switchHostQuiet(host);
    await AppState.instance.setLastHost(host);
    // 同时应用选中的图片源（默认第一个）
    final img = _selectedImg;
    if (img != null && img.isNotEmpty) {
      JmService.instance.setImgHost(img);
      await AppState.instance.setImgHost(img);
    }
    if (!mounted) return;
    widget.onReady();
  }

  /// 离线模式：跳过测速与线路选择，直接进入主界面。
  ///
  /// 只使用本地已下载 / 已缓存内容，不发起任何网络请求。
  Future<void> _enterOffline() async {
    _countdown?.cancel();
    if (_entering) return;
    _entering = true;
    await AppState.instance.setOfflineMode(true);
    if (!mounted) return;
    widget.onReady();
  }

  /// 点击线路：只改变选中项，不立即应用（应用由底部按钮确认）。
  void _pick(String host) {
    final r = _results.firstWhere((e) => e.host == host);
    if (!r.ok) return; // 失败线路不可选
    setState(() {
      _selected = host;
      _userInteracted = true;
    });
    // 只停倒计时，**不中断测速**：其余线路继续在后台测
    _countdown?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final String statusText;
    if (_userInteracted) {
      // 已手选：若还在测速，说明「后台继续测速」
      statusText = _testing
          ? L.t('manualSelectedTesting')
          : L.t('manualSelected');
    } else if (_testing) {
      statusText = L.t('testingLine');
    } else if (!_anyOk) {
      statusText = L.t('allLinesFailed');
    } else if (_secondsLeft > 0) {
      // 倒计时已在下方按钮显示，这里不再重复
      statusText = L.t('autoSelecting');
    } else {
      statusText = L.t('entering');
    }

    final String enterLabel;
    if (_userInteracted) {
      // 手动选过：直接给「进入」，可立即点击
      enterLabel = L.t('applyAndEnter');
    } else if (_testing) {
      enterLabel = L.t('testing');
    } else if (!_anyOk) {
      enterLabel = L.t('allLinesFailed');
    } else if (_secondsLeft > 0) {
      enterLabel = L.tp('enterWithSec', {'sec': _secondsLeft});
    } else {
      enterLabel = L.t('applyAndEnter');
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'JMoe',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  // 重新测速
                  IconButton(
                    tooltip: L.t('retest'),
                    onPressed: _testing || _entering ? null : _start,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              if (_testing)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: const LinearProgressIndicator(minHeight: 3),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    // ---- API 线路 ----
                    for (var i = 0; i < _results.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildItem(theme, i),
                      ),
                    // ---- 图片源（并列测速，默认选第一个）----
                    if (_imgResults.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          L.t('imageLine'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      for (var i = 0; i < _imgResults.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _buildImgItem(theme, i),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // ---- 跳过启动页（独立开关）----
              InkWell(
                onTap: () async {
                  await HostStore.instance
                      .setSkipStartup(!HostStore.instance.skipStartup);
                  if (mounted) setState(() {});
                },
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        HostStore.instance.skipStartup
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 19,
                        color: HostStore.instance.skipStartup
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L.t('skipStartupPage'),
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              L.t('skipStartupPageDesc'),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  // 进入条件（按用户要求）：
                  //  * 用户手动选过 API 线路 → **立即可进**（不等图片源测速）
                  //  * 否则（自动流程）→ 必须**两个都测完**才能进，
                  //    这样图片源也能选到最快的那个
                  onPressed: _entering ||
                          _selected == null ||
                          (!_userInteracted && _testing)
                      ? null
                      : _enter,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  child: Text(enterLabel),
                ),
              ),
              const SizedBox(height: 8),
              // 离线模式：不联网，直接用已下载 / 已缓存的内容
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _entering ? null : _enterOffline,
                  icon: const Icon(Icons.cloud_off_rounded, size: 18),
                  label: Text(L.t('offlineMode')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图片源条目：与 API 线路同样的视觉，但选中态独立。
  Widget _buildImgItem(ThemeData theme, int i) {
    final scheme = theme.colorScheme;
    final r = _imgResults[i];
    final active = _selectedImg == r.host;
    final selectable = r.ok && !_entering;

    return Material(
      color: active ? scheme.primaryContainer : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: selectable
            ? () => setState(() => _selectedImg = r.host)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.image_outlined,
                  size: 15,
                  color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        r.host.replaceFirst('https://', ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color: active ? scheme.onPrimaryContainer : null,
                        ),
                      ),
                    ),
                    // 「最快」标记：图片源也标出最快的那个
                    if (_bestImg == r.host && !_testing) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          L.t('fastest'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _latencyBadge(scheme, r),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(ThemeData theme, int i) {
    final scheme = theme.colorScheme;
    final r = _results[i];
    final active = _selected == r.host;
    final isBest = _best == r.host && !_testing;
    // 测速进行中也允许选择「已出结果」的线路；
    // 这样用户不必等全部测完就能进入。
    final selectable = r.ok && !_entering;

    return Material(
      color: active
          ? scheme.primaryContainer
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: selectable ? () => _pick(r.host) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${r.order}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            r.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: active ? scheme.onPrimaryContainer : null,
                            ),
                          ),
                        ),
                        if (isBest) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              L.t('fastest'),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      r.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _latencyBadge(scheme, r),
            ],
          ),
        ),
      ),
    );
  }

  Widget _latencyBadge(ColorScheme scheme, _HostResult r) {
    if (_testing && r.latency == null) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    }
    if (!r.ok) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          L.t('failed'),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: scheme.onErrorContainer,
          ),
        ),
      );
    }
    final ms = r.latency!;
    final color = ms < 300
        ? const Color(0xFF4CAF50)
        : ms < 800
            ? const Color(0xFFFF9800)
            : const Color(0xFFF44336);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          '${ms}ms',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}
