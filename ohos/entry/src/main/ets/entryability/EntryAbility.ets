import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { registerJmoeChannels } from '../jmoe/JmoeChannelHandler';

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
