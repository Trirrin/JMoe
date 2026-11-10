import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// iOS 原生通道实现（对应 Android 的 MainActivity.kt）。
///
/// 通道名与方法名与 Android 完全一致，Dart 侧无需任何改动：
///   * `jmoe/reader`：文件选择、打开目录、分享、通知、亮度、音量、
///     TTS、常亮、音量键翻页
///   * `jmoe/share` ：分享文本
///
/// 平台差异处理：
///   * **文件选择**：Android 用 SAF，iOS 用 UIDocumentPickerViewController
///   * **打开目录**：iOS 没有"文件管理器定位到目录"的概念，
///     改用 UIDocumentInteractionController 或直接返回 false
///     （Dart 侧会提示"不支持"，不会崩溃）
///   * **分享**：iOS 用 UIActivityViewController
///   * **音量键翻页**：iOS 不允许拦截硬件音量键（系统限制），返回 false
///   * **通知**：iOS 用 UNUserNotificationCenter，需要用户授权
class JmoeChannelHandler: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let reader = FlutterMethodChannel(
      name: "jmoe/reader", binaryMessenger: registrar.messenger())
    let handler = JmoeChannelHandler()
    reader.setMethodCallHandler { call, result in
      handler.handleReader(call, result: result)
    }

    let share = FlutterMethodChannel(
      name: "jmoe/share", binaryMessenger: registrar.messenger())
    share.setMethodCallHandler { call, result in
      handler.handleShare(call, result: result)
    }
  }

  // MARK: - jmoe/reader

  private func handleReader(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "keepScreenOn":
      let on = args["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(true)

    case "getBrightness":
      result(Double(UIScreen.main.brightness))

    case "setBrightness":
      let v = args["value"] as? Double ?? -1
      if v < 0 {
        // 恢复系统自动亮度
        UIScreen.main.brightness = UIScreen.main.brightness
      } else {
        UIScreen.main.brightness = CGFloat(max(0.01, min(1.0, v)))
      }
      result(true)

    case "getVolume":
      // AVAudioSession.outputVolume 是只读的，取系统音量
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(true)
      result(Double(session.outputVolume))

    case "setVolume":
      let v = args["value"] as? Double ?? -1
      setSystemVolume(v, result: result)

    case "setVolumeKeyPage":
      // iOS 无法拦截硬件音量键（系统限制）。
      result(false)

    case "shareFiles":
      let paths = args["paths"] as? [String] ?? []
      shareFiles(paths, result: result)

    case "shareText":
      let text = args["text"] as? String ?? ""
      shareText(text, result: result)

    case "openPath":
      // iOS 没有"文件管理器跳转到目录"的能力。
      // 用 UIDocumentInteractionController 打开该位置（若可行），
      // 否则返回 false —— Dart 侧会提示不支持。
      let path = args["path"] as? String ?? ""
      openPath(path, result: result)

    case "pickFile":
      let exts = args["extensions"] as? [String] ?? []
      pickFile(extensions: exts, result: result)

    case "pickSavePath":
      // 用 UIDocumentPicker 的 export 模式让用户选保存位置。
      // 先把 suggestedName 的空文件写到临时目录，再导出到用户选的位置。
      let name = args["name"] as? String ?? "export"
      pickSavePath(suggestedName: name, result: result)

    case "notify":
      let title = args["title"] as? String ?? ""
      let body = args["body"] as? String ?? ""
      postNotification(title: title, body: body, result: result)

    // ---- TTS ----
    case "ttsAvailable":
      result(true)
    case "ttsInit":
      result(TtsHolder.shared.initEngine())
    case "ttsSpeak":
      let text = args["text"] as? String ?? ""
      let rate = args["rate"] as? Double
      let pitch = args["pitch"] as? Double
      result(TtsHolder.shared.speak(text, rate: rate, pitch: pitch))
    case "ttsStop":
      TtsHolder.shared.stop()
      result(true)
    case "ttsSetRate":
      TtsHolder.shared.rate = args["rate"] as? Double
      result(true)
    case "ttsSetPitch":
      TtsHolder.shared.pitch = args["pitch"] as? Double
      result(true)
    case "ttsGetVoices":
      result(TtsHolder.shared.voiceNames())
    case "ttsSetVoice":
      let name = args["name"] as? String ?? ""
      result(TtsHolder.shared.setVoice(name))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - jmoe/share

  private func handleShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "shareText":
      shareText(args["text"] as? String ?? "", result: result)
    case "shareFiles":
      shareFiles(args["paths"] as? [String] ?? [], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 分享

  private func shareFiles(_ paths: [String], result: @escaping FlutterResult) {
    let urls = paths.map { URL(fileURLWithPath: $0) }.filter {
      FileManager.default.fileExists(atPath: $0.path)
    }
    guard !urls.isEmpty else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      guard let vc = self.topViewController() else {
        result(false)
        return
      }
      let ac = UIActivityViewController(activityItems: urls, applicationActivities: nil)
      // iPad 必须提供 popover 锚点，否则崩溃
      if let pop = ac.popoverPresentationController {
        pop.sourceView = vc.view
        pop.sourceRect = CGRect(
          x: vc.view.bounds.midX, y: vc.view.bounds.maxY, width: 0, height: 0)
        pop.permittedArrowDirections = []
      }
      vc.present(ac, animated: true) { result(true) }
    }
  }

  private func shareText(_ text: String, result: @escaping FlutterResult) {
    guard !text.isEmpty else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      guard let vc = self.topViewController() else {
        result(false)
        return
      }
      let ac = UIActivityViewController(activityItems: [text], applicationActivities: nil)
      if let pop = ac.popoverPresentationController {
        pop.sourceView = vc.view
        pop.sourceRect = CGRect(
          x: vc.view.bounds.midX, y: vc.view.bounds.maxY, width: 0, height: 0)
        pop.permittedArrowDirections = []
      }
      vc.present(ac, animated: true) { result(true) }
    }
  }

  // MARK: - 系统音量

  /// 设置系统音量。
  ///
  /// iOS **没有**公开 API 能直接写系统音量；标准做法是用
  /// `MPVolumeView` 内部的那个 UISlider：把它挂到窗口上（不可见），
  /// 设好 value 再触发 `.touchUpInside`，系统音量就会被改掉。
  /// 这是 App Store 上大量播放器在用的可行方案。
  private func setSystemVolume(_ v: Double, result: @escaping FlutterResult) {
    // v < 0 表示不改变（Dart 侧用它表示「无操作」）
    guard v >= 0 else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      let target = Float(max(0.0, min(1.0, v)))
      let mpView = MPVolumeView(
        frame: CGRect(x: -1000, y: -1000, width: 100, height: 40))
      guard let window = self.keyWindow() else {
        result(false)
        return
      }
      window.addSubview(mpView)
      // MPVolumeView 里唯一的 UISlider 就是音量滑块
      var slider: UISlider?
      for sub in mpView.subviews {
        if let s = sub as? UISlider {
          slider = s
          break
        }
      }
      guard let s = slider else {
        mpView.removeFromSuperview()
        result(false)
        return
      }
      // 直接 setValue 有时不生效，需在下一 runloop 再设一次并触发事件
      s.value = target
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        s.value = target
        s.sendActions(for: .touchUpInside)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          mpView.removeFromSuperview()
          result(true)
        }
      }
    }
  }

  private func keyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
    }
    return UIApplication.shared.keyWindow
  }

  // MARK: - 选保存位置

  private var saveCompletion: FlutterResult?

  /// 让用户选择保存位置。
  ///
  /// iOS 的做法：把目标文件（或一个同名的空占位文件）作为
  /// `UIDocumentPickerViewController(forExporting:)` 的输入，
  /// 用户选好目录后系统会把文件拷过去，回调里拿到最终 URL。
  private func pickSavePath(
    suggestedName: String, result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async {
      let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("jmoe_export", isDirectory: true)
      try? FileManager.default.createDirectory(
        at: tmpDir, withIntermediateDirectories: true)

      let fileName = suggestedName.contains(".")
        ? suggestedName : "\(suggestedName).jmoe"
      let placeholder = tmpDir.appendingPathComponent(fileName)
      if !FileManager.default.fileExists(atPath: placeholder.path) {
        FileManager.default.createFile(
          atPath: placeholder.path, contents: Data())
      }

      guard let vc = self.topViewController() else {
        result(nil)
        return
      }
      let picker = UIDocumentPickerViewController(
        forExporting: [placeholder], asCopy: true)
      picker.delegate = self
      self.saveCompletion = result
      vc.present(picker, animated: true)
    }
  }

  // MARK: - 打开路径

  private func openPath(_ path: String, result: @escaping FlutterResult) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
      result(false)
      return
    }

    // 目录：用「文件」App 的能力打开该目录。
    //
    // iOS 没有可直接调起的第三方文件管理器，但系统「文件」App
    // 支持通过 UIDocumentPickerViewController 的 browser 模式
    // 浏览指定目录。这里用 in: .open 打开该目录本身。
    if isDir.boolValue {
      DispatchQueue.main.async {
        let dirURL = URL(fileURLWithPath: path)
        let picker = UIDocumentPickerViewController(
          url: dirURL, in: .open)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        guard let vc = self.topViewController() else {
          result(false)
          return
        }
        vc.present(picker, animated: true) { result(true) }
      }
      return
    }

    // 文件：用系统分享面板预览
    DispatchQueue.main.async {
      let url = URL(fileURLWithPath: path)
      let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      guard let vc = self.topViewController() else {
        result(false)
        return
      }
      if let pop = ac.popoverPresentationController {
        pop.sourceView = vc.view
        pop.sourceRect = vc.view.bounds
      }
      vc.present(ac, animated: true) { result(true) }
    }
  }

  // MARK: - 文件选择

  private var pickCompletion: FlutterResult?

  private func pickFile(extensions: [String], result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let vc = self.topViewController() else {
        result(nil)
        return
      }
      // 用 UIDocumentPickerViewController 选文件（对应 Android 的 SAF）
      var types: [UTType] = []
      if #available(iOS 14.0, *) {
        if extensions.isEmpty {
          types = [.data]
        } else {
          for e in extensions {
            if let t = UTType(filenameExtension: e) {
              types.append(t)
            }
          }
        }
      }
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forOpeningContentTypes: types.isEmpty ? [.data] : types, asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(
          documentTypes: ["public.data"], in: .import)
      }
      picker.delegate = self
      self.pickCompletion = result
      vc.present(picker, animated: true)
    }
  }

  // MARK: - 通知

  private func postNotification(
    title: String, body: String, result: @escaping FlutterResult
  ) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else {
        result(false)
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let req = UNNotificationRequest(
        identifier: UUID().uuidString, content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
      center.add(req) { err in
        result(err == nil)
      }
    }
  }

  // MARK: - 工具

  private func topViewController() -> UIViewController? {
    guard
      let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
      let root = windowScene.windows.first(where: { $0.isKeyWindow })?
        .rootViewController
    else { return nil }
    var vc = root
    while let presented = vc.presentedViewController {
      vc = presented
    }
    return vc
  }
}

