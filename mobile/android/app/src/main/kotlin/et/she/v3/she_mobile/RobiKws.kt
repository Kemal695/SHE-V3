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
 * (`▁HE Y ▁RO B I`), so an invented name works exactly like a real one. Model is
 * ~5 MB of int8 weights, bundled in assets — no 39 MB download.
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
     * Copy the model out of assets. sherpa-onnx takes filesystem paths, not
     * AssetManager handles. Idempotent — returns null when already installed.
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
        val config = KeywordSpotterConfig.builder()
            .setFeatureConfig(
                FeatureConfig.builder()
                    .setSampleRate(16000)
                    .setFeatureDim(80)
                    .build(),
            )
            .setOnlineModelConfig(
                OnlineModelConfig.builder()
                    .setTransducer(
                        OnlineTransducerModelConfig.builder()
                            .setEncoder("$d/encoder.int8.onnx")
                            .setDecoder("$d/decoder.int8.onnx")
                            .setJoiner("$d/joiner.int8.onnx")
                            .build(),
                    )
                    .setTokens("$d/tokens.txt")
                    .setNumThreads(1)
                    // The KWS model is a zipformer2 transducer.
                    .setModelType("zipformer2")
                    .setDebug(false)
                    .build(),
            )
            .setKeywordsFile("$d/keywords.txt")
            // Defaults from the upstream KWS examples; raising the score makes
            // detection stricter, lowering the threshold makes it more eager.
            .setKeywordsScore(1.5f)
            .setKeywordsThreshold(0.25f)
            .build()
        return KeywordSpotter(config)
    }
}
