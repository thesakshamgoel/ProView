package app.proview.proview

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

/**
 * Looks at one preview frame and says what is in it: things (labels), faces and written text. Everything runs
 * on the phone with bundled models. Call from a single background thread; each call blocks until done.
 */
class Tagger {
    // Created on first use and let go again when idle (see close): the three models together take a lot of memory.
    private var labelerClient: com.google.mlkit.vision.label.ImageLabeler? = null
    private var faceClient: com.google.mlkit.vision.face.FaceDetector? = null
    private var textClient: com.google.mlkit.vision.text.TextRecognizer? = null

    private val labeler
        get() = labelerClient ?: ImageLabeling.getClient(
            ImageLabelerOptions.Builder().setConfidenceThreshold(0.6f).build()
        ).also { labelerClient = it }
    private val faces
        get() = faceClient ?: FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setMinFaceSize(0.08f)
                .build()
        ).also { faceClient = it }
    private val text
        get() = textClient ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).also { textClient = it }

    /** Frees the models. They are rebuilt on the next [tag]. */
    @Synchronized
    fun close() {
        runCatching { labelerClient?.close() }
        runCatching { faceClient?.close() }
        runCatching { textClient?.close() }
        labelerClient = null
        faceClient = null
        textClient = null
    }

    @Synchronized
    fun tag(path: String): Map<String, Any> {
        val bmp = load(path) ?: return mapOf("labels" to emptyList<String>(), "faces" to emptyList<Double>(), "text" to "")
        try {
            val image = InputImage.fromBitmap(bmp, 0)
            val labels = runCatching {
                Tasks.await(labeler.process(image)).sortedByDescending { it.confidence }.take(10).map { it.text.lowercase() }
            }.getOrDefault(emptyList())
            // Share of the picture's width each face takes, so "selfie" and "group" can be told apart later.
            val faceSizes = runCatching {
                Tasks.await(faces.process(image)).map { it.boundingBox.width().toDouble() / bmp.width }
            }.getOrDefault(emptyList())
            val words = runCatching {
                Tasks.await(text.process(image)).text.replace(Regex("\\s+"), " ").trim()
            }.getOrDefault("")
            return mapOf("labels" to labels, "faces" to faceSizes, "text" to words.take(200))
        } finally {
            bmp.recycle()
        }
    }

    private fun load(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 640) sample *= 2
        return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
