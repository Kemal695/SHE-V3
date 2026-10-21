package et.she.v3.she_mobile

import android.content.Context
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.KeywordSpotterConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import java.io.File

/**
 * Robi wake word — sherpa-onnx keyword spotting (Phase 4, final approach).
 *
 * WHY NOT VOSK: Vosk is a dictation engine. It turns audio into words from a
 * fixed vocabulary and we then searched that text for "hey robi". "Robi" is not
 * a word, so it was substituted with whatever English sounded closest — measured
 * on the LE6 it produced "huh", "yeah catfish", "and i'm irish know him", never
 * the phrase. No amount of matching tolerance fixes a transcript that does not
 * contain the words.
 *
 * sherpa-onnx KWS never transcribes. It matches the audio against a small
 * acoustic model of the keyword, which is specified as BPE tokens
 * (`▁HE Y ▁RO B I`), so an invented name works exactly like a real one. The model
 * is ~5 MB of int8 weights, bundled in assets — no 39 MB download.
 *
 * API NOTE: the AAR ships the **Kotlin** API, which uses constructors with
 * named/default arguments — NOT the `builder()` style that appears in the
 * project's `master` branch on GitHub. Coding against master produced
 * "Unresolved reference 'builder'". If the AAR is upgraded, verify the
 * signatures again before editing:
 *
 *   javap -classpath classes.jar com.k2fsa.sherpa.onnx.KeywordSpotterConfig
 *
 * Apache-2.0, on-device, no account or API key.
 */
object RobiKws {

    private const val TAG = "RobiKws"

    /** Where the bundled model lives in assets. */
    private const val ASSET_DIR = "sherpa-kws"

    /** Files sherpa-onnx needs as real paths, copied out of assets once. */
    private val REQUIRED = listOf(
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt",
        "keywords.txt",
    )

    fun dir(context: Context): File = File(context.filesDir, ASSET_DIR)

    fun isInstalled(context: Context): Boolean =
        File(dir(context), "encoder.int8.onnx").isFile

    /**
     * Copy the model out of assets into app storage.
     *
     * Idempotent — returns null when already installed, or a message describing
     * the failure. Kept even though KeywordSpotter also takes an AssetManager:
     * absolute file paths remove one whole class of "model not found" failure.
     */
    fun ensureInstalled(context: Context): String? {
        if (isInstalled(context)) return null
        val target = dir(context)
        return try {
            target.mkdirs()
            for (name in REQUIRED) {
                context.assets.open("$ASSET_DIR/$name").use { input ->
                    File(target, name).outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            }
            null
        } catch (t: Throwable) {
            // Throwable: copying 5 MB can throw OutOfMemoryError on a full disk.
            Log.e(TAG, "could not install model", t)
            "${t::class.java.simpleName}: ${t.message}"
        }
    }

    fun create(context: Context): KeywordSpotter {
        val d = dir(context).absolutePath

        val config = KeywordSpotterConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = "$d/encoder.int8.onnx",
                    decoder = "$d/decoder.int8.onnx",
                    joiner = "$d/joiner.int8.onnx",
                ),
                tokens = "$d/tokens.txt",
                numThreads = 1,
                debug = false,
                // The KWS model is a zipformer2 transducer.
                modelType = "zipformer2",
            ),
            keywordsFile = "$d/keywords.txt",
            // Defaults from the upstream KWS examples: raising the score makes
            // detection stricter, lowering the threshold makes it more eager.
            keywordsScore = 1.5f,
            keywordsThreshold = 0.25f,
        )

        // The AssetManager argument is required by this constructor even when the
        // paths are absolute files — sherpa-onnx uses it for relative ones.
        return KeywordSpotter(context.assets, config)
    }
}
