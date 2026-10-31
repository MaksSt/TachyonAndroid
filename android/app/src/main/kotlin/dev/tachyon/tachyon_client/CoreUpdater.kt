package dev.tachyon.tachyon_client

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.GZIPInputStream
import javax.net.ssl.HttpsURLConnection

class CoreUpdateToken {
    @Volatile var cancelled = false
    @Volatile var connection: HttpsURLConnection? = null
    fun check() { if (cancelled || Thread.currentThread().isInterrupted) throw InterruptedIOException("Update postponed") }
    fun cancel() { cancelled = true; connection?.disconnect() }
}

object CoreUpdater {
    private const val REPOSITORY = "Dushnilin/tachyon-core"
    private val running = AtomicBoolean(false)
    private val activePhases = setOf("queued", "checking", "downloading", "verifying")
    private fun stateFile(context: Context) = AtomicFile(File(context.noBackupFilesDir, "core-update.json"))

    @Synchronized private fun state(context: Context): JSONObject = try {
        JSONObject(stateFile(context).openRead().bufferedReader().use { it.readText() })
    } catch (_: Exception) { JSONObject().put("phase", "idle").put("message", "") }

    @Synchronized fun status(context: Context, phase: String, message: String, progress: Int = -1, version: String = "") {
        val value = JSONObject().put("phase", phase).put("message", message).put("progress", progress)
            .put("version", version).put("updatedAt", System.currentTimeMillis())
        val atomic = stateFile(context)
        val output = atomic.startWrite()
        try { output.write(value.toString().toByteArray()); atomic.finishWrite(output) }
        catch (failure: Exception) { atomic.failWrite(output); throw failure }
    }

    fun snapshot(context: Context): Map<String, Any> {
        val value = state(context)
        val phase = value.optString("phase", "idle")
        val pending = CoreUpdateJobService.pending(context)
        // После убийства процесса незавершённое задание остаётся у JobScheduler.
        val effective = if (phase in activePhases && !running.get() && !pending) "idle" else phase
        return mapOf("phase" to effective, "message" to if (effective == "idle") "" else value.optString("message"),
            "progress" to value.optInt("progress", -1), "version" to value.optString("version"),
            "busy" to (effective in activePhases), "lastCheckedAt" to value.optLong("updatedAt"))
    }

    private fun request(context: Context, address: String, token: CoreUpdateToken, asset: Boolean = false): HttpsURLConnection {
        var url = URL(address)
        repeat(6) {
            token.check()
            require(url.protocol == "https" && url.userInfo == null && url.port in listOf(-1, 443))
            require(if (asset) url.host in setOf("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com") else url.host == "api.github.com")
            val connection = (url.openConnection() as HttpsURLConnection).apply {
                connectTimeout = 15000; readTimeout = 20000; instanceFollowRedirects = false
                setRequestProperty("User-Agent", "TachyonClient/${context.packageManager.getPackageInfo(context.packageName, 0).versionName}")
                setRequestProperty("Accept-Encoding", "identity")
                if (!asset) setRequestProperty("Accept", "application/vnd.github+json")
            }
            token.connection = connection
            val code = connection.responseCode
            if (code in setOf(301, 302, 303, 307, 308) && asset) {
                val destination = connection.getHeaderField("Location") ?: error("GitHub не вернул адрес загрузки.")
                url = URL(url, destination)
                connection.disconnect()
            } else {
                if (code != 200) {
                    connection.disconnect()
                    error(if (code == 403 || code == 429) "GitHub ограничил запросы. Повторите позже." else "GitHub вернул HTTP $code.")
                }
                return connection
            }
        }
        error("Слишком много перенаправлений GitHub.")
    }

    private fun latest(context: Context, token: CoreUpdateToken): JSONObject {
        val connection = request(context, "https://api.github.com/repos/$REPOSITORY/releases/latest", token)
        return try {
            connection.inputStream.use { input ->
                val bytes = input.readBytesLimited(2 * 1024 * 1024, token)
                JSONObject(bytes.toString(Charsets.UTF_8))
            }
        } finally { connection.disconnect() }
    }

