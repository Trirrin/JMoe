import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { registerJmoeChannels } from '../jmoe/JmoeChannelHandler';

/**
 * 鸿蒙入口 Ability。
 *
 * 除注册 Flutter 插件外，还注册 JMoe 的自定义通道
 * （jmoe/reader 与 jmoe/share），对应 Android 的 MainActivity
 * 与 iOS 的 JmoeChannelHandler.swift。
 */
export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);

    registerJmoeChannels(
      flutterEngine.dartExecutor.getBinaryMessenger(),
      this.context,
    );
  }
}
