package et.she.v3.she_mobile

import android.content.Context
import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Downloads and unpacks the on-device speech model used by the Robi wake word.
 *
 * WHY A DOWNLOAD AND NOT A BUNDLED ASSET: the small English Vosk model is ~39 MB
 * compressed / ~40 MB unpacked. Bundling it would add that to every APK and to
 * git history, for a feature most users will never enable. It is fetched once,
 * on the first enable, and reused after that.
 *
 * The model is public, Apache-2.0, and needs no key. If the product ever ships
 * to users, host the zip on our own infrastructure instead of alphacephei.com
 * so a third party cannot break or track the install.
 */
object RobiModel {

    private const val TAG = "RobiModel"
    private const val URL_ZIP =
        "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"

    /** Exact size of that zip, so a truncated download is detected rather than unzipped. */
    private const val EXPECTED_BYTES = 41_205_931L

    private const val TOP_DIR = "vosk-model-small-en-us-0.15"

    fun dir(context: Context): File = File(context.filesDir, "vosk/model")

    fun isInstalled(context: Context): Boolean {
        val d = dir(context)
        return d.isDirectory && (d.list()?.isNotEmpty() == true)
    }

    /**
     * Download + unpack. Blocking — call from a worker thread.
     *
     * [onProgress] receives 0..100. Returns null on success, or a message
     * describing the failure.
     */
    fun install(context: Context, onProgress: (Int) -> Unit): String? {
        val target = dir(context)
        val zip = File(context.cacheDir, "robi-model.zip")

        try {
            if (!zip.isFile || zip.length() != EXPECTED_BYTES) {
                zip.delete()
                download(zip, onProgress)
            }
            if (zip.length() != EXPECTED_BYTES) {
                return "Download incomplete (${zip.length()} of $EXPECTED_BYTES bytes)"
            }

            onProgress(95)
            if (target.exists()) target.deleteRecursively()
            target.mkdirs()
            unzip(zip, target)

            // A model directory with no files means the unzip silently failed.
            if (target.list()?.isNotEmpty() != true) return "Model unpacked empty"

            zip.delete()
            onProgress(100)
            return null
        } catch (e: Exception) {
            Log.e(TAG, "install failed", e)
            return e.message ?: e.toString()
        }
    }

    private fun download(dest: File, onProgress: (Int) -> Unit) {
        val conn = (URL(URL_ZIP).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 30_000
            instanceFollowRedirects = true
        }
        try {
            if (conn.responseCode != HttpURLConnection.HTTP_OK) {
                throw IllegalStateException("HTTP ${conn.responseCode}")
            }
            val total = if (conn.contentLengthLong > 0) conn.contentLengthLong else EXPECTED_BYTES
            BufferedInputStream(conn.inputStream).use { input ->
                FileOutputStream(dest).use { output ->
                    val buf = ByteArray(64 * 1024)
                    var written = 0L
                    var lastPct = -1
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                        written += n
                        val pct = ((written * 90) / total).toInt()
                        if (pct != lastPct) {
                            lastPct = pct
                            onProgress(pct)
                        }
                    }
                    output.flush()
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Extract the archive, stripping the model's top-level folder so that
     * `filesDir/vosk/model/` IS the model (Vosk's Model takes that path).
     */
    private fun unzip(zip: File, target: File) {
        ZipInputStream(BufferedInputStream(FileInputStream(zip))).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val name = entry.name.removePrefix("$TOP_DIR/").removePrefix("/")
                if (name.isNotEmpty() && !name.contains("..")) {
                    val out = File(target, name)
                    if (entry.isDirectory) {
                        out.mkdirs()
                    } else {
                        out.parentFile?.mkdirs()
                        FileOutputStream(out).use { zis.copyTo(it) }
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
    }
}
