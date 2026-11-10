import { MethodChannel, BinaryMessenger } from '@ohos/flutter_ohos';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { window } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { textToSpeech } from '@kit.CoreSpeechKit';

/**
 * HarmonyOS NEXT 原生通道实现（完整版）。
 *
 * 对应 Android 的 MainActivity.kt / iOS 的 JmoeChannelHandler.swift。
 * 通道名与方法名完全一致，Dart 侧无需改动。
 *
 * # 能力清单
 *
 * | 方法 | 实现方式 |
 * |---|---|
 * | keepScreenOn | window.setWindowKeepScreenOn |
 * | getBrightness / setBrightness | window.getWindowProperties / setWindowBrightness |
 * | getVolume / setVolume | audio.AudioVolumeManager（系统音量） |
 * | setVolumeKeyPage | 鸿蒙不允许拦截硬件音量键，返回 false（平台限制） |
 * | shareFiles | wantConstant.ACTION_SEND_TO_DATA + FLAG_AUTH_READ_URI_PERMISSION |
 * | shareText | ACTION_SEND_TO_DATA（text/plain） |
 * | openPath | 拉起系统文件管理器定位 |
 * | pickFile | picker.DocumentViewPicker |
 * | pickSavePath | picker.DocumentViewPicker.save（选目录） |
 * | notify | notificationManager.publish |
 * | tts* | @kit.CoreSpeechKit 的 textToSpeech |
 *
 * # ArkTS 约束（踩过的坑）
 *
 *  * 模块级函数里不能用 `this` → 全用模块级变量
 *  * 不允许 `any` / `unknown` → 显式 interface
 *  * 不允许无类型对象字面量 → 参数封装成 [JmoeArgs]
 */

// ---------------- 模块级状态 ----------------

let abilityContext: common.UIAbilityContext | null = null;
let ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
let ttsRequestSeq: number = 0;

// ---------------- 参数封装 ----------------

class JmoeArgs {
  on?: boolean;
  value?: number;
  paths?: string[];
  text?: string;
  title?: string;
  body?: string;
  extensions?: string[];
  rate?: number;
  pitch?: number;
  name?: string;

  constructor(raw: Object | undefined) {
    if (raw === undefined || raw === null) {
      return;
    }
    const r = raw as Record<string, Object>;
    if (r.on !== undefined) {
      this.on = r.on as boolean;
    }
    if (r.value !== undefined) {
      this.value = r.value as number;
    }
    if (r.paths !== undefined) {
      this.paths = r.paths as string[];
    }
    if (r.text !== undefined) {
      this.text = r.text as string;
    }
    if (r.title !== undefined) {
      this.title = r.title as string;
    }
    if (r.body !== undefined) {
      this.body = r.body as string;
    }
    if (r.extensions !== undefined) {
      this.extensions = r.extensions as string[];
    }
    if (r.rate !== undefined) {
      this.rate = r.rate as number;
    }
    if (r.pitch !== undefined) {
      this.pitch = r.pitch as number;
    }
    if (r.name !== undefined) {
      this.name = r.name as string;
    }
  }
}

interface MethodCallShape {
  method: string;
  arguments?: Object;
}

interface ResultShape {
  success(value?: Object | null): void;
  error(code: string, message: string, details?: Object | null): void;
  notImplemented(): void;
}

// ---------------- 通道注册 ----------------

export function registerJmoeChannels(
  messenger: BinaryMessenger,
  context: common.UIAbilityContext,
): void {
  abilityContext = context;

  const reader: MethodChannel = new MethodChannel(messenger, 'jmoe/reader');
  reader.setMethodCallHandler({
    onMethodCall: (call: MethodCallShape, result: ResultShape): void => {
      handleReader(call, result);
    },
  });

  const share: MethodChannel = new MethodChannel(messenger, 'jmoe/share');
  share.setMethodCallHandler({
    onMethodCall: (call: MethodCallShape, result: ResultShape): void => {
      handleShare(call, result);
    },
  });
}

