package dev.tachyon.tachyon_client

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Указатели меняются атомарно; уже запущенные процессы сохраняют прежний файл. */
object CoreStore {
    private fun root(context: Context) = File(context.noBackupFilesDir, "cores").apply { mkdirs() }
    private fun read(context: Context): JSONObject = try {
        JSONObject(AtomicFile(File(root(context), "selection.json")).openRead().bufferedReader().use { it.readText() })
    } catch (_: Exception) { JSONObject() }

    private fun write(context: Context, state: JSONObject) {
        val atomic = AtomicFile(File(root(context), "selection.json"))
        val stream = atomic.startWrite()
        try { stream.write(state.toString().toByteArray()); atomic.finishWrite(stream) }
        catch (failure: Exception) { atomic.failWrite(stream); throw failure }
    }

    fun bundledEntry(context: Context) = JSONObject().put("id", "bundled").put("version", CoreExecutable.bundled(context).version)

    private fun entryExecutable(context: Context, entry: JSONObject): CoreExecutable {
        val id = entry.getString("id")
        if (id == "bundled") return CoreExecutable.bundled(context)
        require(Regex("[0-9a-f]{64}").matches(id))
        val file = File(root(context), "versions/$id/core")
        require(file.isFile && CoreExecutable.sha256(file) == id) { "Контрольная сумма установленного ядра не совпадает." }
        CoreExecutable.validate(file)
        return CoreExecutable(file, entry.getString("version"), id)
    }

    @Synchronized fun selected(context: Context): CoreExecutable {
        val state = read(context)
        val entry = state.optJSONObject("current") ?: return CoreExecutable.bundled(context)
        return try { entryExecutable(context, entry) } catch (_: Exception) {
            val previous = state.optJSONObject("previous")
            val restored = previous?.let { runCatching { entryExecutable(context, it) }.getOrNull() } ?: CoreExecutable.bundled(context)
            state.put("current", if (restored.id == "bundled") bundledEntry(context) else previous)
                .remove("previous")
            write(context, state)
            RuntimeState.log("Повреждённое ядро исключено; выбрана рабочая версия ${restored.version}")
            restored
        }
    }

    @Synchronized fun snapshot(context: Context): Map<String, Any> {
        val state = read(context)
        val current = state.optJSONObject("current") ?: bundledEntry(context)
        val previous = state.optJSONObject("previous")
        return mapOf("installedVersion" to current.optString("version"), "source" to if (current.optString("id") == "bundled") "bundled" else "github",
            "canRollback" to (previous != null), "previousVersion" to (previous?.optString("version") ?: ""),
            "previousSource" to if (previous?.optString("id") == "bundled") "bundled" else "github",
            "autoUpdate" to state.optBoolean("autoUpdate", false), "selectionId" to current.optString("id"))
    }

    @Synchronized fun setAutoUpdate(context: Context, enabled: Boolean) {
        write(context, read(context).put("autoUpdate", enabled))
    }

    @Synchronized fun rollback(context: Context) {
        val state = read(context)
        val previous = state.optJSONObject("previous") ?: error("Нет предыдущего ядра для отката.")
        entryExecutable(context, previous)
        val current = state.optJSONObject("current") ?: bundledEntry(context)
        write(context, state.put("current", previous).put("previous", current))
        RuntimeState.log("Для следующего подключения выбрано ядро ${previous.optString("version")}")
    }

    @Synchronized fun reject(context: Context, failedId: String) {
        if ((read(context).optJSONObject("current")?.optString("id")) != failedId) return
        if (read(context).optJSONObject("previous") != null) rollback(context)
        else write(context, read(context).put("current", bundledEntry(context)))
    }

    fun staging(context: Context, suffix: String): File = File(root(context), "staging").apply { mkdirs() }
        .let { File(it, "${UUID.randomUUID()}.$suffix") }

    fun commit(context: Context, candidate: File, version: String, digest: String, expectedSelectionId: String? = null, beforeCommit: () -> Unit = {}) {
        require(Regex("[0-9a-f]{64}").matches(digest) && CoreExecutable.sha256(candidate) == digest) { "Контрольная сумма ядра не совпадает." }
        CoreExecutable.validate(candidate)
        val executable = CoreExecutable(candidate, version, digest)
        val inspection = CoreProcess.inspect(context, executable)
        require(inspection["compatible"] == true) { "Android не смог запустить загруженное ядро." }
        require((inspection["reportedVersion"] as? String)?.lineSequence()?.firstOrNull()?.trim() == "tachyon-core ${version.removePrefix("v")}") { "Версия бинарника не совпадает с релизом." }
        CoreProcess.startExact(context, "{\"type\":\"direct\"}", {}, executable).use { }
        beforeCommit()
        synchronized(this) {
            val state = read(context)
            val current = state.optJSONObject("current") ?: bundledEntry(context)
            require(expectedSelectionId == null || current.optString("id") == expectedSelectionId) { "Выбор ядра изменился во время загрузки. Повторите обновление." }
            val destination = File(root(context), "versions/$digest/core")
            destination.parentFile!!.mkdirs()
            if (destination.exists()) require(CoreExecutable.sha256(destination) == digest)
            else require(candidate.renameTo(destination)) { "Не удалось сохранить проверенное ядро." }
            if (current.optString("id") != digest) {
                write(context, state.put("previous", current).put("current", JSONObject()
                    .put("id", digest).put("version", version).put("installedAt", System.currentTimeMillis())))
            }
        }
    }
}
