import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/jm_protocol.dart';
import '../core/l10n.dart';

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

  _HostResult(this.host, this.label, this.latency, this.order);

  bool get ok => latency != null;
}

class _StartupHostPageState extends State<StartupHostPage> {
  final List<_HostResult> _results = [];
  bool _testing = true;
  String? _selected;
  String? _best;

  Timer? _countdown;
  int _secondsLeft = 10;
  bool _userInteracted = false;
  bool _entering = false;

  bool get _anyOk => _results.any((r) => r.ok);

  @override
  void initState() {
    super.initState();
    _start();
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
      _selected = null;
      _best = null;
      _userInteracted = false;
      _secondsLeft = 10;
    });

    final api = JmApi.instance;
    api.lang = AppState.instance.lang;

    await api.loadHostList();
    if (!mounted) return;

    final hosts = api.hosts;
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
    });

    await Future.wait(
      hosts.map((h) async {
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
    );
    if (!mounted) return;

    setState(() {
      _testing = false;
      // 列表顺序保持线路表原始顺序（编号固定），只计算最快项并选中它
      _best = _anyOk
          ? (_results.where((r) => r.ok).toList()
                ..sort((a, b) =>
                    (a.latency ?? 99999).compareTo(b.latency ?? 99999)))
              .first
              .host
          : null;
      _selected = _best;
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
    setState(() => _secondsLeft = 10);
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
                child: ListView.separated(
                  itemCount: _results.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _buildItem(theme, i),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  // 用户手动选过线路 → 立即可点（不等测速完成）；
                  // 否则等测速结束或倒计时结束。
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
