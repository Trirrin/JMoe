import { FlutterEngine, Log } from '@ohos/flutter_ohos';

const TAG = "GeneratedPluginRegistrant";

export class GeneratedPluginRegistrant {

  static registerWith(flutterEngine: FlutterEngine) {
    try {
    } catch (e) {
      Log.e(
        TAG,
        "Tried to register plugins with FlutterEngine ("
          + flutterEngine
          + ") failed.");
      Log.e(TAG, "Received exception while registering", e);
    }
  }
}
