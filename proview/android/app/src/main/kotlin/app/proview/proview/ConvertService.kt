package app.proview.proview

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingDeque

/** Runs "Make phone-playable" conversions one at a time in a foreground service. */
class ConvertService : Service() {

    data class Job(
        val id: String, val uri: Uri, val name: String, val durationSec: Double,
        val videoBitrate: Int, val audioBitrate: Int,
    )

    companion object {
        private const val CHANNEL_PROGRESS = "conversion_progress"
        private const val CHANNEL_RESULT = "conversion_result"
        private const val ONGOING_ID = 1
        private const val ACTION_ENQUEUE = "app.proview.ENQUEUE"
        private const val ACTION_CANCEL = "app.proview.CANCEL"
        private const val ACTION_CANCEL_ALL = "app.proview.CANCEL_ALL"
        private const val BRAND = 0xFF2F6BF2.toInt()
        const val EXTRA_OPEN_URI = "openUri"

        fun enqueue(context: Context, job: Job) {
            val intent = Intent(context, ConvertService::class.java).setAction(ACTION_ENQUEUE)
                .putExtra("id", job.id).putExtra("uri", job.uri.toString()).putExtra("name", job.name)
                .putExtra("duration", job.durationSec).putExtra("vb", job.videoBitrate).putExtra("ab", job.audioBitrate)
            context.startForegroundService(intent)
        }

        fun cancelAll(context: Context) {
            context.startService(Intent(context, ConvertService::class.java).setAction(ACTION_CANCEL_ALL))
        }

        fun cancel(context: Context, id: String) {
            context.startService(Intent(context, ConvertService::class.java).setAction(ACTION_CANCEL).putExtra("id", id))
        }

        fun outputName(name: String) = name.substringBeforeLast('.') + " (ProView).mp4"
    }

