package et.she.v3.she_mobile

import android.content.Context
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

    /** Where the bundled model lives in assets. */
    private const val ASSET_DIR = "sherpa-kws"

    fun dir(context: Context): File = File(context.filesDir, ASSET_DIR)

    /** True when the bundled model can be opened from assets. */
    fun isInstalled(context: Context): Boolean = try {
        context.assets.open("$ASSET_DIR/encoder.int8.onnx").close()
        true
    } catch (t: Throwable) {
        false
    }

    /**
     * The model ships INSIDE the APK, so there is nothing to download or copy.
     * This only verifies the assets are readable and returns a message if not.
     *
     * NOTE: do NOT copy the model to filesDir and pass absolute paths. The
     * KeywordSpotter constructor takes an AssetManager, and sherpa-onnx refuses
     * absolute paths while one is set:
     *
     *   "You are using an absolute path '...' but assetManager is NOT set to null"
     *   "F sherpa-onnx: Read binary file: Load '...' failed"   <- fatal, aborts
     *
     * Asset-relative paths are the supported combination, and they avoid keeping
     * a second 5 MB copy of the model on the device.
     */
    fun ensureInstalled(context: Context): String? =
        if (isInstalled(context)) null else "bundled model missing from assets"

    fun create(context: Context): KeywordSpotter {
        val config = KeywordSpotterConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    // Asset-relative, NOT absolute — see ensureInstalled().
                    encoder = "$ASSET_DIR/encoder.int8.onnx",
                    decoder = "$ASSET_DIR/decoder.int8.onnx",
                    joiner = "$ASSET_DIR/joiner.int8.onnx",
                ),
                tokens = "$ASSET_DIR/tokens.txt",
                numThreads = 1,
                debug = false,
                // The KWS model is a zipformer2 transducer.
                modelType = "zipformer2",
            ),
            keywordsFile = "$ASSET_DIR/keywords.txt",
            // Defaults from the upstream KWS examples: raising the score makes
            // detection stricter, lowering the threshold makes it more eager.
            keywordsScore = 1.5f,
            keywordsThreshold = 0.25f,
        )

        return KeywordSpotter(context.assets, config)
    }
}