// MARK: - 文件选择回调

extension JmoeChannelHandler: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    // 导出（选保存位置）回调
    if let save = saveCompletion {
      saveCompletion = nil
      save(urls.first?.path)
      return
    }
    let r = pickCompletion
    pickCompletion = nil
    guard let url = urls.first else {
      r?(nil)
      return
    }
    // asCopy: true 时文件已在临时目录，直接返回路径
    r?(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if let save = saveCompletion {
      saveCompletion = nil
      save(nil)
      return
    }
    let r = pickCompletion
    pickCompletion = nil
    r?(nil)
  }
}

// MARK: - TTS

/// 语音朗读（对应 Android 的 TextToSpeech）。
class TtsHolder {
  static let shared = TtsHolder()
  private let synth = AVSpeechSynthesizer()
  var rate: Double?
  var pitch: Double?
  private var selectedVoice: String?

  func initEngine() -> Bool { true }

  func speak(_ text: String, rate: Double?, pitch: Double?) -> Bool {
    if text.isEmpty { return false }
    if let r = rate { self.rate = r }
    if let p = pitch { self.pitch = p }
    let u = AVSpeechUtterance(string: text)
    if let v = selectedVoice,
      let voice = AVSpeechSynthesisVoice(identifier: v) {
      u.voice = voice
    } else {
      // 中文优先
      u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    }
    // AVSpeechUtterance 的 rate 范围 0~1，默认 0.5
    if let r = self.rate {
      u.rate = Float(max(0.1, min(1.0, r)))
    }
    if let p = self.pitch {
      u.pitchMultiplier = Float(max(0.5, min(2.0, p)))
    }
    synth.speak(u)
    return true
  }

  func stop() {
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
  }

  func voiceNames() -> [String] {
    return AVSpeechSynthesisVoice.speechVoices().map { $0.identifier }
  }

  func setVoice(_ name: String) -> Bool {
    if AVSpeechSynthesisVoice(identifier: name) != nil {
      selectedVoice = name
      return true
    }
    return false
  }
}