    private val queue = LinkedBlockingDeque<Job>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private var worker: Thread? = null
    @Volatile private var currentId: String? = null
    @Volatile private var encoderLabel = ""
    private var startedAtMs = 0L
    private var lastNotify = 0L
    private lateinit var sources: MediaSources
    private lateinit var notifications: NotificationManager

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        sources = MediaSources(this)
        notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_PROGRESS, "Conversion progress", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Live progress while ProView makes phone-playable copies"
                setShowBadge(false)
            }
        )
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_RESULT, "Finished conversions", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Tells you when a copy is ready or a conversion fails"
            }
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ENQUEUE -> {
                val job = Job(
                    intent.getStringExtra("id")!!, Uri.parse(intent.getStringExtra("uri")),
                    intent.getStringExtra("name") ?: "Video", intent.getDoubleExtra("duration", 0.0),
                    intent.getIntExtra("vb", 80_000_000), intent.getIntExtra("ab", 320_000),
                )
                goForeground(ongoingNotification(job.name, "Waiting to start", -1, ""))
                TaskHub.update(
                    job.id, "type" to "convert", "state" to "queued", "title" to job.name,
                    "sourceUri" to job.uri.toString(), "progress" to 0.0, "detail" to "Waiting to start",
                )
                queue.add(job)
                ensureWorker()
            }
            ACTION_CANCEL -> {
                val id = intent.getStringExtra("id") ?: return START_NOT_STICKY
                if (currentId == id) {
                    cancelled.add(id)
                    NativeEngine.cancelConvert()
                } else if (queue.removeIf { it.id == id }) {
                    TaskHub.update(id, "state" to "cancelled", "detail" to "Cancelled")
                }
                if (worker == null) stopSelf()
            }
            ACTION_CANCEL_ALL -> {
                val waiting = queue.toList()
                queue.clear()
                waiting.forEach { TaskHub.update(it.id, "state" to "cancelled", "detail" to "Cancelled") }
                currentId?.let {
                    cancelled.add(it)
                    NativeEngine.cancelConvert()
                }
                if (worker == null) stopSelf()
            }
            else -> if (worker == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun goForeground(notification: Notification) {
        val type = if (Build.VERSION.SDK_INT >= 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
        else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        startForeground(ONGOING_ID, notification, type)
    }

    @Synchronized
    private fun ensureWorker() {
        if (worker != null) return
        worker = Thread({
            while (true) {
                val job = synchronized(this) {
                    queue.poll() ?: run {
                        worker = null
                        null
                    }
                } ?: break
                run(job)
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }, "ProView-convert").apply { start() }
    }

    private fun run(job: Job) {
        currentId = job.id
        val wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ProView:convert").apply { acquire(6 * 3600_000L) }
        val tmpDir = File(cacheDir, "convert").apply { mkdirs() }
        val tmp = File(tmpDir, "${job.id}.mp4")
        try {
            val estimate = ((job.videoBitrate + job.audioBitrate) / 8.0 * job.durationSec * 1.1).toLong()
            val free = StatFs(cacheDir.path).availableBytes
            if (job.durationSec > 0 && free < estimate * 2) {
                fail(job, "Not enough free space. This conversion needs about ${gb(estimate * 2)} free; you have ${gb(free)}.")
                return
            }

            TaskHub.update(job.id, "state" to "running", "progress" to 0.0, "detail" to "Starting the encoder")
            val started = System.currentTimeMillis()
            startedAtMs = started
            encoderLabel = ""
            updateOngoing(job.name, "Starting", 0, "", force = true)
            val error = try {
                sources.withEnginePath(job.uri) { path ->
                    NativeEngine.convert(path, tmp.absolutePath, job.videoBitrate, job.audioBitrate,
                        object : NativeEngine.ConvertListener {
                            override fun onProgress(doneSec: Double, totalSec: Double, fps: Double) {
                                val total = if (totalSec > 0) totalSec else job.durationSec
                                val fraction = if (total > 0) (doneSec / total).coerceIn(0.0, 1.0) else 0.0
                                val elapsed = (System.currentTimeMillis() - started) / 1000.0
                                val eta = if (fraction > 0.02) elapsed * (1 - fraction) / fraction else -1.0
                                val detail = "${(fraction * 100).toInt()}% · ${"%.0f".format(fps)} fps" +
                                    (if (eta >= 0) " · ${duration(eta)} left" else "")
                                TaskHub.update(job.id, "progress" to fraction, "fps" to fps, "eta" to eta, "detail" to detail)
                                val extra = buildString {
                                    append("${(fraction * 100).toInt()}% done")
                                    if (eta >= 0) append(" · about ${duration(eta)} left")
                                    append("\n${"%.0f".format(fps)} frames per second")
                                    if (encoderLabel.isNotEmpty()) append(" · $encoderLabel")
                                }
                                updateOngoing(job.name, detail, (fraction * 100).toInt(), extra)
                            }

                            override fun onEncoder(name: String, bitDepth: Int) {
                                val size = name.substringAfter('@', "").replace("x", " × ")
                                encoderLabel = "$bitDepth-bit HEVC" + (if (size.isNotEmpty()) " at $size" else "")
                                TaskHub.update(job.id, "encoder" to name, "bitDepth" to bitDepth)
                            }
                        })
                }
            } catch (e: Exception) {
                e.message ?: "Couldn't read the video"
            }

            when {
                error == "cancelled" || cancelled.remove(job.id) -> {
                    TaskHub.update(job.id, "state" to "cancelled", "detail" to "Cancelled")
                }
                error != null -> fail(job, error)
                else -> {
                    TaskHub.update(job.id, "state" to "saving", "progress" to 1.0, "detail" to "Saving to Gallery")
                    updateOngoing(job.name, "Saving to Gallery", -1, "Almost done", force = true)
                    val out = saveToGallery(tmp, outputName(job.name))
                    val seconds = (System.currentTimeMillis() - started) / 1000.0
                    TaskHub.update(
                        job.id, "state" to "done", "outputUri" to out.toString(), "outputSize" to tmp.length(),
                        "outputName" to outputName(job.name), "seconds" to seconds,
                        "detail" to "Saved to Gallery › ProView · ${gb(tmp.length())}",
                    )
                    val took = duration(seconds)
                    notifyResult(
                        job, "Ready to play",
                        "${job.name}\nPhone-playable copy · ${gb(tmp.length())} · made in $took. It's in Gallery › ProView.", out,
                    )
                }
            }
        } catch (e: Exception) {
            fail(job, e.message ?: "Something went wrong")
        } finally {
            tmp.delete()
            currentId = null
            if (wake.isHeld) wake.release()
        }
    }

    private fun fail(job: Job, message: String) {
        TaskHub.update(job.id, "state" to "failed", "error" to message, "detail" to message)
        notifyResult(job, "Couldn't convert ${job.name}", message, null)
    }

    private fun saveToGallery(file: File, name: String): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/ProView")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = contentResolver.insert(collection, values) ?: throw IllegalStateException("Couldn't save to Gallery")
        try {
            contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out, 1 shl 20) } }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null)
            throw IllegalStateException("Couldn't save to Gallery: ${e.message}")
        }
        return uri
    }

    private fun action(label: String, intent: PendingIntent) = NotificationCompat.Action.Builder(0, label, intent).build()

    private fun cancelIntent(id: String): PendingIntent = PendingIntent.getService(
        this, id.hashCode(),
        Intent(this, ConvertService::class.java).setAction(ACTION_CANCEL).putExtra("id", id),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun ongoingNotification(title: String, text: String, percent: Int, big: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val waiting = queue.size
        val builder = NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat_proview)
            .setColor(BRAND)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentTitle(title)
            .setContentText(text)
            .setSubText(if (waiting > 0) "Making copy · $waiting more waiting" else "Making a phone-playable copy")
            .setStyle(NotificationCompat.BigTextStyle().bigText(if (big.isNotEmpty()) big else text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (startedAtMs > 0) builder.setWhen(startedAtMs).setShowWhen(true).setUsesChronometer(true)
        currentId?.let { id ->
            builder.addAction(action("Stop", cancelIntent(id)))
            if (waiting > 0) {
                builder.addAction(
                    action(
                        "Stop all",
                        PendingIntent.getService(
                            this, 7, Intent(this, ConvertService::class.java).setAction(ACTION_CANCEL_ALL),
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                        ),
                    ),
                )
            }
        }
        if (percent >= 0) builder.setProgress(100, percent, false) else builder.setProgress(0, 0, true)
        return builder.build()
    }

    private fun updateOngoing(title: String, text: String, percent: Int, big: String, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - lastNotify < 1000) return
        lastNotify = now
        notifications.notify(ONGOING_ID, ongoingNotification(title, text, percent, big))
    }

    private fun notifyResult(job: Job, title: String, text: String, output: Uri?) {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        output?.let { intent.putExtra(EXTRA_OPEN_URI, it.toString()) }
        val open = PendingIntent.getActivity(
            this, job.id.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_RESULT)
            .setSmallIcon(R.drawable.ic_stat_proview)
            .setColor(BRAND)
            .setCategory(if (output != null) NotificationCompat.CATEGORY_STATUS else NotificationCompat.CATEGORY_ERROR)
            .setContentTitle(title)
            .setContentText(text.lineSequence().first())
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(open)
        if (output != null) {
            builder.addAction(action("Play", open))
            val send = Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, output)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val chooser = Intent.createChooser(send, "Share ${job.name}").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.addAction(
                action(
                    "Share",
                    PendingIntent.getActivity(
                        this, job.id.hashCode() + 1, chooser, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                ),
            )
        }
        notifications.notify(job.id.hashCode(), builder.build())
    }

    private fun gb(bytes: Long): String =
        if (bytes >= 1_000_000_000) "%.1f GB".format(bytes / 1e9) else "${bytes / 1_000_000} MB"

    private fun duration(sec: Double): String {
        val s = sec.toInt()
        return if (s >= 60) "${s / 60} min ${s % 60} s" else "$s s"
    }
}
