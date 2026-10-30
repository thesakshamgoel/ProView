package app.proview.proview

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import org.json.JSONObject

/** Decides whether Android's own (hardware) player can play a clip smoothly, and explains why not. */
object Playability {
    data class Verdict(val native: Boolean, val reason: String)

    private val codecs by lazy { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos }

    private val nativeAudio = setOf(
        "aac", "mp3", "mp3float", "opus", "vorbis", "flac", "pcm_s16le", "pcm_u8", "amr_nb", "amr_wb",
    )

    private val friendlyAudio = mapOf(
        "pcm_s24le" to "24-bit PCM", "pcm_s24be" to "24-bit PCM", "pcm_s32le" to "32-bit PCM",
        "pcm_s32be" to "32-bit PCM", "pcm_f32le" to "32-bit float PCM", "pcm_f32be" to "32-bit float PCM",
        "pcm_s16be" to "16-bit big-endian PCM", "alac" to "Apple Lossless", "ac3" to "Dolby Digital",
        "eac3" to "Dolby Digital Plus",
    )

    fun check(probe: JSONObject): Verdict {
        val v = probe.optJSONObject("video") ?: return Verdict(false, "This file has no video track")
        val codec = v.optString("codec")
        val width = v.optInt("width")
        val height = v.optInt("height")
        val fps = v.optDouble("fps", 30.0).takeIf { it > 0 } ?: 30.0
        val depth = v.optInt("bitDepth", 8)
        val chroma = v.optString("chroma")

        val mime = when (codec) {
            "hevc" -> "video/hevc"
            "h264" -> "video/avc"
            "vp9" -> "video/x-vnd.on2.vp9"
            "av1" -> "video/av01"
            "mpeg4" -> "video/mp4v-es"
            "prores" -> return Verdict(false, "Android has no ProRes decoder, so this clip is decoded in software")
            "dnxhd" -> return Verdict(false, "Android has no DNxHD/DNxHR decoder")
            "cfhd" -> return Verdict(false, "Android has no CineForm decoder")
            else -> return Verdict(false, "Android's player doesn't support ${codec.uppercase()} video")
        }
        val codecName = when (codec) {
            "hevc" -> "HEVC"; "h264" -> "H.264"; "vp9" -> "VP9"; "av1" -> "AV1"; else -> "MPEG-4"
        }
        if (chroma.isNotEmpty() && chroma != "4:2:0") {
            return Verdict(false, "This phone's video hardware can't decode $codecName $chroma ${depth}-bit")
        }
        if (depth > 10 || (depth > 8 && codec in setOf("h264", "mpeg4"))) {
            return Verdict(false, "This phone's video hardware can't decode ${depth}-bit $codecName")
        }

        val profile = when {
            codec == "hevc" && depth == 10 -> CodecProfileLevel.HEVCProfileMain10
            codec == "vp9" && depth == 10 -> CodecProfileLevel.VP9Profile2
            codec == "av1" && depth == 10 -> CodecProfileLevel.AV1ProfileMain10
            else -> null
        }
        val decoder = codecs.firstOrNull { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, true) } && supports(info, mime, width, height, fps, profile)
        } ?: return Verdict(
            false,
            "${resolution(width, height)} $codecName at ${fps.toInt()} fps is beyond this phone's video hardware",
        )

        probe.optJSONObject("audio")?.let { a ->
            val ac = a.optString("codec")
            if (ac !in nativeAudio) {
                val label = friendlyAudio[ac] ?: ac.uppercase()
                return Verdict(false, "Android's player can't play this clip's $label audio")
            }
        }
        return Verdict(true, "Plays with ${if (decoder.isHardwareAccelerated) "hardware" else "software"} decoding")
    }

    private fun supports(info: MediaCodecInfo, mime: String, w: Int, h: Int, fps: Double, profile: Int?): Boolean {
        val caps = try {
            info.getCapabilitiesForType(mime)
        } catch (e: IllegalArgumentException) {
            return false
        }
        val video = caps.videoCapabilities ?: return false
        val sizeOk = w <= 0 || h <= 0 ||
            video.areSizeAndRateSupported(w, h, fps) || video.areSizeAndRateSupported(h, w, fps)
        if (!sizeOk) return false
        if (profile != null && caps.profileLevels.none { it.profile == profile }) return false
        return true
    }

    private fun resolution(w: Int, h: Int): String {
        val long = maxOf(w, h)
        return when {
            long >= 7600 -> "8K"
            long >= 3800 -> "4K"
            long >= 2500 -> "${long}p"
            long >= 1900 -> "1080p"
            else -> "${minOf(w, h)}p"
        }
    }

    /** True if this phone's HEVC encoder accepts 10-bit input (for the conversion sheet). */
    fun encoderSupportsTenBit(): Boolean = codecs.any { info ->
        info.isEncoder && info.supportedTypes.any { it.equals("video/hevc", true) } && try {
            val caps = info.getCapabilitiesForType("video/hevc")
            caps.profileLevels.any { it.profile == CodecProfileLevel.HEVCProfileMain10 } &&
                caps.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010)
        } catch (e: Exception) {
            false
        }
    }

    /** Highest bitrate the HEVC hardware encoder accepts, used to clamp the quality presets. */
    fun encoderMaxBitrate(): Int = codecs.filter { info ->
        info.isEncoder && info.isHardwareAccelerated && info.supportedTypes.any { it.equals("video/hevc", true) }
    }.maxOfOrNull { it.getCapabilitiesForType("video/hevc").videoCapabilities.bitrateRange.upper } ?: 100_000_000
}
