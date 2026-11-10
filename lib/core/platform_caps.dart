import 'dart:io' show Platform;

/// 平台能力判断。
///
/// # 为什么需要它
///
/// 三端（Android / iOS / HarmonyOS）的原生能力并不完全一致。
/// 用户要求：**平台不支持的功能不要在界面上出现**，
/// 而不是显示出来点了没反应或报错。
///
/// 因此凡是依赖平台能力的入口，都要先用这里的能力开关判断，
/// 不支持时**整块隐藏**（不是禁用、不是灰化 —— 用户不该知道有这功能）。
///
/// 加新平台或新能力时，只需改这一个文件。
class PlatformCaps {
  PlatformCaps._();

  /// HarmonyOS 的 operatingSystem 标识
  static bool get isOhos => Platform.operatingSystem == 'ohos';

  static bool get isAndroid => !isOhos && Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;

  // -------------------------------------------------------------------------
  // 音量键翻页
  // -------------------------------------------------------------------------

  /// 是否支持用**音量键翻页**。
  ///
  /// 只有 Android 能做到：它允许应用拦截 `KEYCODE_VOLUME_UP/DOWN`
  /// 并消费事件（`dispatchKeyEvent` 返回 true）。
  ///
  /// * **iOS**：系统不允许应用拦截硬件音量键，无公开 API。
  /// * **HarmonyOS**：同样不允许拦截硬件音量键。
  ///
  /// 所以这两个平台上，设置页的「音量键翻页」开关与阅读器的
  /// 音量键通道注册都要**完全隐藏/跳过**。
  static bool get supportsVolumeKeyPaging => isAndroid;

  // -------------------------------------------------------------------------
  // 系统音量读写
  // -------------------------------------------------------------------------

  /// 是否支持读写**系统音量**。
  ///
  /// * Android：`AudioManager` 可读写。
  /// * iOS：读取可（`AVAudioSession.outputVolume`），
  ///   写入只能借助 `MPVolumeView` 的私有 slider，已实现但不太可靠。
  /// * HarmonyOS：`AudioManager.setVolume` 可读写。
  ///
  /// 三端都实现了，保留开关以便将来某端失效时快速切换。
  static bool get supportsSystemVolume => true;

  // -------------------------------------------------------------------------
  // 打开所在目录
  // -------------------------------------------------------------------------

  /// 是否支持「打开文件所在目录」（跳到文件管理器并定位）。
  ///
  /// * Android：DocumentsUI / 各家文件管理器可定位。
  /// * iOS：无第三方文件管理器可调起，但可用「文件」App 浏览目录，
  ///   已用 `UIDocumentPickerViewController` 实现。
  /// * HarmonyOS：可拉起系统文件管理器。
  ///
  /// 三端都实现了，保留开关以便将来失效时隐藏入口。
  static bool get supportsOpenFolder => true;

  // -------------------------------------------------------------------------
  // 选择保存位置
  // -------------------------------------------------------------------------

  /// 是否支持「让用户选保存位置」。
  ///
  /// * Android：SAF 的 `pickSavePath`。
  /// * iOS：`UIDocumentPickerViewController(forExporting:)`。
  /// * HarmonyOS：`picker.DocumentViewPicker.save()`。
  static bool get supportsPickSavePath => true;

  // -------------------------------------------------------------------------
  // TTS 朗读
  // -------------------------------------------------------------------------

  /// 是否支持语音朗读。
  ///
  /// 三端都有实现（Android TextToSpeech / iOS AVSpeechSynthesizer /
  /// 鸿蒙 CoreSpeechKit）。但运行时可能因设备缺少语音包而不可用，
  /// 所以调用方还应结合原生返回的 `ttsAvailable` 结果判断。
  static bool get supportsTts => true;

  // -------------------------------------------------------------------------
  // 通知
  // -------------------------------------------------------------------------

  /// 是否支持发送系统通知。
  static bool get supportsNotification => true;

  // -------------------------------------------------------------------------
  // 屏幕亮度调节
  // -------------------------------------------------------------------------

  /// 是否支持应用内调节屏幕亮度。
  static bool get supportsBrightness => true;

  /// 平台名（用于提示文案 / 日志）
  static String get name {
    if (isOhos) return 'HarmonyOS';
    if (isIOS) return 'iOS';
    if (isAndroid) return 'Android';
    return Platform.operatingSystem;
  }
}
