import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/host_store.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../widgets/app_toast.dart';

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

  final int order;

  final bool isImage;

  _HostResult(this.host, this.label, this.latency, this.order,
      {this.isImage = false});

  bool get ok => latency != null;
}

class _StartupHostPageState extends State<StartupHostPage> {
  final List<_HostResult> _results = [];

  final List<_HostResult> _imgResults = [];

  String? _selectedImg;

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
    if (!api.hosts.any((h) => h[0] == preferred)) {
      api.hosts = [
        ...api.hosts,
        [preferred, preferred],
      ];
    }
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

    if (await _tryPinnedShortcut()) return;
    if (!mounted) return;

    final api = JmApi.instance;
    api.lang = AppState.instance.lang;

    await api.loadHostList();
    if (!mounted) return;

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
      _best = _anyOk
          ? (_results.where((r) => r.ok).toList()
                ..sort((a, b) =>
                    (a.latency ?? 99999).compareTo(b.latency ?? 99999)))
              .first
              .host
          : null;
      _selected = _best;
      final okImgs = _imgResults.where((r) => r.ok).toList()
        ..sort((a, b) =>
            (a.latency ?? 99999).compareTo(b.latency ?? 99999));
      if (okImgs.isNotEmpty) _selectedImg = okImgs.first.host;
      _bestImg = okImgs.isNotEmpty ? okImgs.first.host : null;
    });

    if (_best != null) {
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
    final img = _selectedImg;
    if (img != null && img.isNotEmpty) {
      JmService.instance.setImgHost(img);
      await AppState.instance.setImgHost(img);
    }
    if (!mounted) return;
    widget.onReady();
  }

  Future<void> _enterOffline() async {
    _countdown?.cancel();
    if (_entering) return;
    _entering = true;
    await AppState.instance.setOfflineMode(true);
    if (!mounted) return;
    widget.onReady();
  }

  void _pick(String host) {
    final r = _results.firstWhere((e) => e.host == host);
    if (!r.ok) return;
    setState(() {
      _selected = host;
      _userInteracted = true;
    });
    _countdown?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final String statusText;
    if (_userInteracted) {
      statusText = _testing
          ? L.t('manualSelectedTesting')
          : L.t('manualSelected');
    } else if (_testing) {
      statusText = L.t('testingLine');
    } else if (!_anyOk) {
      statusText = L.t('allLinesFailed');
    } else if (_secondsLeft > 0) {
      statusText = L.t('autoSelecting');
    } else {
      statusText = L.t('entering');
    }

    final String enterLabel;
    if (_userInteracted) {
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
                    for (var i = 0; i < _results.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildItem(theme, i),
                      ),
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