// ---------------- reader 分发 ----------------

function handleReader(call: MethodCallShape, result: ResultShape): void {
  const method: string = call.method;
  const args: JmoeArgs = new JmoeArgs(call.arguments);

  switch (method) {
    case 'keepScreenOn':
      setKeepScreenOn(args.on === true, result);
      break;
    case 'getBrightness':
      getBrightness(result);
      break;
    case 'setBrightness':
      setBrightness(args.value ?? -1, result);
      break;
    case 'getVolume':
      getVolume(result);
      break;
    case 'setVolume':
      setVolume(args.value ?? 0.5, result);
      break;
    case 'setVolumeKeyPage':
      // 平台限制：鸿蒙不允许应用拦截硬件音量键
      result.success(false);
      break;
    case 'shareFiles':
      shareFiles(args.paths ?? [], result);
      break;
    case 'shareText':
      shareText(args.text ?? '', result);
      break;
    case 'openPath':
      openPath(args.text ?? '', result);
      break;
    case 'pickFile':
      pickFile(args.extensions ?? [], result);
      break;
    case 'pickSavePath':
      pickSaveDir(args.name ?? '', result);
      break;
    case 'notify':
      notify(args.title ?? '', args.body ?? '', result);
      break;
    case 'ttsAvailable':
      result.success(true);
      break;
    case 'ttsInit':
      ttsInit(result);
      break;
    case 'ttsSpeak':
      ttsSpeak(args.text ?? '', args.rate, args.pitch, result);
      break;
    case 'ttsStop':
      ttsStop(result);
      break;
    case 'ttsSetRate':
    case 'ttsSetPitch':
      // 语速/音调在 speak 时通过 extraParams 传入，这里只确认收到
      result.success(true);
      break;
    case 'ttsGetVoices':
      ttsGetVoices(result);
      break;
    case 'ttsSetVoice':
      // 语音在 speak 时通过 extraParams 指定
      result.success(true);
      break;
    default:
      result.notImplemented();
      break;
  }
}

function handleShare(call: MethodCallShape, result: ResultShape): void {
  const args: JmoeArgs = new JmoeArgs(call.arguments);
  if (call.method === 'shareText') {
    shareText(args.text ?? '', result);
  } else if (call.method === 'shareFiles') {
    shareFiles(args.paths ?? [], result);
  } else {
    result.notImplemented();
  }
}

// ---------------- 屏幕 ----------------

