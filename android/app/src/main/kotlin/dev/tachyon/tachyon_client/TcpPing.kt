package dev.tachyon.tachyon_client

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

object TcpPing {
    fun measure(server: String, port: Int, type: String): Long {
        require(server.isNotBlank() && server.length <= 253 && port in 1..65535)
        require(type !in setOf("hysteria2", "hysteria", "tuic", "wireguard")) { "У этого протокола UDP-транспорт; TCPPing неприменим." }
        // DNS разрешается до замера: результат — только установка TCP-соединения.
        val addresses = InetAddress.getAllByName(server).take(4)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        for (address in addresses) {
            val remaining = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            if (remaining <= 0) break
            try {
                Socket().use { socket ->
                    val started = System.nanoTime()
                    socket.connect(InetSocketAddress(address, port), minOf(5000L, remaining).toInt().coerceAtLeast(1))
                    return TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started).coerceAtLeast(1)
                }
            } catch (_: java.io.IOException) { /* Пробуем следующий адрес сервера. */ }
        }
        error("Не удалось установить TCP-соединение с сервером профиля.")
    }
}
