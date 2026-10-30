package app.proview.proview

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.IntentFilter
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var sources: MediaSources
    private lateinit var channel: MethodChannel
    private lateinit var stage: VideoStage
    // Background threads: reading and thumbnailing a big library must never compete with scrolling.
    private val background = java.util.concurrent.ThreadFactory { r ->
        Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }
    }
    private val io = Executors.newFixedThreadPool(3, background)
    private val analysis = Executors.newFixedThreadPool(2, background)
    // One at a time: image understanding is heavy and should never compete with scrolling or playback.
    private val tagging = Executors.newSingleThreadExecutor(background)
    private val tagger by lazy { Tagger() }
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val releaseTagger = Runnable { tagging.execute { tagger.close() } }
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingPick: MethodChannel.Result? = null
    private var pendingUri: String? = null
    private var pendingTrash: MethodChannel.Result? = null

    companion object {
        private const val REQ_PERMISSION = 10
        private const val REQ_NOTIFICATIONS = 11
        private const val REQ_TREE = 20
        private const val REQ_DOCUMENT = 21
        private const val REQ_TRASH = 30
    }

    // Flutter draws on its own transparent SurfaceView (kept above the window), so the video layer
    // underneath shows through wherever Flutter paints nothing. A SurfaceView rather than the
    // TextureView Flutter picks for transparent activities: it composites in hardware and stays smooth.
    override fun getRenderMode() = RenderMode.surface
    override fun getTransparencyMode() = TransparencyMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        stage = VideoStage(this)
        stageChannel?.setMethodCallHandler { call, result -> stage.handle(call, result) }
        pendingUri = uriFromIntent(intent)
        requestSmoothestDisplayMode()
        ContextCompat.registerReceiver(
            this, powerSaveReceiver, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    override fun onResume() {
        super.onResume()
        requestSmoothestDisplayMode()
    }

    /**
     * Asks Android for the display's fastest refresh rate at the current resolution (120 Hz on a Galaxy S24),
     * except while power saving is on, when it leaves the choice to the system so the battery isn't spent on it.
     */
    @Suppress("DEPRECATION")
    private fun requestSmoothestDisplayMode() {
        try {
            val display = windowManager.defaultDisplay ?: return
            val current = display.mode
            val best = display.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .maxByOrNull { it.refreshRate } ?: return
            val saving = getSystemService(PowerManager::class.java)?.isPowerSaveMode == true
            val want = if (saving) 0 else best.modeId // 0 = no preference
            val lp = window.attributes
            if (lp.preferredDisplayModeId != want) {
                lp.preferredDisplayModeId = want
                window.attributes = lp
            }
        } catch (_: Exception) {
        }
    }

    // Switching power saving on or off re-picks the refresh rate straight away.
    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = requestSmoothestDisplayMode()
    }

    private var stageChannel: MethodChannel? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        uriFromIntent(intent)?.let { channel.invokeMethod("openUri", it) }
    }

    private fun uriFromIntent(intent: Intent?): String? {
        intent ?: return null
        // Developer hook for tuning experiments: --es tune "threads=8,adpf=0"
        intent.getStringExtra("tune")?.let { NativePlayer.setTune(it) }
        intent.getStringExtra(ConvertService.EXTRA_OPEN_URI)?.let { return it }
        if (intent.action == Intent.ACTION_VIEW) return intent.data?.toString()
        if (intent.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            return (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.toString()
        }
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sources = MediaSources(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "proview/tasks").setStreamHandler(TaskHub.streamHandler)
        channel = MethodChannel(messenger, "proview/engine")
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        // The stage needs the content view, which exists only after onCreate; it hooks itself up there.
        stageChannel = MethodChannel(messenger, "proview/player")
    }

    private fun background(result: MethodChannel.Result, pool: java.util.concurrent.ExecutorService = io, work: () -> Any?) {
        pool.execute {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: SecurityException) {
                runOnUiThread { result.error("permission", "ProView no longer has access to this file", null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("failed", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialUri" -> {
                result.success(pendingUri)
                pendingUri = null
            }
            "permissionState" -> result.success(permissionState())
            "requestPermission" -> requestMediaPermission(result)
            "openAppSettings" -> {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                result.success(null)
            }
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
                }
                result.success(null)
            }
            "queryLibrary" -> background(result) { sources.queryMediaStore() }
            "queryTrash" -> background(result) { sources.queryTrash() }
            "trash" -> askSystem(result, call.argument<List<String>>("uris").orEmpty(), call.argument<Boolean>("trash") != false)
            "deleteForever" -> askSystem(result, call.argument<List<String>>("uris").orEmpty(), null)
            "deleteDocuments" -> background(result) {
                // Files on a drive or in a picked folder have no bin: they are removed for good.
                var deleted = 0
                for (u in call.argument<List<String>>("uris").orEmpty()) {
                    try {
                        if (DocumentsContract.deleteDocument(contentResolver, Uri.parse(u))) deleted++
                    } catch (_: Exception) {
                    }
                }
                deleted
            }
            "shareMany" -> {
                val uris = ArrayList(call.argument<List<String>>("uris").orEmpty().map { Uri.parse(it) })
                val send = Intent(Intent.ACTION_SEND_MULTIPLE).setType("video/*")
                    .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "Share"))
                result.success(null)
            }
            "brightness" -> {
                val v = call.argument<Double>("value")
                val lp = window.attributes
                if (call.argument<Boolean>("reset") == true) {
                    // Back to whatever the system brightness slider says.
                    lp.screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    window.attributes = lp
                } else if (v != null) {
                    lp.screenBrightness = v.toFloat().coerceIn(0.01f, 1f)
                    window.attributes = lp
                }
                result.success(currentBrightness())
            }
            "volume" -> {
                val am = getSystemService(android.media.AudioManager::class.java)
                val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                val v = call.argument<Double>("value")
                if (v != null) am.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, (v * max).toInt().coerceIn(0, max), 0)
                result.success(am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC).toDouble() / max)
            }
            "listTree" -> background(result) { sources.listTree(Uri.parse(call.argument<String>("uri"))) }
            "describe" -> background(result) { sources.describeDocument(Uri.parse(call.argument<String>("uri"))) }
            "pickFolder" -> {
                pendingPick = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                startActivityForResult(intent, REQ_TREE)
            }
            "pickFile" -> {
                pendingPick = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*")
                    .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "application/octet-stream", "application/mxf"))
                startActivityForResult(intent, REQ_DOCUMENT)
            }
            "releaseFolder" -> {
                try {
                    contentResolver.releasePersistableUriPermission(
                        Uri.parse(call.argument<String>("uri")), Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "tagImage" -> background(result, tagging) {
                val tags = tagger.tag(call.argument<String>("path") ?: "")
                // Let the models go once there is nothing left to look at.
                mainHandler.removeCallbacks(releaseTagger)
                mainHandler.postDelayed(releaseTagger, 20_000)
                tags
            }
            "analyze" -> background(result, analysis) { sources.analyze(Uri.parse(call.argument<String>("uri"))) }
            "thumbnail" -> background(result) {
                sources.thumbnail(
                    Uri.parse(call.argument<String>("uri")), call.argument<String>("key")!!,
                    call.argument<Double>("duration") ?: 0.0, call.argument<Int>("rotation") ?: 0,
                    call.argument<Boolean>("preferSystem") ?: false,
                )
            }
            "cacheKey" -> result.success(
                sources.cacheKey(
                    call.argument<String>("uri")!!, (call.argument<Number>("size") ?: 0).toLong(),
                    (call.argument<Number>("modified") ?: 0).toLong(),
                ),
            )
            "decodeSpeed" -> background(result, analysis) {
                sources.withEnginePath(Uri.parse(call.argument<String>("uri"))) { NativeEngine.decodeSpeed(it) }
            }
            "isSeekable" -> background(result) { sources.isSeekable(Uri.parse(call.argument<String>("uri"))) }
            "cacheDocument" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                val name = call.argument<String>("name") ?: "Video"
                val id = call.argument<String>("taskId")!!
                background(result) {
                    TaskHub.update(id, "type" to "download", "state" to "running", "title" to name, "progress" to 0.0,
                        "detail" to "Downloading")
                    try {
                        var last = 0L
                        val file = sources.copyToCache(uri, name) { done, total ->
                            val now = System.currentTimeMillis()
                            if (now - last > 250) {
                                last = now
                                val p = if (total > 0) done.toDouble() / total else 0.0
                                TaskHub.update(id, "progress" to p,
                                    "detail" to "Downloading ${done / 1_000_000} of ${total / 1_000_000} MB")
                            }
                        }
                        TaskHub.update(id, "state" to "done", "progress" to 1.0, "detail" to "Downloaded")
                        Uri.fromFile(file).toString()
                    } catch (e: Exception) {
                        TaskHub.update(id, "state" to "failed", "error" to (e.message ?: "Download failed"),
                            "detail" to (e.message ?: "Download failed"))
                        throw e
                    }
                }
            }
            "detachFd" -> background(result) { sources.detachFd(Uri.parse(call.argument<String>("uri"))) }
            "convert" -> {
                ConvertService.enqueue(
                    this,
                    ConvertService.Job(
                        call.argument<String>("taskId")!!, Uri.parse(call.argument<String>("uri")),
                        call.argument<String>("name") ?: "Video", call.argument<Double>("duration") ?: 0.0,
                        call.argument<Int>("videoBitrate")!!, call.argument<Int>("audioBitrate") ?: 320_000,
                    ),
                )
                result.success(null)
            }
            "cancelAllConvert" -> {
                ConvertService.cancelAll(this)
                result.success(null)
            }
            "cancelConvert" -> {
                ConvertService.cancel(this, call.argument<String>("taskId")!!)
                result.success(null)
            }
            "dismissTask" -> {
                TaskHub.remove(call.argument<String>("taskId")!!)
                result.success(null)
            }
            "tasks" -> result.success(TaskHub.all())
            "deviceInfo" -> background(result) {
                mapOf(
                    "model" to Build.MODEL,
                    "manufacturer" to Build.MANUFACTURER,
                    "android" to Build.VERSION.RELEASE,
                    "sdk" to Build.VERSION.SDK_INT,
                    "cores" to Runtime.getRuntime().availableProcessors(),
                    // FFmpeg's GPU ProRes decoder needs Vulkan 1.3.
                    "gpuDecode" to packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION, 0x403000),
                    "tenBitEncoder" to Playability.encoderSupportsTenBit(),
                    "maxBitrate" to Playability.encoderMaxBitrate(),
                    "freeBytes" to StatFs(cacheDir.path).availableBytes,
                )
            }
            "share" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                val send = Intent(Intent.ACTION_SEND).setType(call.argument<String>("mime") ?: "video/*")
                    .putExtra(Intent.EXTRA_STREAM, uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                send.clipData = ClipData.newRawUri("", uri)
                startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "Share"))
                result.success(null)
            }
            "openExternally" -> {
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(call.argument<String>("uri")), "video/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    )
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                }
            }
            "clearThumbnails" -> background(result) { sources.clearThumbnails() }
            "keepScreenOn" -> {
                if (call.argument<Boolean>("on") == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The window's brightness 0..1 (the system's own level when this app hasn't overridden it). */
    private fun currentBrightness(): Double {
        val set = window.attributes.screenBrightness
        if (set >= 0) return set.toDouble()
        return try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
        } catch (_: Exception) {
            0.5
        }
    }

    /**
     * Moves videos to the bin (trash = true), restores them (false) or deletes them for good (null).
     * Android shows its own confirmation, which is also what makes this allowed for files ProView doesn't own.
     */
    private fun askSystem(result: MethodChannel.Result, uris: List<String>, trash: Boolean?) {
        if (uris.isEmpty()) {
            result.success(true)
            return
        }
        try {
            val list = uris.map { Uri.parse(it) }
            val request = if (trash == null) MediaStore.createDeleteRequest(contentResolver, list)
            else MediaStore.createTrashRequest(contentResolver, list, trash)
            pendingTrash?.success(false)
            pendingTrash = result
            startIntentSenderForResult(request.intentSender, REQ_TRASH, null, 0, 0, 0)
        } catch (e: Exception) {
            result.error("failed", e.message ?: "Couldn't ask Android to do that", null)
        }
    }

    // ---- Permissions -----------------------------------------------------------------------

    private fun mediaPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        )
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    private fun permissionState(): String {
        val full = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_VIDEO
        else Manifest.permission.READ_EXTERNAL_STORAGE
        if (checkSelfPermission(full) == PackageManager.PERMISSION_GRANTED) return "granted"
        if (Build.VERSION.SDK_INT >= 34 &&
            checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
        ) return "partial"
        return "denied"
    }

    private fun requestMediaPermission(result: MethodChannel.Result) {
        if (permissionState() == "granted") {
            result.success("granted")
            return
        }
        pendingPermission = result
        requestPermissions(mediaPermissions(), REQ_PERMISSION)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_PERMISSION) {
            pendingPermission?.success(permissionState())
            pendingPermission = null
        }
    }

    // ---- Pickers ---------------------------------------------------------------------------

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_TRASH) {
            pendingTrash?.success(resultCode == RESULT_OK)
            pendingTrash = null
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        when (requestCode) {
            REQ_TREE -> {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                val docUri = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
                result.success(mapOf("uri" to uri.toString(), "name" to (sources.documentName(docUri) ?: "Folder")))
            }
            REQ_DOCUMENT -> {
                try {
                    contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: SecurityException) {
                }
                result.success(uri.toString())
            }
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(powerSaveReceiver) }
        if (::stage.isInitialized) stage.releaseAll()
        io.shutdown()
        analysis.shutdown()
        super.onDestroy()
    }
}
