package app.proview.proview

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** JNI bridge to ProView's own player (player.c): GPU ProRes decoding and 10-bit Vulkan output. */
object NativePlayer {
    init {
        System.loadLibrary("proview")
    }

    @JvmStatic external fun setTune(settings: String)
    @JvmStatic external fun create(): Long
    @JvmStatic external fun open(h: Long, path: String, audioPath: String): String?
    @JvmStatic external fun setSurface(h: Long, surface: android.view.Surface?, width: Int, height: Int)
    @JvmStatic external fun play(h: Long)
    @JvmStatic external fun pause(h: Long)
    @JvmStatic external fun seek(h: Long, sec: Double)
    @JvmStatic external fun step(h: Long, dir: Int)
    @JvmStatic external fun setRate(h: Long, rate: Double)
    @JvmStatic external fun setVolume(h: Long, volume: Float)
    @JvmStatic external fun setSmooth(h: Long, on: Boolean)
    @JvmStatic external fun state(h: Long): DoubleArray
    @JvmStatic external fun info(h: Long): String
    @JvmStatic external fun release(h: Long)
}

/**
 * The video layer. A single SurfaceView sits *under* the (transparent) Flutter UI, so video goes straight
 * to the display compositor (10-bit, no copies) and Flutter never has to compose a platform view.
 * Flutter positions it with "layout" and drives playback over the "proview/player" channel.
 */
class VideoStage(private val activity: Activity) {
    private interface Session {
        fun attach(holder: SurfaceHolder?)
        fun play()
        fun pause()
        fun seek(sec: Double)
        fun step(dir: Int)
        fun rate(rate: Double)
        fun volume(v: Double)
        fun loop(on: Boolean)
        fun state(): List<Any?>
        fun info(): Map<String, Any?>
        fun release()
    }

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val sessions = HashMap<Long, Session>()
    private var current: Long = 0
    private var nextId = 1L
    private var surfaceReady = false
    private val view: SurfaceView = SurfaceView(activity).apply { visibility = View.GONE }

