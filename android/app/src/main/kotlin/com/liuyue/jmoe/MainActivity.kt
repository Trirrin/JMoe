package com.liuyue.jmoe

import android.content.Intent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val shareChannel = "jmoe/share"
    private val readerChannel = "jmoe/reader"

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeak: Triple<String, Float, String?>? = null
    private var channel: MethodChannel? = null
    private var utterCounter = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val subject = call.argument<String>("subject") ?: ""
                        try {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                if (subject.isNotEmpty()) {
                                    putExtra(Intent.EXTRA_SUBJECT, subject)
                                }
                            }
                            val chooser = Intent.createChooser(send, "分享到")
                                .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(chooser)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SHARE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        val rc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, readerChannel)
        channel = rc
        rc.setMethodCallHandler { call, result ->
            when (call.method) {
                "ttsInit" -> initTts { ok -> result.success(ok) }
                "ttsSpeak" -> {
                    val text = call.argument<String>("text") ?: ""
                    val rate = (call.argument<Double>("rate") ?: 1.0).toFloat()
                    val locale = call.argument<String>("locale") ?: "zh-CN"
                    if (!ttsReady) {
                        initTts { ok ->
                            if (ok) {
                                speak(text, rate, locale)
                                result.success(true)
                            } else {
                                // 设备无可用语音引擎
                                result.error("TTS_UNAVAILABLE", "no tts engine", null)
                            }
                        }
                    } else {
                        speak(text, rate, locale)
                        result.success(true)
                    }
                }
                "ttsStop" -> {
                    tts?.stop()
                    result.success(true)
                }
                "ttsSetRate" -> {
                    tts?.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
                    result.success(true)
                }
                "ttsAvailable" -> result.success(ttsReady)
                "setBrightness" -> {
                    val v = (call.argument<Double>("value") ?: -1.0).toFloat()
                    runOnUiThread {
                        val lp = window.attributes
                        lp.screenBrightness = if (v < 0f) {
                            WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        } else {
                            v.coerceIn(0.01f, 1f)
                        }
                        window.attributes = lp
                    }
                    result.success(true)
                }
                "getBrightness" -> {
                    val cur = window.attributes.screenBrightness
                    val value = if (cur >= 0f) {
                        cur.toDouble()
                    } else {
                        try {
                            android.provider.Settings.System.getInt(
                                contentResolver,
                                android.provider.Settings.System.SCREEN_BRIGHTNESS
                            ) / 255.0
                        } catch (_: Exception) {
                            0.5
                        }
                    }
                    result.success(value)
                }
                "getVolume" -> {
                    val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
                    val cur = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                    val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                    result.success(if (max > 0) cur.toDouble() / max else 0.0)
                }
                "setVolume" -> {
                    val v = (call.argument<Double>("value") ?: 0.5).toFloat().coerceIn(0f, 1f)
                    runOnUiThread {
                        val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
                        val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                        am.setStreamVolume(
                            android.media.AudioManager.STREAM_MUSIC,
                            (v * max).roundToInt(),
                            0
                        )
                    }
                    result.success(true)
                }
                "keepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: true
                    runOnUiThread {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun initTts(onReady: (Boolean) -> Unit) {
        if (ttsReady) {
            onReady(true)
            return
        }
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {
                        runOnUiThread {
                            channel?.invokeMethod("onTtsDone", mapOf("id" to utteranceId))
                        }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        runOnUiThread {
                            channel?.invokeMethod("onTtsError", mapOf("id" to utteranceId))
                        }
                    }
                })
                ttsReady = true
                pendingSpeak?.let { (t, r, l) ->
                    pendingSpeak = null
                    speak(t, r, l ?: "zh-CN")
                }
                onReady(true)
            } else {
                // 初始化失败：明确告知 Dart 侧不可用
                ttsReady = false
                onReady(false)
            }
        }
    }

    private fun speak(text: String, rate: Float, locale: String) {
        if (!ttsReady) {
            pendingSpeak = Triple(text, rate, locale)
            initTts { ok ->
                if (!ok) pendingSpeak = null
            }
            return
        }
        val t = tts ?: return
        try {
            var loc = Locale.forLanguageTag(locale)
            val avail = t.isLanguageAvailable(loc)
            if (avail < TextToSpeech.LANG_AVAILABLE) {
                loc = Locale.getDefault()
                t.isLanguageAvailable(loc)
            }
            t.language = loc
        } catch (_: Exception) {
        }
        t.setSpeechRate(rate)
        utterCounter++
        val id = "u$utterCounter"
        t.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
    }

    override fun onDestroy() {
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {
        }
        tts = null
        ttsReady = false
        super.onDestroy()
    }
}
