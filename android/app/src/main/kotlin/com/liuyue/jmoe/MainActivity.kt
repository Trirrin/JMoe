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

    private var volumeKeyEnabled = false

    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingSaveResult: MethodChannel.Result? = null

    companion object {
        private const val REQ_PICK_FILE = 1001
        private const val REQ_SAVE_FILE = 1002
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_PICK_FILE -> {
                val uri = data?.data
                val path = if (resultCode == RESULT_OK && uri != null) {
                    uriToPath(uri)
                } else {
                    null
                }
                pendingPickResult?.success(path)
                pendingPickResult = null
            }
            REQ_SAVE_FILE -> {
                val uri = data?.data
                if (resultCode == RESULT_OK && uri != null) {
                    val path = uriToPath(uri)
                    pendingSaveResult?.success(path)
                } else {
                    pendingSaveResult?.success(null)
                }
                pendingSaveResult = null
            }
        }
    }

    private fun uriToPath(uri: android.net.Uri): String? {
        return try {
            if (uri.scheme == "file") return uri.path
            val name = queryDisplayName(uri) ?: "picked_${System.currentTimeMillis()}"
            val outDir = java.io.File(cacheDir, "picked")
            if (!outDir.exists()) outDir.mkdirs()
            val outFile = java.io.File(outDir, name)
            contentResolver.openInputStream(uri)?.use { input ->
                outFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            outFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) c.getString(idx) else null
                } else null
            }
        } catch (e: Exception) {
            null
        }
    }

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
                "ttsSetPitch" -> {
                    tts?.setPitch((call.argument<Double>("pitch") ?: 1.0).toFloat())
                    result.success(true)
                }
                "ttsGetVoices" -> {
                    initTts { ok ->
                        if (!ok) {
                            result.success(emptyList<Map<String, String>>())
                            return@initTts
                        }
                        try {
                            val voices = tts?.voices?.mapNotNull { v ->
                                mapOf(
                                    "name" to (v.name ?: ""),
                                    "locale" to (v.locale?.toLanguageTag() ?: ""),
                                )
                            }?.toList() ?: emptyList()
                            result.success(voices)
                        } catch (_: Exception) {
                            result.success(emptyList<Map<String, String>>())
                        }
                    }
                }
                "ttsSetVoice" -> {
                    val name = call.argument<String>("name") ?: ""
                    try {
                        val v = tts?.voices?.firstOrNull { it.name == name }
                        if (v != null) {
                            tts?.voice = v
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (_: Exception) {
                        result.success(false)
                    }
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
                "moveToBack" -> {
                    runOnUiThread {
                        moveTaskToBack(true)
                        result.success(true)
                    }
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
                "openPath" -> {
                    val path = call.argument<String>("path") ?: ""
                    runOnUiThread {
                        val ok = openFolderCompat(path)
                        result.success(ok)
                    }
                }
                "shareFiles" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    runOnUiThread {
                        try {
                            if (paths.isEmpty()) {
                                result.success(false)
                                return@runOnUiThread
                            }
                            val authority = "${packageName}.fileprovider"
                            val uris = ArrayList<android.net.Uri>()
                            for (p in paths) {
                                val f = java.io.File(p)
                                if (!f.exists()) continue
                                uris.add(
                                    androidx.core.content.FileProvider.getUriForFile(
                                        this, authority, f
                                    )
                                )
                            }
                            if (uris.isEmpty()) {
                                result.success(false)
                                return@runOnUiThread
                            }
                            val first = paths.first().lowercase()
                            val mime = when {
                                first.endsWith(".jmoe") -> "application/octet-stream"
                                first.endsWith(".json") -> "application/json"
                                else -> "image/*"
                            }
                            val send = if (uris.size == 1) {
                                Intent(Intent.ACTION_SEND).apply {
                                    type = mime
                                    putExtra(Intent.EXTRA_STREAM, uris[0])
                                }
                            } else {
                                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                                    type = mime
                                    putParcelableArrayListExtra(
                                        Intent.EXTRA_STREAM, uris
                                    )
                                }
                            }
                            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            val chooser = Intent.createChooser(send, "分享")
                                .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(chooser)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                }
                "setVolumeKeyPage" -> {
                    volumeKeyEnabled = call.argument<Boolean>("on") ?: false
                    result.success(true)
                }
                "notify" -> {
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    val id = call.argument<Int>("id") ?: 1
                    runOnUiThread {
                        result.success(postNotify(id, title, body))
                    }
                }
                "pickFile" -> {
                    val exts = call.argument<List<String>>("extensions") ?: emptyList()
                    val mime = call.argument<String>("mime")
                    pendingPickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = mime ?: "*/*"
                        if (mime == null && exts.isNotEmpty()) {
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                exts.map { e ->
                                    when (e.lowercase()) {
                                        "json" -> "application/json"
                                        else -> "*/*"
                                    }
                                }.toTypedArray()
                            )
                        }
                    }
                    try {
                        startActivityForResult(intent, REQ_PICK_FILE)
                    } catch (e: Exception) {
                        pendingPickResult?.error("PICK_FAILED", e.message, null)
                        pendingPickResult = null
                    }
                }
                "pickSavePath" -> {
                    val name = call.argument<String>("name") ?: "export.json"
                    pendingSaveResult = result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    try {
                        startActivityForResult(intent, REQ_SAVE_FILE)
                    } catch (e: Exception) {
                        pendingSaveResult?.error("SAVE_FAILED", e.message, null)
                        pendingSaveResult = null
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun openFolderCompat(path: String): Boolean {
        if (path.isEmpty()) return false
        val file = java.io.File(path)
        if (!file.exists()) return false

        val targetUri = buildDocUri(file)

        try {
            val i = Intent(Intent.ACTION_VIEW).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (targetUri != null) {
                    setDataAndType(
                        targetUri,
                        android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                    )
                    putExtra("android.provider.extra.INITIAL_URI", targetUri)
                }
            }
            startActivity(i)
            return true
        } catch (_: Throwable) {
        }

        try {
            val i = Intent(Intent.ACTION_VIEW).apply {
                setPackage("com.android.documentsui")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (targetUri != null) {
                    setDataAndType(
                        targetUri,
                        android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                    )
                    putExtra("android.provider.extra.INITIAL_URI", targetUri)
                }
            }
            startActivity(i)
            return true
        } catch (_: Throwable) {
        }

        try {
            val i = Intent(Intent.ACTION_VIEW).apply {
                if (targetUri != null) {
                    setDataAndType(
                        targetUri,
                        android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                    )
                } else {
                    setDataAndType(
                        android.net.Uri.parse("file://" + file.absolutePath),
                        "resource/folder"
                    )
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                putExtra("android.provider.extra.INITIAL_URI", targetUri)
                putExtra("explorer_path", file.absolutePath)
            }
            startActivity(i)
            return true
        } catch (_: Throwable) {
        }

        val pkgs = listOf(
            "com.mi.android.globalFileexplorer",
            "com.android.documentsui",
            "com.android.fileexplorer",
            "com.sec.android.app.myfiles",
            "com.oneplus.filemanager",
            "com.oppo.filemanager",
            "com.vivo.filemanager"
        )
        for (p in pkgs) {
            try {
                val i = Intent(Intent.ACTION_VIEW).apply {
                    setPackage(p)
                    setDataAndType(
                        android.net.Uri.parse("file://" + file.absolutePath),
                        "resource/folder"
                    )
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra("explorer_path", file.absolutePath)
                    putExtra("android.provider.extra.INITIAL_URI", targetUri)
                }
                startActivity(i)
                return true
            } catch (_: Throwable) {
            }
        }
        return false
    }

    private fun buildDocUri(file: java.io.File): android.net.Uri? {
        return try {
            val abs = file.absolutePath
            val rel = when {
                abs.startsWith("/storage/emulated/0/") ->
                    abs.removePrefix("/storage/emulated/0/")
                abs.startsWith("/sdcard/") -> abs.removePrefix("/sdcard/")
                else -> return null
            }
            android.net.Uri.parse(
                "content://com.android.externalstorage.documents/document/" +
                    android.net.Uri.encode("primary:$rel")
            )
        } catch (_: Throwable) {
            null
        }
    }
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (volumeKeyEnabled) {
            val code = event.keyCode
            if (code == android.view.KeyEvent.KEYCODE_VOLUME_DOWN ||
                code == android.view.KeyEvent.KEYCODE_VOLUME_UP
            ) {
                if (event.action == android.view.KeyEvent.ACTION_DOWN) {
                    val dir = if (
                        code == android.view.KeyEvent.KEYCODE_VOLUME_DOWN
                    ) 1 else -1
                    runOnUiThread {
                        channel?.invokeMethod("onVolumeKey", dir)
                    }
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun postNotify(id: Int, title: String, body: String): Boolean {
        return try {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                val perm = "android.permission.POST_NOTIFICATIONS"
                if (checkSelfPermission(perm) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(perm), 2001)
                    return false
                }
            }
            val mgr = getSystemService(NOTIFICATION_SERVICE)
                as android.app.NotificationManager
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                val ch = android.app.NotificationChannel(
                    "jmoe_updates",
                    "作品更新",
                    android.app.NotificationManager.IMPORTANCE_DEFAULT
                )
                mgr.createNotificationChannel(ch)
            }
            val builder = android.app.Notification.Builder(this)
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                builder.setChannelId("jmoe_updates")
            }
            val intent = android.content.Intent(
                this, MainActivity::class.java
            ).apply {
                addFlags(
                    android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
            }
            val pi = android.app.PendingIntent.getActivity(
                this, id, intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
            )
            builder
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentIntent(pi)
                .setAutoCancel(true)
            mgr.notify(id, builder.build())
            true
        } catch (e: Exception) {
            false
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
