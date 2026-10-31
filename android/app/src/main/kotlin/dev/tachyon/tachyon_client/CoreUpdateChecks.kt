package dev.tachyon.tachyon_client

import android.content.Context
import org.json.JSONObject
import java.io.FileOutputStream
import java.util.zip.GZIPOutputStream

/** Изолированные регрессии: вызываются каналом только в пакете .checks. */
object CoreUpdateChecks {
    fun run(context: Context): Map<String, Boolean> {
        check(context.packageName.endsWith(".checks"))
        val bundled = CoreExecutable.bundled(context)
        val digest = CoreExecutable.sha256(bundled.file)
        val archive = CoreStore.staging(context, "test.tar.gz")
        val candidate = CoreStore.staging(context, "test.core")
        val bad = CoreStore.staging(context, "bad.core")
        val binaryName = "tachyon-core-${CoreExecutable.architecture()}-linux-android-${bundled.version}"
        val header = ByteArray(512)
        fun put(offset: Int, text: String) { text.toByteArray(Charsets.US_ASCII).copyInto(header, offset) }
        put(0, "./$binaryName")
        put(100, "0000444\u0000"); put(108, "0000000\u0000"); put(116, "0000000\u0000")
        put(124, bundled.file.length().toString(8).padStart(11, '0') + "\u0000")
        put(136, "00000000000\u0000"); put(148, "        "); header[156] = '0'.code.toByte()
        put(257, "ustar\u0000"); put(263, "00")
        val sum = header.sumOf { it.toInt() and 255 }
        put(148, sum.toString(8).padStart(6, '0') + "\u0000 ")
        try {
            GZIPOutputStream(FileOutputStream(archive)).use { output ->
                output.write(header)
                bundled.file.inputStream().use { it.copyTo(output) }
                output.write(ByteArray(((512 - bundled.file.length() % 512) % 512).toInt() + 1024))
            }
            val before = CoreStore.selected(context).id
            val unsupported = runCatching { CoreUpdater.asset(JSONObject("{\"assets\":[]}"), "$binaryName.tar.gz") }.isFailure
            val cancelled = CoreUpdateToken().apply { cancel() }
            val cancellation = runCatching { CoreUpdater.extract(archive, bad, binaryName, cancelled) }.isFailure
            CoreUpdater.extract(archive, candidate, binaryName, CoreUpdateToken())
            val bytesUnchanged = CoreExecutable.sha256(candidate) == digest
            val badDigest = runCatching { CoreStore.commit(context, candidate, bundled.version, "0".repeat(64)) }.isFailure
            val preservedOnError = CoreStore.selected(context).id == before
            CoreProcess.start(context, "{\"type\":\"direct\"}").use { active ->
                CoreStore.commit(context, candidate, bundled.version, digest)
                val selected = CoreStore.selected(context)
                val activePreserved = active.process.isAlive && active.executable.id == before
                val selectedManaged = selected.id == digest && CoreProcess.inspect(context)["compatible"] == true
                CoreProcess.start(context, "{\"type\":\"direct\"}").use { managed ->
                    check(managed.executable.id == digest)
                }
                CoreStore.rollback(context)
                val rolledBack = CoreStore.selected(context).id == before && active.process.isAlive
                return mapOf("archiveUnchanged" to bytesUnchanged, "missingAndroidRejected" to unsupported,
                    "cancelled" to cancellation, "badDigestRejected" to badDigest, "preservedOnError" to preservedOnError,
                    "activePreserved" to activePreserved, "selectedManaged" to selectedManaged, "rollback" to rolledBack)
            }
        } finally {
            listOf(archive, candidate, bad).forEach { it.delete() }
        }
    }
}
