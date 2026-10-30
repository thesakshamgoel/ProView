package app.proview.proview

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ConcurrentHashMap

/** Background tasks started on the Android side (conversions, cloud downloads), streamed to Flutter. */
object TaskHub {
    private val main = Handler(Looper.getMainLooper())
    private val tasks = ConcurrentHashMap<String, MutableMap<String, Any?>>()
    private var sink: EventChannel.EventSink? = null

    val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            sink = events
            tasks.values.forEach { t -> events.success(HashMap(t)) }
        }

        override fun onCancel(arguments: Any?) {
            sink = null
        }
    }

    fun update(id: String, vararg fields: Pair<String, Any?>) {
        val task = tasks.getOrPut(id) { mutableMapOf("id" to id, "createdAt" to System.currentTimeMillis()) }
        synchronized(task) {
            fields.forEach { (k, v) -> task[k] = v }
        }
        val snapshot = synchronized(task) { HashMap(task) }
        main.post { sink?.success(snapshot) }
    }

    fun get(id: String): Map<String, Any?>? = tasks[id]?.let { synchronized(it) { HashMap(it) } }

    fun remove(id: String) {
        tasks.remove(id)
        main.post { sink?.success(mapOf("id" to id, "removed" to true)) }
    }

    fun all(): List<Map<String, Any?>> = tasks.values.map { synchronized(it) { HashMap(it) } }
}
