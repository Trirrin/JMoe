import 'dart:async';

import 'package:flutter/services.dart';

/// 原生能力桥：TTS 朗读、亮度、常亮。
class ReaderNative {
  ReaderNative._();
  static final ReaderNative instance = ReaderNative._();

  static const _ch = MethodChannel('jmoe/reader');

  bool _bound = false;

  /// TTS 单条播完回调。
  VoidCallback? onUtteranceDone;

  void _bind() {
    if (_bound) return;
    _bound = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onTtsDone':
          onUtteranceDone?.call();
          break;
        case 'onTtsError':
          onUtteranceDone?.call();
          break;
      }
      return null;
    });
  }

  Future<bool> ttsInit() async {
    _bind();
    try {
      final r = await _ch.invokeMethod<bool>('ttsInit');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> ttsSpeak({
    required String text,
    double rate = 1.0,
    String locale = 'zh-CN',
  }) async {
    _bind();
    try {
      final r = await _ch.invokeMethod<bool>('ttsSpeak', {
        'text': text,
        'rate': rate,
        'locale': locale,
      });
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> ttsStop() async {
    try {
      await _ch.invokeMethod('ttsStop');
    } catch (_) {}
  }

  Future<void> ttsSetRate(double rate) async {
    try {
      await _ch.invokeMethod('ttsSetRate', {'rate': rate});
    } catch (_) {}
  }

  /// 设置音调（0.5 ~ 2.0）。
  Future<void> ttsSetPitch(double pitch) async {
    try {
      await _ch.invokeMethod('ttsSetPitch', {'pitch': pitch});
    } catch (_) {}
  }

  /// 获取设备可用音色列表：[{name, locale}]
  Future<List<Map<String, String>>> ttsGetVoices() async {
    try {
      final r = await _ch.invokeMethod<List>('ttsGetVoices');
      if (r == null) return const [];
      return r
          .whereType<Map>()
          .map((e) => {
                'name': '${e['name'] ?? ''}',
                'locale': '${e['locale'] ?? ''}',
              })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 按名称选择音色。
  Future<bool> ttsSetVoice(String name) async {
    try {
      final r = await _ch.invokeMethod<bool>('ttsSetVoice', {'name': name});
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> ttsAvailable() async {
    try {
      final r = await _ch.invokeMethod<bool>('ttsAvailable');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// value: -1 表示跟随系统，0..1 为绝对亮度。
  Future<void> setBrightness(double value) async {
    try {
      await _ch.invokeMethod('setBrightness', {'value': value});
    } catch (_) {}
  }

  /// 读取当前亮度（0..1）。
  Future<double> getBrightness() async {
    try {
      final v = await _ch.invokeMethod<double>('getBrightness');
      return v ?? 0.5;
    } catch (_) {
      return 0.5;
    }
  }

  /// 读取媒体音量（0..1）。
  Future<double> getVolume() async {
    try {
      final v = await _ch.invokeMethod<double>('getVolume');
      return v ?? 0.5;
    } catch (_) {
      return 0.5;
    }
  }

  /// 设置媒体音量（0..1）。
  Future<void> setVolume(double value) async {
    try {
      await _ch.invokeMethod('setVolume', {'value': value.clamp(0.0, 1.0)});
    } catch (_) {}
  }

  Future<void> keepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod('keepScreenOn', {'on': on});
    } catch (_) {}
  }
}

typedef VoidCallback = void Function();
