import AVFoundation
import Flutter
import MediaPlayer
import UIKit

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

  private func handleReader(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "moveToBack":
      DispatchQueue.main.async {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        result(true)
      }

    case "keepScreenOn":
      let on = args["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(true)

    case "getBrightness":
      result(Double(UIScreen.main.brightness))

    case "setBrightness":
      let v = args["value"] as? Double ?? -1
      if v < 0 {
        UIScreen.main.brightness = UIScreen.main.brightness
      } else {
        UIScreen.main.brightness = CGFloat(max(0.01, min(1.0, v)))
      }
      result(true)

    case "getVolume":
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(true)
      result(Double(session.outputVolume))

    case "setVolume":
      let v = args["value"] as? Double ?? -1
      setSystemVolume(v, result: result)

    case "setVolumeKeyPage":
      result(false)

    case "shareFiles":
      let paths = args["paths"] as? [String] ?? []
      shareFiles(paths, result: result)

    case "shareText":
      let text = args["text"] as? String ?? ""
      shareText(text, result: result)

    case "openPath":
      let path = args["path"] as? String ?? ""
      openPath(path, result: result)

    case "pickFile":
      let exts = args["extensions"] as? [String] ?? []
      pickFile(extensions: exts, result: result)

    case "pickSavePath":
      let name = args["name"] as? String ?? "export"
      pickSavePath(suggestedName: name, result: result)

    case "notify":
      let title = args["title"] as? String ?? ""
      let body = args["body"] as? String ?? ""
      postNotification(title: title, body: body, result: result)

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

  private func setSystemVolume(_ v: Double, result: @escaping FlutterResult) {
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

  private var saveCompletion: FlutterResult?

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

  private func openPath(_ path: String, result: @escaping FlutterResult) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
      result(false)
      return
    }

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

  private var pickCompletion: FlutterResult?

  private func pickFile(extensions: [String], result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let vc = self.topViewController() else {
        result(nil)
        return
      }
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

extension JmoeChannelHandler: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
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
      u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    }
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
