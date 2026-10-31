package dev.tachyon.tachyon_client

import android.content.Context
import hev.htproxy.TProxyService
import java.time.LocalTime

data class SessionTraffic(val upload: Long, val download: Long)

object RuntimeState {
    @Volatile var state = "stopped"
    @Volatile var message = ""
    @Volatile var activeCoreVersion = ""
    @Volatile var activeCoreId = ""
    private val logs = ArrayDeque<String>()

    @Synchronized fun log(value: String) {
        val safe = value.replace(Regex("[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"), "[UUID]")
            .replace(Regex("(?i)(?:https?|vless|trojan|hysteria2)://\\S+"), "[URL]")
            .replace(Regex("(?i)(password|public_key|private_key|authorization)[=: ]+[^ ,}]+"), "$1=[скрыто]").take(1000)
        logs.addLast("${LocalTime.now().withNano(0)}  $safe")
        while (logs.size > 250) logs.removeFirst()
    }

    fun traffic(): SessionTraffic {
        val stats = if (state == "running") try { TProxyService.TProxyGetStats() } catch (_: Throwable) { longArrayOf(0, 0, 0, 0) } else longArrayOf(0, 0, 0, 0)
        return SessionTraffic(stats.getOrElse(1) { 0L }.coerceAtLeast(0), stats.getOrElse(3) { 0L }.coerceAtLeast(0))
    }

    fun snapshot(context: Context): Map<String, Any> {
        val history = synchronized(this) { logs.toList() }
        val traffic = traffic()
        val core = CoreStore.snapshot(context)
        return mapOf("state" to state, "message" to message, "logs" to history, "upload" to traffic.upload, "download" to traffic.download,
            "coreVersion" to (core["installedVersion"] ?: "Не установлено"), "coreSelectionId" to (core["selectionId"] ?: "bundled"),
            "runningCoreVersion" to activeCoreVersion, "runningCoreId" to activeCoreId,
            "coreManager" to core, "coreUpdate" to CoreUpdater.snapshot(context))
    }
}