    init {
        val root = activity.findViewById<FrameLayout>(android.R.id.content)
        root.addView(view, 0, FrameLayout.LayoutParams(1, 1))
        view.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {}
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                surfaceReady = true
                sessions[current]?.attach(holder)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surfaceReady = false
                sessions[current]?.attach(null)
            }
        })
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val id = (call.argument<Number>("id"))?.toLong() ?: 0L
        val s = sessions[id]
        when (call.method) {
            "open" -> open(call, result)
            "layout" -> {
                layout(
                    call.argument<Number>("x")?.toFloat() ?: 0f, call.argument<Number>("y")?.toFloat() ?: 0f,
                    call.argument<Number>("w")?.toInt() ?: 0, call.argument<Number>("h")?.toInt() ?: 0,
                )
                result.success(null)
            }
            "visible" -> {
                // INVISIBLE tears down the surface (the engine just stops drawing); VISIBLE brings it back.
                if (id == current) view.visibility = if (call.argument<Boolean>("visible") == false) View.INVISIBLE else View.VISIBLE
                result.success(null)
            }
            "play" -> done(result) { s?.play() }
            "pause" -> done(result) { s?.pause() }
            "seek" -> done(result) { s?.seek(call.argument<Double>("sec") ?: 0.0) }
            "step" -> done(result) { s?.step(call.argument<Int>("dir") ?: 1) }
            "rate" -> done(result) { s?.rate(call.argument<Double>("rate") ?: 1.0) }
            "volume" -> done(result) { s?.volume(call.argument<Double>("volume") ?: 1.0) }
            "loop" -> done(result) { s?.loop(call.argument<Boolean>("on") ?: false) }
            "state" -> result.success(s?.state())
            "info" -> result.success(s?.info())
            "release" -> {
                sessions.remove(id)?.let { session ->
                    session.attach(null)
                    session.release()
                }
                if (id == current) {
                    current = 0
                    view.visibility = View.GONE
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private inline fun done(result: MethodChannel.Result, block: () -> Unit) {
        block()
        result.success(null)
    }

    fun releaseAll() {
        sessions.values.forEach { it.release() }
        sessions.clear()
    }

    private fun layout(x: Float, y: Float, w: Int, h: Int) {
        val lp = view.layoutParams as FrameLayout.LayoutParams
        if (lp.width != max(1, w) || lp.height != max(1, h)) {
            lp.width = max(1, w)
            lp.height = max(1, h)
            view.layoutParams = lp
        }
        view.x = x
        view.y = y
    }

    private fun show(id: Long, session: Session) {
        sessions[current]?.attach(null)
        current = id
        view.visibility = View.VISIBLE
        if (surfaceReady) session.attach(view.holder)
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val uri = Uri.parse(call.argument<String>("uri"))
        val loop = call.argument<Boolean>("loop") ?: false
        val id = nextId++
        if (call.argument<String>("engine") == "system") {
            val session = ExoSession(activity, uri, loop)
            sessions[id] = session
            view.holder.setSizeFromLayout()
            show(id, session)
            result.success(mapOf("id" to id))
            return
        }
        val smooth = call.argument<Boolean>("smooth") ?: true
        io.execute {
            val h = NativePlayer.create()
            val error = try {
                // The engine dup()s descriptors, so they can be closed right after opening. Audio reads the file
                // through its own descriptor so it can read ahead independently of the video.
                activity.contentResolver.openFileDescriptor(uri, "r")!!.use { pfd ->
                    activity.contentResolver.openFileDescriptor(uri, "r")!!.use { pfd2 ->
                        NativePlayer.open(h, "fd:${pfd.fd}", "fd:${pfd2.fd}")
                    }
                }
            } catch (e: Exception) {
                e.message ?: "Couldn't open this file"
            }
            if (error != null) {
                NativePlayer.release(h)
                main.post { result.error("open", error, null) }
                return@execute
            }
            NativePlayer.setSmooth(h, smooth)
            val st = NativePlayer.state(h)
            main.post {
                val session = NativeSession(h, io)
                sessions[id] = session
                // Render at the video's size, capped to the screen: the compositor scales it into place.
                val metrics = activity.resources.displayMetrics
                val screen = max(metrics.widthPixels, metrics.heightPixels).toDouble()
                val vw = st[5].coerceAtLeast(2.0)
                val vh = st[6].coerceAtLeast(2.0)
                val scale = min(1.0, screen / max(vw, vh))
                view.holder.setFixedSize(((vw * scale).roundToInt() / 2) * 2, ((vh * scale).roundToInt() / 2) * 2)
                show(id, session)
                result.success(mapOf("id" to id))
            }
        }
    }

    /** ProView's engine. */
    private class NativeSession(val h: Long, val io: java.util.concurrent.Executor) : Session {
        @Volatile private var released = false

        override fun attach(holder: SurfaceHolder?) {
            if (released) return
            val frame = holder?.surfaceFrame
            NativePlayer.setSurface(h, holder?.surface, frame?.width() ?: 0, frame?.height() ?: 0)
        }

        override fun play() = NativePlayer.play(h)
        override fun pause() = NativePlayer.pause(h)
        override fun seek(sec: Double) = NativePlayer.seek(h, sec)
        override fun step(dir: Int) = NativePlayer.step(h, dir)
        override fun rate(rate: Double) = NativePlayer.setRate(h, rate)
        override fun volume(v: Double) = NativePlayer.setVolume(h, v.toFloat())
        override fun loop(on: Boolean) {}
        override fun state(): List<Any?> = NativePlayer.state(h).toList() + listOf<Any?>(null)
        override fun info(): Map<String, Any?> {
            val o = JSONObject(NativePlayer.info(h))
            return mapOf(
                "engine" to "proview",
                "decode" to o.optString("decode"),
                "output" to o.optString("output"),
                "bits" to o.optInt("bits"),
                "stage" to o.optInt("stage"),
                "threads" to o.optInt("threads"),
                "headroom" to o.optDouble("headroom"),
            )
        }

        override fun release() {
            released = true
            io.execute { NativePlayer.release(h) }
        }
    }

    /** Android's own player (hardware decoder) for files the phone plays natively. */
    private class ExoSession(context: Context, uri: Uri, loop: Boolean) : Session {
        private val player = ExoPlayer.Builder(context).build()
        private var error: String? = null
        private var size = VideoSize.UNKNOWN

        init {
            player.addListener(object : Player.Listener {
                override fun onPlayerError(e: PlaybackException) {
                    error = e.message ?: "Playback error"
                }

                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    size = videoSize
                }
            })
            player.setSeekParameters(SeekParameters.EXACT)
            player.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            player.setMediaItem(MediaItem.fromUri(uri))
            player.prepare()
        }

        override fun attach(holder: SurfaceHolder?) {
            if (holder == null) player.clearVideoSurface() else player.setVideoSurfaceHolder(holder)
        }

        override fun play() {
            if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
            player.play()
        }

        override fun pause() = player.pause()
        override fun seek(sec: Double) = player.seekTo((sec * 1000).toLong())
        override fun step(dir: Int) {
            player.pause()
            val fps = player.videoFormat?.frameRate?.takeIf { it > 0 } ?: 30f
            player.seekTo(max(0L, player.currentPosition + (dir * 1000 / fps).toLong()))
        }

        override fun rate(rate: Double) {
            player.playbackParameters = PlaybackParameters(rate.toFloat())
        }

        override fun volume(v: Double) {
            player.volume = v.toFloat()
        }

        override fun loop(on: Boolean) {
            player.repeatMode = if (on) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        }

        override fun state(): List<Any?> {
            val state = player.playbackState
            val dur = if (player.duration == C.TIME_UNSET) 0.0 else player.duration / 1000.0
            val w = size.width * (if (size.pixelWidthHeightRatio > 0) size.pixelWidthHeightRatio else 1f)
            val counters = player.videoDecoderCounters
            return listOf(
                player.currentPosition / 1000.0, dur,
                if (player.isPlaying) 1.0 else 0.0,
                if (state == Player.STATE_BUFFERING || state == Player.STATE_IDLE && error == null) 1.0 else 0.0,
                if (state == Player.STATE_ENDED) 1.0 else 0.0,
                w.toDouble(), size.height.toDouble(),
                (counters?.droppedBufferCount ?: 0).toDouble(),
                error,
            )
        }

        override fun info(): Map<String, Any?> {
            val f = player.videoFormat
            return mapOf(
                "engine" to "system",
                "decode" to "hardware",
                "output" to "hardware",
                "bits" to if ((f?.colorInfo?.lumaBitdepth ?: 8) > 8) 10 else 8,
            )
        }

        override fun release() = player.release()
    }
}
