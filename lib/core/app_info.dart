/// 应用版本信息（**唯一来源**）。
///
/// 之前版本号在 `settings_page.dart` 里硬编码了两处字符串 `'1.3.0'`，
/// 改 `pubspec.yaml` 后界面仍显示旧版本 —— 用户看到的就是「装了新版还写着
/// 1.3.0」。这里集中成一个常量，升版本只改这一处（外加 pubspec）。
///
/// 发版检查清单：
///   1. `pubspec.yaml` 的 `version:` 改成新版本（`x.y.z+build`）
///   2. 这里的 [version] 改成同样的 `x.y.z`
const String appVersion = '1.4.0';

/// 逆向自官方客户端的协议版本（`Tokenparam` 第二段）。
const String appProtocolVersion = '2.1.12';
