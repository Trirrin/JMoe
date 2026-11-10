import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reader_native.dart';
import '../core/reader_settings.dart';

class NovelTtsSheet extends StatefulWidget {
  const NovelTtsSheet({
    super.key,
    required this.settings,
    required this.theme,
    required this.onChanged,
    required this.onStart,
  });

  final ReaderSettings settings;
  final ReaderTheme theme;
  final VoidCallback onChanged;

  final VoidCallback onStart;

  @override
  State<NovelTtsSheet> createState() => _NovelTtsSheetState();
}

class _NovelTtsSheetState extends State<NovelTtsSheet> {
  List<Map<String, String>> _voices = const [];
  bool _loadingVoices = true;

  @override
  void initState() {
    super.initState();
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    final v = await ReaderNative.instance.ttsGetVoices();
    if (!mounted) return;
    setState(() {
      _voices = v;
      _loadingVoices = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final theme = widget.theme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.t('readAloud'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: theme.fg,
              ),
            ),
            const SizedBox(height: 14),
            _slider(
              label: L.t('ttsSpeed'),
              value: s.ttsRate,
              min: 0.5,
              max: 3.0,
              divisions: 25,
              display: '${s.ttsRate.toStringAsFixed(1)}x',
              onChanged: (v) {
                s.update(() => s.ttsRate = v);
                ReaderNative.instance.ttsSetRate(v);
                setState(() {});
                widget.onChanged();
              },
            ),
            _slider(
              label: L.t('ttsPitch'),
              value: s.ttsPitch,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              display: s.ttsPitch.toStringAsFixed(1),
              onChanged: (v) {
                s.update(() => s.ttsPitch = v);
                ReaderNative.instance.ttsSetPitch(v);
                setState(() {});
                widget.onChanged();
              },
            ),
            const SizedBox(height: 6),
            Text(
              L.t('ttsVoice'),
              style: TextStyle(fontSize: 12.5, color: theme.fg),
            ),
            const SizedBox(height: 6),
            if (_loadingVoices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.subtle,
                  ),
                ),
              )
            else if (_voices.isEmpty)
              Text(
                L.t('ttsNoVoices'),
                style: TextStyle(fontSize: 11.5, color: theme.subtle),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _voices.take(12).map((v) {
                  final on = s.ttsVoiceName == v['name'];
                  final label = v['locale']!.isEmpty
                      ? v['name']!
                      : '${v['locale']}';
                  return ChoiceChip(
                    label: Text(
                      label,
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: on,
                    onSelected: (_) async {
                      await ReaderNative.instance.ttsSetVoice(v['name']!);
                      s.update(() => s.ttsVoiceName = v['name']!);
                      setState(() {});
                      widget.onChanged();
                    },
                  );
                }).toList(),
              ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onStart();
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text(L.t('ttsStartReading')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final theme = widget.theme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12.5, color: theme.fg),
                ),
              ),
              Text(
                display,
                style: TextStyle(fontSize: 11.5, color: theme.subtle),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
