package dev.tachyon.tachyon_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import hev.htproxy.TProxyService
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class TachyonVpnService : VpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger()
    private var tun: ParcelFileDescriptor? = null
    private var core: CoreProcess? = null
    private var tunnelConfig: File? = null
    private var tunnelStarted = false
    private var profileName = "VPN"
    private var startedAt = 0L
    @Volatile private var starting = false

    @Synchronized override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != START) { disconnect(); stopSelf(); return START_NOT_STICKY }
        if (starting || core != null) return START_NOT_STICKY
        val outbound = intent.getStringExtra("outbound")
        if (outbound == null || outbound.length > 1_048_576) { stopSelf(); return START_NOT_STICKY }
        starting = true
        profileName = VpnNotification.profileName(intent.getStringExtra("profileName"))
        startedAt = System.currentTimeMillis()
        val current = generation.incrementAndGet()
        RuntimeState.state = "connecting"; RuntimeState.message = ""
        VpnTileService.refresh(this)
        RuntimeState.log("Подключение через Tachyon")
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "VPN-подключение", NotificationManager.IMPORTANCE_LOW))
        startForeground(1, notification("Подключение…"))
        worker.execute {
            try {
                val engine = CoreProcess.start(this, outbound, RuntimeState::log)
                var lastTrafficText = ""
                synchronized(this) {
                    if (generation.get() != current) { engine.close(); return@synchronized }
                    core = engine
                    RuntimeState.activeCoreVersion = engine.executable.version
                    RuntimeState.activeCoreId = engine.executable.id
                    val device = Builder().setSession("Tachyon Client").setMtu(1500)
                        .addAddress("198.18.0.1", 30).addAddress("fd00:1:fd00:1::1", 126)
                        .addRoute("0.0.0.0", 0).addRoute("::", 0).addDnsServer("1.1.1.1")
                        // Дочернее ядро имеет тот же UID: его сокеты не попадут в собственный TUN.
                        .addDisallowedApplication(packageName).establish() ?: error("Android did not create TUN")
                    tun = device
                    val config = File.createTempFile("tunnel-", ".yaml", cacheDir)
                    tunnelConfig = config
                    config.writeText("""
                        tunnel:
                          mtu: 1500
                          ipv4: 198.18.0.1
                          ipv6: 'fd00:1:fd00:1::1'
                        socks5:
                          address: 127.0.0.1
                          port: ${engine.port}
                          udp: udp
                          username: '${engine.username}'
                          password: '${engine.password}'
                        misc:
                          log-level: warn
                    """.trimIndent())
                    check(TProxyService.TProxyStartService(config.absolutePath, device.fd)) { "Packet bridge failed to start" }
                    tunnelStarted = true
                    Thread.sleep(150)
                    check(TProxyService.TProxyIsRunning()) { "Packet bridge is not running" }
                    RuntimeState.state = "running"
                    VpnTileService.refresh(this)
                    starting = false
                    RuntimeState.log("VPN подключён")
                    lastTrafficText = VpnNotification.trafficText(RuntimeState.traffic())
                    notifications.notify(1, notification(lastTrafficText))
                }
                var nextTrafficUpdate = SystemClock.elapsedRealtime() + 2000
                while (generation.get() == current) {
                    check(engine.process.isAlive) { "Ядро завершилось с кодом ${engine.process.exitValue()}" }
                    check(TProxyService.TProxyIsRunning()) { "Пакетный мост завершился" }
                    if (SystemClock.elapsedRealtime() >= nextTrafficUpdate) {
                        synchronized(this) {
                            // Не возвращаем уведомление после отключения или смены подключения.
                            if (generation.get() == current && RuntimeState.state == "running") {
                                val text = VpnNotification.trafficText(RuntimeState.traffic())
                                if (text != lastTrafficText) {
                                    notifications.notify(1, notification(text))
                                    lastTrafficText = text
                                }
                            }
                        }
                        nextTrafficUpdate = SystemClock.elapsedRealtime() + 2000
                    }
                    Thread.sleep(500)
                }
            } catch (failure: Throwable) {
                synchronized(this) {
                    if (generation.get() == current) {
                        RuntimeState.log("Ошибка запуска: ${failure.message ?: failure.javaClass.simpleName}")
                        disconnect(failed = true)
                        stopSelf()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun notification(text: String): Notification =
        VpnNotification.build(this, CHANNEL, profileName, text, startedAt)

    @Synchronized private fun disconnect(failed: Boolean = false) {
        generation.incrementAndGet()
        starting = false
        if (tunnelStarted) { runCatching { TProxyService.TProxyStopService() }; tunnelStarted = false }
        runCatching { tun?.close() }; tun = null
        runCatching { core?.close() }; core = null
        RuntimeState.activeCoreVersion = ""; RuntimeState.activeCoreId = ""
        tunnelConfig?.delete(); tunnelConfig = null
        RuntimeState.state = if (failed) "error" else "stopped"
        RuntimeState.message = if (failed) "Не удалось установить VPN. Подробности — в журнале." else ""
        VpnTileService.refresh(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onRevoke() { RuntimeState.log("Разрешение VPN отозвано системой"); disconnect(); stopSelf(); super.onRevoke() }
    override fun onDestroy() { val failed = RuntimeState.state == "error"; disconnect(failed); worker.shutdownNow(); super.onDestroy() }

    companion object {
        const val START = "dev.tachyon.client.START"
        const val STOP = "dev.tachyon.client.STOP"
        private const val CHANNEL = "tachyon-vpn"
    }
}