    private fun InputStream.readBytesLimited(limit: Int, token: CoreUpdateToken): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16384)
        while (true) {
            token.check()
            val count = read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit) { "Ответ GitHub превышает допустимый размер." }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    internal fun asset(release: JSONObject, name: String): JSONObject {
        val assets = release.getJSONArray("assets")
        val matches = (0 until assets.length()).map { assets.getJSONObject(it) }.filter { it.optString("name") == name }
        require(matches.size == 1) { "В релизе нет нужной официальной Android-сборки." }
        val value = matches.single()
        require(Regex("sha256:[0-9a-f]{64}").matches(value.optString("digest"))) { "GitHub не опубликовал SHA-256 артефакта." }
        return value
    }

    private fun download(context: Context, release: JSONObject, name: String, target: File, limit: Long, token: CoreUpdateToken, progress: Boolean) {
        val value = asset(release, name)
        val expectedSize = value.getLong("size")
        require(expectedSize in 1..limit) { "Неверный размер артефакта GitHub." }
        val address = value.getString("browser_download_url")
        require(address == "https://github.com/$REPOSITORY/releases/download/${release.getString("tag_name")}/$name") { "GitHub вернул посторонний адрес загрузки." }
        val connection = request(context, address, token, asset = true)
        try {
            connection.inputStream.use { input ->
                FileOutputStream(target).use { output ->
                    var copied = 0L; var lastProgress = -1
                    val buffer = ByteArray(65536)
                    while (true) {
                        token.check()
                        val count = input.read(buffer)
                        if (count < 0) break
                        copied += count
                        require(copied <= expectedSize) { "Размер загрузки не совпадает с GitHub." }
                        output.write(buffer, 0, count)
                        val percent = (100 * copied / expectedSize).toInt()
                        if (progress && percent / 5 != lastProgress / 5) {
                            status(context, "downloading", "Загрузка Android-ядра", percent, release.getString("tag_name"))
                            lastProgress = percent
                        }
                    }
                    output.fd.sync()
                    require(copied == expectedSize) { "Загрузка ядра не завершена." }
                }
            }
            require(CoreExecutable.sha256(target) == value.getString("digest").removePrefix("sha256:")) { "SHA-256 архива не совпадает с GitHub." }
        } finally { connection.disconnect() }
    }

    internal fun extract(archive: File, destination: File, binaryName: String, token: CoreUpdateToken) {
        GZIPInputStream(archive.inputStream()).use { input ->
            var found = false; var total = 0L
            fun readBlock(): ByteArray? {
                val block = ByteArray(512)
                var filled = 0
                while (filled < 512) {
                    token.check()
                    val count = input.read(block, filled, 512 - filled)
                    if (count < 0) { require(filled == 0) { "Повреждён TAR-заголовок." }; return null }
                    filled += count
                }
                return block
            }
            while (true) {
                val header = readBlock() ?: break
                if (header.all { it == 0.toByte() }) break
                fun field(offset: Int, length: Int) = header.copyOfRange(offset, offset + length).toString(Charsets.US_ASCII).trim('\u0000', ' ')
                val recordedChecksum = field(148, 8).toLongOrNull(8) ?: error("Повреждён TAR checksum.")
                val actualChecksum = header.indices.sumOf { if (it in 148..155) 32L else (header[it].toInt() and 255).toLong() }
                require(recordedChecksum == actualChecksum) { "Повреждён TAR-заголовок." }
                val size = field(124, 12).toLongOrNull(8) ?: error("Неверный размер TAR-записи.")
                total += size + 512
                require(size >= 0 && total <= 160L * 1024 * 1024) { "Распакованный архив слишком большой." }
                val matches = field(0, 100).substringAfterLast('/') == binaryName
                if (matches) {
                    require(!found && header[156] in byteArrayOf(0, '0'.code.toByte()) && size in 64..(128L * 1024 * 1024)) { "Неверная запись ядра в TAR." }
                    found = true
                    FileOutputStream(destination).use { output ->
                        check(destination.setReadOnly()) { "Не удалось защитить бинарник от записи." }
                        val buffer = ByteArray(65536)
                        var remaining = size
                        while (remaining > 0) {
                            token.check()
                            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                            require(count > 0) { "Бинарник в архиве повреждён." }
                            output.write(buffer, 0, count); remaining -= count
                        }
                        output.fd.sync()
                    }
                } else input.skipFully(size, token)
                input.skipFully((512 - size % 512) % 512, token)
            }
            require(found) { "В архиве отсутствует Android-ядро." }
        }
    }

    private fun InputStream.skipFully(size: Long, token: CoreUpdateToken) {
        var remaining = size
        val buffer = ByteArray(16384)
        while (remaining > 0) {
            token.check()
            val count = read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
            require(count > 0) { "Архив не завершён." }
            remaining -= count
        }
    }

    /** null означает, что параллельное задание уже выполняет эту работу. */
    fun update(context: Context, token: CoreUpdateToken): Boolean? {
        if (!running.compareAndSet(false, true)) return null
        val archive = CoreStore.staging(context, "tar.gz")
        val checksums = CoreStore.staging(context, "sha256")
        val candidate = CoreStore.staging(context, "core")
        try {
            status(context, "checking", "Проверка последнего релиза GitHub")
            val startedSelection = CoreStore.selected(context).id
            val release = latest(context, token)
            require(!release.optBoolean("draft") && !release.optBoolean("prerelease"))
            val version = release.getString("tag_name")
            require(Regex("v[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9.-]+)?").matches(version)) { "Неожиданное имя релиза." }
            val binaryName = "tachyon-core-${CoreExecutable.architecture()}-linux-android-$version"
            val name = "$binaryName.tar.gz"
            // Проверяем наличие ABI до начала загрузки, Linux fallback отсутствует.
            asset(release, name)
            download(context, release, "SHA256SUMS", checksums, 1024 * 1024, token, progress = false)
            val expectedHash = checksums.readLines().mapNotNull { line ->
                val parts = line.trim().split(Regex("\\s+"), limit = 2)
                if (parts.size == 2 && parts[1].removePrefix("*").removePrefix("./") == binaryName) parts[0] else null
            }.singleOrNull() ?: error("Нет однозначной контрольной суммы Android-бинарника.")
            require(Regex("[0-9a-f]{64}").matches(expectedHash))
            if (CoreStore.selected(context).id == expectedHash) {
                status(context, "current", "Установлено последнее ядро", 100, version)
                return true
            }
            status(context, "downloading", "Загрузка Android-ядра", 0, version)
            download(context, release, name, archive, 32L * 1024 * 1024, token, progress = true)
            status(context, "verifying", "Проверка SHA-256 и запуска ядра", -1, version)
            extract(archive, candidate, binaryName, token)
            CoreStore.commit(context, candidate, version, expectedHash, expectedSelectionId = startedSelection, beforeCommit = token::check)
            status(context, "ready", "Ядро готово. Будет использовано при следующем подключении.", 100, version)
            RuntimeState.log("Ядро $version загружено с GitHub и проверено; текущий VPN-сеанс сохранён")
            return true
        } catch (failure: Exception) {
            if (token.cancelled || Thread.currentThread().isInterrupted) {
                status(context, "queued", "Обновление отложено до восстановления условий")
            } else {
                val message = if (failure is IllegalArgumentException || failure is IllegalStateException) failure.message ?: "Проверка обновления не пройдена." else "Не удалось загрузить ядро. Проверьте сеть и повторите."
                status(context, "error", message.take(250))
                RuntimeState.log("Обновление ядра не установлено; рабочая версия сохранена")
            }
            return false
        } finally {
            token.connection?.disconnect()
            listOf(archive, checksums, candidate).forEach { it.delete() }
            running.set(false)
        }
    }
}
