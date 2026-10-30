package app.proview.proview

import java.nio.ByteBuffer

/** JNI bridge to libproview (FFmpeg + Android hardware HEVC encoder). */
object NativeEngine {
    init {
        System.loadLibrary("proview")
    }

    interface ConvertListener {
        fun onProgress(doneSec: Double, totalSec: Double, fps: Double)
        fun onEncoder(name: String, bitDepth: Int)
    }

    /** JSON description of the file, or {"error": ...}. [path] may be "fd:<n>". */
    @JvmStatic external fun probe(path: String): String

    /** Decodes one frame into [out] as RGBA; returns (width shl 16) or height, or 0 on failure. */
    @JvmStatic external fun thumbnail(path: String, atSec: Double, maxSide: Int, out: ByteBuffer): Int

    /** Frames per second this phone's CPU can decode the clip's video at. */
    @JvmStatic external fun decodeSpeed(path: String): Double

    /** Converts to 10-bit HEVC MP4; null on success, otherwise an error message ("cancelled" if cancelled). */
    @JvmStatic external fun convert(
        inPath: String, outPath: String, videoBitrate: Int, audioBitrate: Int, listener: ConvertListener,
    ): String?

    @JvmStatic external fun cancelConvert()
}
