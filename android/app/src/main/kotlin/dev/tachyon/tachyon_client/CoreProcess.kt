package dev.tachyon.tachyon_client

import android.content.Context
import android.os.ParcelFileDescriptor
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.Closeable
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLEncoder
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

class CoreProcess private constructor(val process: Process, val port: Int, val username: String, val password: String, private val config: File, private val output: ParcelFileDescriptor, val executable: CoreExecutable, private val controllerPort: Int?, private val controllerSecret: String) : Closeable {
    private var outputThread: Thread? = null
    private var closed = false

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        process.destroy()
        if (!process.waitFor(2, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            process.waitFor(2, TimeUnit.SECONDS)
        }
        outputThread?.join(500)
        runCatching { output.close() }
        config.delete()
    }

    fun socket(host: String, destinationPort: Int): Socket {
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress("127.0.0.1", port), 3_000)
            socket.soTimeout = 10_000
            val output = socket.getOutputStream()
            val input = DataInputStream(socket.getInputStream())
            output.write(byteArrayOf(5, 1, 2)); output.flush()
            require(input.readUnsignedByte() == 5 && input.readUnsignedByte() == 2) { "SOCKS authentication required" }
            val user = username.toByteArray(); val pass = password.toByteArray()
            output.write(byteArrayOf(1, user.size.toByte()) + user + byteArrayOf(pass.size.toByte()) + pass); output.flush()
            require(input.readUnsignedByte() == 1 && input.readUnsignedByte() == 0) { "SOCKS authentication failed" }
            val address = host.toByteArray(Charsets.UTF_8)
            require(address.size in 1..255 && destinationPort in 1..65535)
            output.write(byteArrayOf(5, 1, 0, 3, address.size.toByte()) + address + byteArrayOf((destinationPort shr 8).toByte(), destinationPort.toByte())); output.flush()
            require(input.readUnsignedByte() == 5 && input.readUnsignedByte() == 0) { "SOCKS connection failed" }
            input.readUnsignedByte()
            val length = when (input.readUnsignedByte()) { 1 -> 4; 4 -> 16; 3 -> input.readUnsignedByte(); else -> throw IOException("SOCKS address type") }
            input.readFully(ByteArray(length + 2))
            return socket
        } catch (failure: Exception) { socket.close(); throw failure }
    }

    private fun controllerRequest(path: String): Pair<Int, JSONObject> {
        val apiPort = controllerPort ?: error("URLTest controller is disabled")
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", apiPort), 1000)
            socket.soTimeout = 8000
            val request = "GET $path HTTP/1.1\r\nHost: 127.0.0.1:$apiPort\r\nAuthorization: Bearer $controllerSecret\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply { write(request.toByteArray(Charsets.US_ASCII)); flush() }
            val input = DataInputStream(socket.getInputStream())
            fun line(): String {
                val bytes = ArrayList<Byte>()
                while (bytes.size < 4096) {
                    val value = input.readUnsignedByte()
                    if (value == 10) return bytes.toByteArray().toString(Charsets.US_ASCII).trimEnd('\r')
                    bytes.add(value.toByte())
                }
                throw IOException("Oversized URLTest response header")
            }
            val status = line().split(' ').getOrNull(1)?.toIntOrNull() ?: throw IOException("Invalid URLTest response")
            var length = -1
            var headerBytes = 0
            while (true) {
                val header = line()
                headerBytes += header.length + 2
                require(headerBytes <= 16384) { "Oversized URLTest headers" }
                if (header.isEmpty()) break
                if (header.startsWith("Content-Length:", ignoreCase = true)) length = header.substringAfter(':').trim().toInt()
            }
            require(length in 0..65536) { "Invalid URLTest response length" }
            val body = ByteArray(length).also { input.readFully(it) }
            return status to JSONObject(body.toString(Charsets.UTF_8))
        }
    }

    companion object {
        internal fun parseOutbounds(text: String): JSONArray {
            val decoded = JSONTokener(text).nextValue()
            val outbounds = if (decoded is JSONObject) JSONArray().put(decoded) else decoded as? JSONArray
                ?: error("Invalid outbound configuration")
            require(outbounds.length() in 1..32)
            outbounds.getJSONObject(0).put("tag", "proxy")
            val tags = HashSet<String>()
            for (index in 0 until outbounds.length()) {
                val item = outbounds.getJSONObject(index)
                require(item.getString("type").isNotBlank())
                require(tags.add(item.getString("tag")))
            }
            return outbounds
        }

        internal fun checkOutbounds(context: Context, text: String, dns: JSONObject = ProxyDns.load(context)): Map<String, Any> {
            require(context.packageName.endsWith(".checks"))
            val root = JSONObject().put("outbounds", parseOutbounds(text))
                .put("dns", dns)
                .put("route", JSONObject().put("final", "proxy").put("default_domain_resolver", "bootstrap"))
            val config = File.createTempFile("check-", ".json", context.cacheDir)
            val output = File.createTempFile("check-", ".log", context.cacheDir)
            var process: Process? = null
            try {
                config.writeText(root.toString())
                process = ProcessBuilder(CoreStore.selected(context).command("check", "-c", config.absolutePath))
                    .redirectErrorStream(true).redirectOutput(output).start()
                val ended = process.waitFor(5, TimeUnit.SECONDS)
                val code = if (ended) process.exitValue() else -1
                val unknown = if (ended) Regex("unknown field \\\"([a-zA-Z0-9_]+)\\\"").findAll(output.readText()).map { it.groupValues[1] }.distinct().toList() else emptyList()
                // Возвращаются только заранее известные фрагменты ошибок, без
                // значений конфигурации, адресов, заголовков и ключей.
                val diagnostics = if (ended) output.readText() else ""
                val reasons = listOf("into string", "into bool", "into int", "invalid type", "invalid range",
                    "unsupported session placement", "unsupported seq placement", "unsupported uplink data placement",
                    "unsupported x padding placement", "unsupported x padding method", "only in packet-up mode",
                    "required when session_length", "session id space", "must be above 0", "mutually exclusive",
                    "unknown mode", "expected a string").filter { diagnostics.contains(it, ignoreCase = true) }
                return mapOf("valid" to (ended && code == 0), "exitCode" to code, "unknownFields" to unknown, "reasons" to reasons)
            } finally {
                process?.let { if (it.isAlive) it.destroyForcibly() }
                config.delete(); output.delete()
            }
        }

        private fun exitMessage(code: Int): String = if (code == 159)
            "Android заблокировал системный вызов Linux-ядра (SIGSYS). Нужна сборка Tachyon для Android."
            else "Tachyon завершился с кодом $code"

        fun inspect(context: Context, executable: CoreExecutable = CoreStore.selected(context)): Map<String, Any> {
            val binary = executable.file
            if (!binary.isFile) return mapOf("compatible" to false, "message" to "Бинарник ядра отсутствует для этой архитектуры.")
            return try {
                val process = ProcessBuilder(executable.command("--version")).redirectErrorStream(true).start()
                if (!process.waitFor(5, TimeUnit.SECONDS)) {
                    process.destroyForcibly()
                    mapOf("compatible" to false, "message" to "Ядро не ответило на проверку запуска.")
                } else {
                    val code = process.exitValue()
                    val reported = process.inputStream.bufferedReader().use { it.readText().take(200) }.trim()
                    mapOf("compatible" to (code == 0), "exitCode" to code,
                        "reportedVersion" to reported, "selectionId" to executable.id,
                        "message" to if (code == 0) "Проверка запуска пройдена. VPN требует отдельной проверки." else exitMessage(code))
                }
            } catch (_: Exception) {
                mapOf("compatible" to false, "message" to "Android не смог запустить установленное ядро.")
            }
        }

        private fun token(): String = Base64.encodeToString(ByteArray(18).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP or Base64.URL_SAFE)

        fun start(context: Context, outboundText: String, log: (String) -> Unit = {}): CoreProcess {
            val dns = ProxyDns.load(context)
            val executable = CoreStore.selected(context)
            return try { startExact(context, outboundText, log, executable, dns = dns) } catch (failure: Exception) {
                if (executable.id == "bundled") throw failure
                CoreStore.reject(context, executable.id)
                val previous = CoreStore.selected(context)
                if (previous.id == executable.id) throw failure
                log("Новое ядро не запустилось; возврат к ${previous.version}")
                startExact(context, outboundText, log, previous, dns = dns)
            }
        }

        internal fun startExact(context: Context, outboundText: String, log: (String) -> Unit, executable: CoreExecutable, urlTest: Boolean = false, dns: JSONObject = ProxyDns.load(context)): CoreProcess {
            require(executable.file.isFile) { "Tachyon executable is not installed for this ABI" }
            val outbounds = parseOutbounds(outboundText)
            var controllerPort: Int? = null
            val port = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { reserved ->
                if (urlTest) controllerPort = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                reserved.localPort
            }
            val username = token(); val password = token()
            val controllerSecret = if (urlTest) token() else ""
            val root = JSONObject()
                .put("log", JSONObject().put("level", "info"))
                .put("dns", dns)
                .put("inbounds", JSONArray().put(JSONObject().put("type", "socks").put("tag", "vpn-socks").put("listen", "127.0.0.1").put("listen_port", port).put("users", JSONArray().put(JSONObject().put("username", username).put("password", password)))))
                .put("outbounds", outbounds)
                .put("route", JSONObject().put("final", "proxy").put("auto_detect_interface", false).put("default_domain_resolver", "bootstrap"))
            if (urlTest) root.put("experimental", JSONObject().put("clash_api", JSONObject()
                .put("external_controller", "127.0.0.1:$controllerPort").put("secret", controllerSecret)))
            val config = File.createTempFile("tachyon-", ".json", context.cacheDir)
            config.writeText(root.toString())
            // Android Process.destroy() сразу закрывает стандартные pipe.
            // Собственный reader живёт до последней строки журнала Tachyon.
            val output = try { ParcelFileDescriptor.createPipe() }
                catch (failure: Exception) { config.delete(); throw failure }
            val process = try {
                ProcessBuilder(executable.command("run", "-c", config.absolutePath))
                    .directory(context.filesDir).redirectErrorStream(true)
                    .redirectOutput(File("/proc/self/fd/${output[1].fd}")).start()
            } catch (failure: Exception) {
                output.forEach { runCatching { it.close() } }
                config.delete()
                throw failure
            } finally { runCatching { output[1].close() } }
            val core = CoreProcess(process, port, username, password, config, output[0], executable, controllerPort, controllerSecret)
            val secrets = mutableListOf(username, password)
            secrets.addAll(ProxyDns.redactions(dns))
            if (controllerSecret.isNotEmpty()) secrets.add(controllerSecret)
            fun collect(value: Any) {
                if (value is JSONObject) for (key in value.keys()) {
                    val item = value.get(key)
                    if (key in setOf("uuid", "password", "private_key", "public_key") && item is String && item.isNotEmpty()) secrets.add(item)
                    if (item is JSONObject || item is JSONArray) collect(item)
                }
                if (value is JSONArray) for (index in 0 until value.length()) collect(value.get(index))
            }
            collect(outbounds)
            core.outputThread = Thread({ runCatching { ParcelFileDescriptor.AutoCloseInputStream(output[0]).bufferedReader().useLines { lines -> lines.forEach { line -> log(secrets.fold(line) { text, secret -> text.replace(secret, "[скрыто]", ignoreCase = true) }) } } } }, "tachyon-output").apply { isDaemon = true; start() }
            try {
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                while (System.nanoTime() < deadline) {
                    if (!process.isAlive) throw IOException(exitMessage(process.exitValue()))
                    try {
                        Socket().use { socket ->
                            socket.connect(InetSocketAddress("127.0.0.1", port), 150)
                            socket.soTimeout = 300
                            val output = socket.getOutputStream(); val input = DataInputStream(socket.getInputStream())
                            output.write(byteArrayOf(5, 1, 2)); output.flush()
                            require(input.readUnsignedByte() == 5 && input.readUnsignedByte() == 2)
                            val user = username.toByteArray(); val pass = password.toByteArray()
                            output.write(byteArrayOf(1, user.size.toByte()) + user + byteArrayOf(pass.size.toByte()) + pass); output.flush()
                            require(input.readUnsignedByte() == 1 && input.readUnsignedByte() == 0)
                        }
                        if (urlTest) require(core.controllerRequest("/version").first == 200)
                        return core
                    } catch (_: Exception) { Thread.sleep(50) }
                }
                throw IOException("Tachyon readiness timeout")
            } catch (failure: Exception) { core.close(); throw failure }
        }

        fun urlTest(context: Context, outbound: String): Long =
            measureUrlTest(context, outbound, "https://www.gstatic.com/generate_204")

        internal fun urlTestFixture(context: Context, outbound: String, port: Int): Long {
            require(context.packageName.endsWith(".checks") && port in 1..65535)
            return measureUrlTest(context, outbound, "http://127.0.0.1:$port/check")
        }

        private fun measureUrlTest(context: Context, outbound: String, url: String): Long {
            // Возвращаем число самого Tachyon; запуск процесса и локальный API
            // не входят в измерение. Для HTTPS ядро начинает таймер после TLS.
            // Ошибка отдельного профиля не должна откатывать выбранное ядро.
            return startExact(context, outbound, {}, CoreStore.selected(context), urlTest = true).use { core ->
                val path = "/proxies/proxy/delay?timeout=5000&url=" + URLEncoder.encode(url, "UTF-8")
                val (status, body) = core.controllerRequest(path)
                if (status != 200) throw IOException("Tachyon URLTest failed")
                body.getLong("delay").also { require(it in 1..65535) { "Invalid Tachyon delay" } }
            }
        }

        fun measure(context: Context, outbound: String): Long {
            return start(context, outbound, RuntimeState::log).use { core ->
                val started = System.nanoTime()
                core.socket("www.gstatic.com", 443).use { socket ->
                    ((SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(socket, "www.gstatic.com", 443, true) as SSLSocket).use { tls ->
                        tls.sslParameters = tls.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                        tls.startHandshake()
                        tls.outputStream.write("GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n".toByteArray())
                        tls.outputStream.flush()
                        val line = tls.inputStream.bufferedReader().readLine() ?: throw IOException("Empty probe response")
                        require(line.startsWith("HTTP/1.1 204") || line.startsWith("HTTP/1.0 204")) { "Probe HTTP status" }
                    }
                }
                TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            }
        }
    }
}
