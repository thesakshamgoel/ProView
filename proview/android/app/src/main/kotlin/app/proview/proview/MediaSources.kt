package app.proview.proview

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import android.util.Size
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest

/** Finds videos (MediaStore, picked folders/drives, single documents) and reads them through the engine. */
class MediaSources(private val context: Context) {

    private val resolver get() = context.contentResolver

    companion object {
        val VIDEO_EXTENSIONS = setOf("mov", "mp4", "m4v", "mkv", "mxf", "avi", "mts", "m2ts", "ts", "webm", "3gp")
        private const val THUMB_SIDE = 512
        private val thumbBuffer = ThreadLocal.withInitial { ByteBuffer.allocateDirect(THUMB_SIDE * THUMB_SIDE * 4) }
    }

    // ---- Listing ---------------------------------------------------------------------------

    /** Videos in the system bin (what Samsung Gallery calls the Recycle bin), with when each is purged. */
    fun queryTrash(): List<Map<String, Any?>> = queryMediaStore(trashed = true)

    fun queryMediaStore(trashed: Boolean = false): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_MODIFIED,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Video.Media.RELATIVE_PATH,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
        ).let { if (android.os.Build.VERSION.SDK_INT >= 30) it + MediaStore.Video.Media.DATE_EXPIRES else it }
        val args = android.os.Bundle().apply {
            putStringArray(android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Video.Media.DATE_MODIFIED))
            putInt(android.content.ContentResolver.QUERY_ARG_SORT_DIRECTION, android.content.ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, if (trashed) MediaStore.MATCH_ONLY else MediaStore.MATCH_EXCLUDE)
            }
        }
        resolver.query(collection, projection, args, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val uri = ContentUris.withAppendedId(collection, id)
                out += mapOf(
                    "uri" to uri.toString(),
                    "name" to (c.getString(1) ?: "Video"),
                    "size" to c.getLong(2),
                    "modified" to c.getLong(3) * 1000,
                    "durationMs" to c.getLong(4),
                    "folder" to (c.getString(5) ?: ""),
                    "path" to (c.getString(6) ?: ""),
                    "width" to c.getInt(7),
                    "height" to c.getInt(8),
                    "source" to "device",
                    "expires" to (if (c.columnCount > 9 && !c.isNull(9)) c.getLong(9) * 1000 else 0L),
                )
            }
        }
        return out
    }

    /** Recursively lists videos inside a folder or drive the user picked with the system picker. */
    fun listTree(treeUri: Uri, limit: Int = 5000): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootName = documentName(DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)) ?: "Folder"
        val queue = ArrayDeque<Pair<String, String>>()
        queue += rootId to rootName
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        var visited = 0
        while (queue.isNotEmpty() && out.size < limit && visited < 20000) {
            val (docId, folderName) = queue.removeFirst()
            visited++
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            resolver.query(children, projection, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (!name.startsWith(".")) queue += id to name
                        continue
                    }
                    if (!mime.startsWith("video/") && name.substringAfterLast('.', "").lowercase() !in VIDEO_EXTENSIONS) continue
                    out += mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString(),
                        "name" to name,
                        "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
                        "modified" to (if (c.isNull(4)) 0L else c.getLong(4)),
                        "durationMs" to 0L,
                        "folder" to folderName,
                        "path" to "",
                        "width" to 0,
                        "height" to 0,
                        "source" to "tree",
                    )
                }
            }
        }
        return out
    }

    fun documentName(uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    fun describeDocument(uri: Uri): Map<String, Any?> {
        var name = uri.lastPathSegment ?: "Video"
        var size = 0L
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        } catch (_: Exception) {
        }
        return mapOf(
            "uri" to uri.toString(), "name" to name, "size" to size, "modified" to System.currentTimeMillis(),
            "durationMs" to 0L, "folder" to "Opened files", "path" to "", "width" to 0, "height" to 0,
            "source" to "document",
        )
    }

    // ---- Reading ---------------------------------------------------------------------------

    /** Runs [block] with an engine path ("fd:<n>") for [uri]; the descriptor is closed afterwards. */
    fun <T> withEnginePath(uri: Uri, block: (String) -> T): T {
        val pfd = resolver.openFileDescriptor(uri, "r") ?: throw IllegalStateException("Couldn't open the file")
        pfd.use { return block("fd:${it.fd}") }
    }

    /** True if [uri] can be read with random access (cloud providers may hand out a one-way stream). */
    fun isSeekable(uri: Uri): Boolean = try {
        resolver.openFileDescriptor(uri, "r")?.use { pfd ->
            Os.lseek(pfd.fileDescriptor, 0, OsConstants.SEEK_END) > 0
        } ?: false
    } catch (e: Exception) {
        false
    }

    /** A detached descriptor for the preview player (mpv takes ownership via fdclose://). */
    fun detachFd(uri: Uri): Int {
        val pfd = resolver.openFileDescriptor(uri, "r") ?: throw IllegalStateException("Couldn't open the file")
        return pfd.detachFd()
    }

    fun cacheKey(uri: String, size: Long, modified: Long): String {
        val digest = MessageDigest.getInstance("SHA-1").digest("$uri|$size|$modified".toByteArray())
        return digest.joinToString("") { "%02x".format(it) }.take(24)
    }

    /** Probes the file and decides whether this phone can play it natively. */
    fun analyze(uri: Uri): Map<String, Any?> {
        val json = withEnginePath(uri) { NativeEngine.probe(it) }
        val probe = JSONObject(json)
        if (probe.has("error")) throw IllegalStateException(probe.getString("error"))
        val verdict = Playability.check(probe)
        return mapOf("probe" to json, "native" to verdict.native, "reason" to verdict.reason)
    }

    /** Returns a cached JPEG thumbnail path, generating it if needed. */
    fun thumbnail(uri: Uri, key: String, durationSec: Double, rotation: Int, preferSystem: Boolean): String? {
        val dir = File(context.filesDir, "thumbs").apply { mkdirs() }
        val file = File(dir, "$key.jpg")
        if (file.exists() && file.length() > 0) return file.absolutePath

        var bitmap: Bitmap? = null
        if (preferSystem) {
            bitmap = try {
                resolver.loadThumbnail(uri, Size(THUMB_SIDE, THUMB_SIDE), null)
            } catch (e: Exception) {
                null
            }
        }
        if (bitmap == null) bitmap = engineFrame(uri, durationSec, rotation, THUMB_SIDE)
        bitmap ?: return null
        val tmp = File(dir, "$key.tmp")
        tmp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 86, it) }
        bitmap.recycle()
        tmp.renameTo(file)
        return file.absolutePath
    }

    private fun engineFrame(uri: Uri, durationSec: Double, rotation: Int, side: Int): Bitmap? {
        val at = when {
            durationSec <= 0 -> 0.0
            durationSec < 4 -> 0.0
            else -> minOf(durationSec * 0.1, 8.0)
        }
        val buf = thumbBuffer.get()!!
        buf.clear()
        val packed = withEnginePath(uri) { NativeEngine.thumbnail(it, at, side, buf) }
        if (packed == 0) return null
        val w = packed ushr 16
        val h = packed and 0xffff
        buf.limit(w * h * 4)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(buf)
        if (rotation == 0) return bmp
        val rotated = Bitmap.createBitmap(bmp, 0, 0, w, h, Matrix().apply { postRotate(rotation.toFloat()) }, true)
        bmp.recycle()
        return rotated
    }

    fun clearThumbnails() {
        File(context.filesDir, "thumbs").deleteRecursively()
    }

    /** Copies a non-seekable (cloud) document into the cache so it can be played and converted. */
    fun copyToCache(uri: Uri, name: String, onProgress: (Long, Long) -> Unit): File {
        val dir = File(context.cacheDir, "opened").apply { mkdirs() }
        val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "_")
        val target = File(dir, safe)
        val total = describeDocument(uri)["size"] as Long
        resolver.openInputStream(uri)!!.use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(1 shl 20)
                var done = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                    done += n
                    onProgress(done, total)
                }
            }
        }
        return target
    }
}
