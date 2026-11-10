import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/host_store.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';

/// 线路管理页：API 线路 + 图片线路统一管理，支持测速、切换、显示延迟。
class HostManagePage extends StatefulWidget {
  const HostManagePage({super.key});

  @override
  State<HostManagePage> createState() => _HostManagePageState();
}

/// 单条线路状态。
class _HostItem {
  final String host;
  final String label;
  final int order; // 固定编号，永不随测速变化
  int? latency;

  _HostItem({
    required this.host,
    required this.label,
    required this.order,
  });

  bool get ok => latency != null;
}

class _HostManagePageState extends State<HostManagePage> {
  final _api = JmApi.instance;
  final _items = <_HostItem>[];
  final _imgItems = <_HostItem>[];

  bool _testing = false;
  bool _applying = false;
  bool _loading = true;
  /// 当前已生效的线路
  String _activeHost = '';

  /// 已选中但尚未应用的线路（测速后自动指向最优）
  String _pendingHost = '';

  /// 已选中但尚未应用的图片线路
  String _pendingImgHost = '';

  /// 当前生效的图片线路
  String _activeImgHost = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    if (_api.hosts.isEmpty) {
      await _api.loadHostList();
    }
    if (!mounted) return;
    setState(() {
      _activeHost = _api.host;
      if (_pendingHost.isEmpty) _pendingHost = _api.host;
      _activeImgHost = JmService.instance.imgHost ?? '';
      if (_pendingImgHost.isEmpty) _pendingImgHost = _activeImgHost;
      // 合并自定义线路：用户添加的要出现在这个列表里
      final merged = HostStore.instance.mergeWith(_api.hosts);
      _items
        ..clear()
        ..addAll([
          for (var i = 0; i < merged.length; i++)
            _HostItem(
              host: merged[i][0],
              label: JmProtocol.localizeHostLabel(
                merged[i].length > 1 ? merged[i][1] : merged[i][0],
                AppState.instance.uiLang,
              ),
              order: i + 1,
            ),
        ]);
      // 图片线路：来自 imgHostCandidates
      _imgItems
        ..clear()
        ..addAll([
          for (var i = 0; i < JmService.instance.imgHostCandidates.length; i++)
            _HostItem(
              host: JmService.instance.imgHostCandidates[i],
              label: 'IMG ${i + 1}',
              order: i + 1,
            ),
        ]);
      _loading = false;
    });
    // 进入即自动测速一次
    _test(all: true);
  }

  Future<void> _test({bool all = false}) async {
    if (_testing) return;
    setState(() => _testing = true);
    await Future.wait([
      // API 线路测速
      for (final it in _items)
        () async {
          final ms = await _api.measure(it.host);
          if (!mounted) return;
          setState(() => it.latency = ms);
        }(),
      // 图片线路测速
      for (final it in _imgItems)
        () async {
          final ms = await JmService.instance.measureImgHost(it.host);
          if (!mounted) return;
          setState(() => it.latency = ms);
        }(),
    ]);
    if (!mounted) return;
    setState(() {
      _testing = false;
      // 测速完成后自动选中「最优线路」，但需用户点应用才生效
      final okItems = _items.where((e) => e.ok).toList()
        ..sort((a, b) => (a.latency ?? 99999).compareTo(b.latency ?? 99999));
      if (okItems.isNotEmpty) _pendingHost = okItems.first.host;
    });
  }

  /// 是否存在未应用的变更（决定「应用」按钮是否可用）。
  bool get _hasPendingChange =>
      _pendingHost.isNotEmpty && _pendingHost != _activeHost ||
      _pendingImgHost.isNotEmpty &&
          _pendingImgHost != _activeImgHost;

  /// 点击线路：只改变选中项，不立即切换。
  void _select(_HostItem it) {
    if (!it.ok) {
      _toast(L.tp('hostUnavailable', {'host': it.host}));
      return;
    }
    setState(() => _pendingHost = it.host);
  }

  /// 应用选中的线路（底部按钮触发）：同时应用 API 与图片线路。
  Future<void> _apply() async {
    if (!_hasPendingChange) {
      _toast(L.t('hostAlreadyActive'));
      return;
    }
    setState(() => _applying = true);

    var ok = true;

    // 1) API 线路变更
    if (_pendingHost.isNotEmpty && _pendingHost != _activeHost) {
      final switched = await _api.switchHost(_pendingHost);
      if (!mounted) return;
      if (switched) {
        await AppState.instance.setApiHost(_pendingHost);
        try {
          await JmService.instance.loadSettings(
            imgShunt: AppState.instance.imageShunt,
          );
        } catch (_) {}
        _activeHost = _pendingHost;
      } else {
        ok = false;
        _toast(L.tp('hostUnavailable', {'host': _pendingHost}));
      }
    }

    // 2) 图片线路变更
    if (_pendingImgHost.isNotEmpty && _pendingImgHost != _activeImgHost) {
      JmService.instance.setImgHost(_pendingImgHost);
      await AppState.instance.setImgHost(_pendingImgHost);
      _activeImgHost = _pendingImgHost;
    }

    if (!mounted) return;
    setState(() => _applying = false);

    if (ok) {
      _toast(L.t('hostApplied'));
    }
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  /// 添加自定义线路：输入主机名（可带 https://，会自动去掉）。
  Future<void> _showAddHostDialog() async {
    final hostCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('addCustomHost')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: L.t('hostAddress'),
                hintText: 'www.example.com',
                border: const OutlineInputBorder(),
                helperText: L.t('hostAddressHint'),
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelCtrl,
              decoration: InputDecoration(
                labelText: L.t('hostLabelOptional'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('add')),
          ),
        ],
      ),
    );
    final host = hostCtrl.text;
    final label = labelCtrl.text;
    hostCtrl.dispose();
    labelCtrl.dispose();
    if (ok != true || host.trim().isEmpty) return;
    await HostStore.instance.addCustom(
      CustomHost(host: host, label: label, at: 0),
    );
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('hostManage')),
        actions: [
          IconButton(
            tooltip: L.t('retest'),
            onPressed: _testing || _loading ? null : () => _test(),
            icon: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                // ---- 跳过启动页（独立开关，不绑定具体线路）----
                //
                // 开启后启动时直接用「上次进入所用的线路」连接，
                // 连不通会自动回落到启动页。所以不需要再单独「固定线路」。
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SwitchListTile(
                    dense: true,
                    secondary:
                        const Icon(Icons.fast_forward_rounded, size: 20),
                    title: Text(
                      L.t('skipStartupPage'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      L.t('skipStartupPageDesc'),
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    value: HostStore.instance.skipStartup,
                    onChanged: (v) async {
                      await HostStore.instance.setSkipStartup(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  L.t('apiLine'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  L.t('hostManageApiDesc'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                ..._items.map((it) => _hostTile(theme, it)),
                const SizedBox(height: 8),
                // 添加自定义线路
                OutlinedButton.icon(
                  onPressed: _showAddHostDialog,
                  icon: const Icon(Icons.add_link_rounded, size: 18),
                  label: Text(L.t('addCustomHost')),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                  ),
                ),
                // 已添加的自定义线路（可删除）
                if (HostStore.instance.customHosts.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      L.tp('customHostsN', {
                        'n': '${HostStore.instance.customHosts.length}',
                      }),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final c in HostStore.instance.customHosts)
                    Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      elevation: 0,
                      color: scheme.surfaceContainerLow,
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.link_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        title: Text(
                          c.host,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        subtitle: c.label.isEmpty
                            ? null
                            : Text(
                                c.label,
                                style: const TextStyle(fontSize: 10.5),
                              ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: scheme.error,
                          ),
                          onPressed: () async {
                            await HostStore.instance.removeCustom(c.host);
                            if (mounted) _load();
                          },
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 22),
                Text(
                  L.t('imageLine'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  L.t('hostManageImgDesc'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                ..._imgItems.map((it) => _imgTile(theme, it)),
                const SizedBox(height: 8),
              ],
                  ),
                ),
                // 底部：应用按钮
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: (_applying || !_hasPendingChange)
                            ? null
                            : _apply,
                        icon: _applying
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check_rounded, size: 18),
                        label: Text(L.t('applyHost')),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _hostTile(ThemeData theme, _HostItem it) {
    final scheme = theme.colorScheme;
    final active = _pendingHost == it.host;
    final isCurrent = _activeHost == it.host;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.55)
          : scheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _select(it),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // 固定编号（不随测速重排）
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? scheme.primary : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${it.order}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      it.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: active ? scheme.onPrimaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      it.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _latencyBadge(scheme, it),
              if (isCurrent) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    L.t('hostCurrent'),
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ],
              if (active) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_circle_rounded,
                    size: 18, color: scheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _imgTile(ThemeData theme, _HostItem it) {
    final scheme = theme.colorScheme;
    // 选中态看 pending，生效态看 active —— 与 API 线路一致
    final active = _pendingImgHost == it.host;
    final isCurrent = _activeImgHost == it.host;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.55)
          : scheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (!it.ok) {
            _toast(L.tp('hostUnavailable', {'host': it.host}));
            return;
          }
          // 只改选中项，等用户点「应用」才真正生效
          setState(() => _pendingImgHost = it.host);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${it.order}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  it.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? scheme.onPrimaryContainer : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _latencyBadge(scheme, it),
              if (isCurrent) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    L.t('hostCurrent'),
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ],
              if (active) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_circle_rounded,
                    size: 18, color: scheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _latencyBadge(ColorScheme scheme, _HostItem it) {
    if (_testing && it.latency == null) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    }
    if (!it.ok) {
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
    final ms = it.latency!;
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