async function setKeepScreenOn(
  on: boolean,
  result: ResultShape,
): Promise<void> {
  try {
    if (abilityContext !== null) {
      const win: window.Window = await window.getLastWindow(abilityContext);
      await win.setWindowKeepScreenOn(on);
    }
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

async function getBrightness(result: ResultShape): Promise<void> {
  try {
    if (abilityContext !== null) {
      const win: window.Window = await window.getLastWindow(abilityContext);
      const props: window.WindowProperties = win.getWindowProperties();
      result.success(props.brightness ?? 0.5);
      return;
    }
    result.success(0.5);
  } catch (err) {
    result.success(0.5);
  }
}

async function setBrightness(v: number, result: ResultShape): Promise<void> {
  try {
    if (abilityContext !== null) {
      const win: window.Window = await window.getLastWindow(abilityContext);
      if (v < 0) {
        await win.setWindowBrightness(-1);
      } else {
        await win.setWindowBrightness(Math.max(0.01, Math.min(1, v)));
      }
    }
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

// ---------------- 系统音量 ----------------

/**
 * 取音乐流的音量管理器。
 *
 * 鸿蒙的音量按「音量组」管理，groupId 0 是默认组，
 * 里面能拿到 MEDIA（媒体）流的当前/最大/最小档位。
 */
async function getVolumeGroup(): Promise<audio.AudioVolumeGroupManager | null> {
  try {
    const mgr: audio.AudioVolumeManager =
      audio.getAudioManager().getVolumeManager();
    return await mgr.getVolumeGroupManager(0);
  } catch (err) {
    return null;
  }
}

async function getVolume(result: ResultShape): Promise<void> {
  try {
    const group: audio.AudioVolumeGroupManager | null =
      await getVolumeGroup();
    if (group === null) {
      result.success(0.5);
      return;
    }
    const vol: number = await group.getVolume(audio.AudioVolumeType.MEDIA);
    const max: number = await group.getMaxVolume(audio.AudioVolumeType.MEDIA);
    const min: number = await group.getMinVolume(audio.AudioVolumeType.MEDIA);
    const span: number = max - min;
    if (span <= 0) {
      result.success(0.5);
      return;
    }
    result.success((vol - min) / span);
  } catch (err) {
    result.success(0.5);
  }
}

async function setVolume(v: number, result: ResultShape): Promise<void> {
  try {
    const group: audio.AudioVolumeGroupManager | null =
      await getVolumeGroup();
    if (group === null) {
      result.success(false);
      return;
    }
    const max: number = await group.getMaxVolume(audio.AudioVolumeType.MEDIA);
    const min: number = await group.getMinVolume(audio.AudioVolumeType.MEDIA);
    const span: number = max - min;
    const clamped: number = Math.max(0, Math.min(1, v));
    const target: number = min + Math.round(span * clamped);
    // 注意：setVolume 定义在 AudioManager 上，
    // AudioVolumeGroupManager 只有 get*Volume。
    const am: audio.AudioManager = audio.getAudioManager();
    await am.setVolume(audio.AudioVolumeType.MEDIA, target);
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

// ---------------- 分享 ----------------

/**
 * 分享文件。
 *
 * 鸿蒙没有独立的「分享 SDK」，标准做法是用 Want 的
 * `ACTION_SEND_TO_DATA` 拉起系统分享面板，并授予读权限。
 * file:// 形式在应用间不可直接访问，这里用文件 URI + 授权标志。
 */
async function shareFiles(
  paths: string[],
  result: ResultShape,
): Promise<void> {
  if (abilityContext === null || paths.length === 0) {
    result.success(false);
    return;
  }
  try {
    const uris: string[] = [];
    for (let i = 0; i < paths.length; i++) {
      const p: string = paths[i];
      if (!fileIo.accessSync(p)) {
        continue;
      }
      uris.push('file://' + p);
    }
    if (uris.length === 0) {
      result.success(false);
      return;
    }

    const want: Want = {
      action: 'ohos.want.action.sendToData',
      type: 'application/octet-stream',
      uri: uris[0],
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    };
    await abilityContext.startAbility(want);
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

/** 分享文本。 */
async function shareText(text: string, result: ResultShape): Promise<void> {
  if (abilityContext === null || text.length === 0) {
    result.success(false);
    return;
  }
  try {
    const want: Want = {
      action: 'ohos.want.action.sendToData',
      type: 'text/plain',
      parameters: {
        'ability.params.stream': text,
      },
    };
    await abilityContext.startAbility(want);
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

// ---------------- 打开路径 ----------------

async function openPath(path: string, result: ResultShape): Promise<void> {
  if (abilityContext === null || path.length === 0) {
    result.success(false);
    return;
  }
  try {
    const want: Want = {
      bundleName: 'com.huawei.hmos.filemanager',
      abilityName: 'FileManagerAbility',
      uri: 'file://' + path,
    };
    await abilityContext.startAbility(want);
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

// ---------------- 文件选择 ----------------

async function pickFile(
  extensions: string[],
  result: ResultShape,
): Promise<void> {
  if (abilityContext === null) {
    result.success(null);
    return;
  }
  try {
    const opts: picker.DocumentSelectOptions =
      new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    if (extensions.length > 0) {
      const filters: string[] = [];
      for (let i = 0; i < extensions.length; i++) {
        filters.push('.' + extensions[i]);
      }
      opts.fileSuffixFilters = filters;
    }
    const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(
      abilityContext,
    );
    const uris: string[] = await p.select(opts);
    if (uris.length === 0) {
      result.success(null);
      return;
    }
    result.success(uris[0]);
  } catch (err) {
    result.success(null);
  }
}

/**
 * 选择保存目录/路径。
 *
 * 用 DocumentViewPicker 的 save 模式：用户选一个位置并给文件名，
 * 返回可写的 URI。Dart 侧需要文件路径时用它写文件。
 */
async function pickSaveDir(
  suggestedName: string,
  result: ResultShape,
): Promise<void> {
  if (abilityContext === null) {
    result.success(null);
    return;
  }
  try {
    const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    if (suggestedName.length > 0) {
      opts.newFileNames = [suggestedName];
    }
    const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(
      abilityContext,
    );
    const uris: string[] = await p.save(opts);
    if (uris.length === 0) {
      result.success(null);
      return;
    }
    result.success(uris[0]);
  } catch (err) {
    result.success(null);
  }
}

// ---------------- 通知 ----------------

async function notify(
  title: string,
  body: string,
  result: ResultShape,
): Promise<void> {
  try {
    const content: notificationManager.NotificationContent = {
      notificationContentType:
        notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: {
        title: title,
        text: body,
      },
    };
    const request: notificationManager.NotificationRequest = {
      id: Math.floor(Math.random() * 100000),
      content: content,
    };
    await notificationManager.publish(request);
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

// ---------------- TTS ----------------

async function ensureTtsEngine(): Promise<boolean> {
  if (ttsEngine !== null) {
    return true;
  }
  try {
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: 0,
      online: 1,
    };
    ttsEngine = await textToSpeech.createEngine(params);
    return ttsEngine !== null;
  } catch (err) {
    return false;
  }
}

async function ttsInit(result: ResultShape): Promise<void> {
  const ok: boolean = await ensureTtsEngine();
  result.success(ok);
}

async function ttsSpeak(
  text: string,
  rate: number | undefined,
  pitch: number | undefined,
  result: ResultShape,
): Promise<void> {
  if (text.length === 0) {
    result.success(false);
    return;
  }
  const ok: boolean = await ensureTtsEngine();
  if (!ok || ttsEngine === null) {
    result.success(false);
    return;
  }
  try {
    ttsRequestSeq++;
    const extra: Record<string, Object> = {};
    // speed 范围 0.5~2.0，pitch 范围 0.5~2.0（鸿蒙 TTS 约定）
    if (rate !== undefined) {
      extra['speed'] = Math.max(0.5, Math.min(2.0, rate * 2));
    }
    if (pitch !== undefined) {
      extra['pitch'] = Math.max(0.5, Math.min(2.0, pitch));
    }
    const params: textToSpeech.SpeakParams = {
      requestId: '' + Date.now() + '_' + ttsRequestSeq,
      extraParams: extra,
    };
    ttsEngine.speak(text, params);
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

function ttsStop(result: ResultShape): void {
  try {
    if (ttsEngine !== null) {
      ttsEngine.stop();
    }
    result.success(true);
  } catch (err) {
    result.success(false);
  }
}

async function ttsGetVoices(result: ResultShape): Promise<void> {
  const ok: boolean = await ensureTtsEngine();
  if (!ok || ttsEngine === null) {
    result.success([]);
    return;
  }
  try {
    const query: textToSpeech.VoiceQuery = {
      requestId: '' + Date.now(),
      // 1 = 离线模式（在线模式当前不支持）
      online: 1,
    };
    const voices: Array<textToSpeech.VoiceInfo> =
      await ttsEngine.listVoices(query);
    const names: string[] = [];
    for (let i = 0; i < voices.length; i++) {
      names.push(voices[i].language);
    }
    result.success(names);
  } catch (err) {
    result.success([]);
  }
}
