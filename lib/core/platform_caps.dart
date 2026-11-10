import 'dart:io' show Platform;

class PlatformCaps {
  PlatformCaps._();

  static bool get isOhos => Platform.operatingSystem == 'ohos';

  static bool get isAndroid => !isOhos && Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;

  static bool get supportsVolumeKeyPaging => isAndroid;

  static bool get supportsSystemVolume => true;

  static bool get supportsOpenFolder => true;

  static bool get supportsPickSavePath => true;

  static bool get supportsTts => true;

  static bool get supportsNotification => true;

  static bool get supportsBrightness => true;

  static String get name {
    if (isOhos) return 'HarmonyOS';
    if (isIOS) return 'iOS';
    if (isAndroid) return 'Android';
    return Platform.operatingSystem;
  }
}
