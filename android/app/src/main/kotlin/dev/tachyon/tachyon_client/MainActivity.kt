package dev.tachyon.tachyon_client

import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.widget.Toast
import android.Manifest
import android.content.Intent
import android.net.VpnService
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import java.security.MessageDigest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val tcpWorkers = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private var pendingProfileName: String? = null
    private val permissionRequest = 8421
    private var cachedCoreInfo: Map<String, Any>? = null
    private var cachedCoreSelection = ""

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = SecureStateStore(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.tachyon.client/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "requestVpnTile" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 33) {
                            getSystemService(StatusBarManager::class.java).requestAddTileService(
                                ComponentName(this, VpnTileService::class.java), "Tachyon",
                                Icon.createWithResource(this, R.drawable.ic_stat_tachyon), mainExecutor
                            ) { status ->
                                if (status in setOf(StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED,
                                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED,
                                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED)) result.success(null)
                                else result.error("tile", "Не удалось открыть добавление плитки. Добавьте Tachyon через редактирование шторки.", null)
                            }
                        } else {
                            Toast.makeText(this, "Откройте шторку → Изменить → добавьте Tachyon.", Toast.LENGTH_LONG).show()
                            result.success(null)
                        }
                    } catch (_: Exception) { result.error("tile", "Добавьте Tachyon через редактирование шторки.", null) }
                }
                "quickSettingsCheck", "notificationCheck", "dnsSettingsCheck" -> {
                    if (!packageName.endsWith(".checks")) {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        try {
                            val info = when (call.method) {
                                "notificationCheck" -> VpnNotificationChecks.run(applicationContext)
                                "dnsSettingsCheck" -> ProxyDnsChecks.run(applicationContext)
                                else -> VpnTileChecks.run(applicationContext)
                            }
                            main.post { result.success(info) }
                        } catch (_: Exception) { main.post { result.error("tile-check", "Quick Settings contract check failed.", null) } }
                    }
                }
                "deviceInfo" -> {
                    try {
                        val id = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                        require(!id.isNullOrEmpty())
                        val hash = MessageDigest.getInstance("SHA-256").digest("$id:$packageName:hwid-v1".toByteArray())
                        val hwid = "and-" + hash.take(16).joinToString("") { "%02x".format(it.toInt() and 255) }
                        fun header(value: String) = value.filter { it.code in 32..126 }.take(160)
                        result.success(mapOf("packageId" to packageName, "hwid" to hwid, "osVersion" to header(Build.VERSION.RELEASE),
                            "model" to header("${Build.MANUFACTURER} ${Build.MODEL}")))
                    } catch (_: Exception) { result.error("identity", "Не удалось получить HWID устройства.", null) }
                }
                "coreInfo" -> worker.execute {
                    val selected = CoreStore.selected(this)
                    val info = cachedCoreInfo?.takeIf { cachedCoreSelection == selected.id } ?: CoreProcess.inspect(this, selected).also {
                        cachedCoreInfo = it
                        cachedCoreSelection = selected.id
                        if (it["compatible"] == false) RuntimeState.log("Проверка ядра: ${it["message"]}")
                    }
                    main.post { result.success(info) }
                }
                "startCoreUpdate" -> {
                    try { CoreUpdateJobService.enqueue(this); result.success(null) }
                    catch (failure: Exception) { result.error("core-update", failure.message, null) }
                }
                "setCoreAutoUpdate" -> {
                    try {
                        CoreUpdateJobService.configureAuto(this, call.argument<Boolean>("enabled") == true)
                        result.success(null)
                    } catch (failure: Exception) { result.error("core-auto-update", failure.message, null) }
                }
                "rollbackCore" -> worker.execute {
                    try { CoreStore.rollback(this); main.post { result.success(null) } }
                    catch (_: Exception) { main.post { result.error("core-rollback", "Не удалось выбрать предыдущую версию ядра.", null) } }
                }
                "coreLifecycleCheck" -> {
                    if (!packageName.endsWith(".checks")) {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        try {
                            val core = CoreProcess.start(this, "{\"type\":\"direct\"}")
                            core.close()
                            val info = mapOf("alive" to core.process.isAlive, "exitCode" to core.process.exitValue())
                            main.post { result.success(info) }
                        } catch (_: Exception) { main.post { result.error("lifecycle", "Core lifecycle check failed.", null) } }
                    }
                }
                "managedCoreStoreCheck" -> {
                    if (!packageName.endsWith(".checks")) {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        try {
                            val info = CoreUpdateChecks.run(applicationContext)
                            main.post { result.success(info) }
                        } catch (failure: Exception) {
                            main.post { result.error("managed-check", failure.message, null) }
                        }
                    }
                }
                "vpnNetworkCheck" -> {
                    if (!packageName.endsWith(".checks")) {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val network = getSystemService(ConnectivityManager::class.java)
                    val capabilities = network.getNetworkCapabilities(network.activeNetwork)
                    result.success(capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true)
                }
                "openUrl" -> {
                    try {
                        val uri = Uri.parse(call.argument<String>("url") ?: "")
                        require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null)
                        startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                        result.success(null)
                    } catch (_: Exception) { result.error("link", "Не удалось открыть ссылку.", null) }
                }
                "status" -> result.success(RuntimeState.snapshot(this))
                "loadState" -> worker.execute {
                    try { val value = store.load(); main.post { result.success(value) } }
                    catch (_: Exception) { main.post { result.error("storage", "Не удалось прочитать защищённые данные.", null) } }
                }
                "saveState" -> {
                    val value = call.argument<String>("data")
                    if (value == null) { result.error("arguments", "Не переданы данные.", null); return@setMethodCallHandler }
                    worker.execute {
                        try { store.save(value); main.post { result.success(null) } }
                        catch (_: Exception) { main.post { result.error("storage", "Не удалось сохранить защищённые данные.", null) } }
                    }
                }
                "connect" -> {
                    val value = call.argument<String>("outbound")
                    if (value == null || value.length > 1_048_576) { result.error("arguments", "Некорректная конфигурация профиля.", null); return@setMethodCallHandler }
                    if (pending != null) { result.error("busy", "Запрос разрешения VPN уже открыт.", null); return@setMethodCallHandler }
                    pending = result; pendingConfig = value
                    pendingProfileName = VpnNotification.profileName(call.argument<String>("profileName"))
                    val permission = VpnService.prepare(this)
                    if (permission == null) startPending() else startActivityForResult(permission, permissionRequest)
                }
                "disconnect" -> {
                    startService(Intent(this, TachyonVpnService::class.java).setAction(TachyonVpnService.STOP))
                    result.success(null)
                }
                "urlTest", "urlTestFixture" -> {
                    if (call.method == "urlTestFixture" && !packageName.endsWith(".checks")) {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val outbound = call.argument<String>("outbound")
                    if (outbound == null || outbound.length > 1_048_576) { result.error("url-test", "Некорректная конфигурация профиля.", null); return@setMethodCallHandler }
                    val fixturePort = call.argument<Int>("port")
                    tcpWorkers.execute {
                        try {
                            val delay = if (call.method == "urlTestFixture") CoreProcess.urlTestFixture(this, outbound, fixturePort ?: 0)
                                else CoreProcess.urlTest(this, outbound)
                            main.post { result.success(delay) }
                        } catch (_: Exception) { main.post { result.error("url-test", "URLTest: нет ответа через профиль.", null) } }
                    }
                }
                "tcpPing" -> {
                    val server = call.argument<String>("server")
                    val port = call.argument<Int>("port")
                    val type = call.argument<String>("type")
                    if (server == null || port == null || type == null) { result.error("tcp-ping", "В профиле нет TCP-адреса сервера.", null); return@setMethodCallHandler }
                    tcpWorkers.execute {
                        try { val millis = TcpPing.measure(server, port, type); main.post { result.success(millis) } }
                        catch (_: Exception) { main.post { result.error("tcp-ping", "Не удалось установить TCP-соединение с сервером профиля.", null) } }
                    }
                }
                "outboundConfigCheck" -> {
                    if (!packageName.endsWith(".checks")) {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val value = call.argument<String>("outbound")
                    if (value == null || value.length > 1_048_576) { result.error("arguments", "Invalid outbound configuration", null); return@setMethodCallHandler }
                    worker.execute {
                        try { val info = CoreProcess.checkOutbounds(this, value); main.post { result.success(info) } }
                        catch (_: Exception) { main.post { result.error("check", "Configuration validation failed", null) } }
                    }
                }
                "httpsProbe" -> {
                    val value = call.argument<String>("outbound")
                    if (value == null) { result.error("arguments", "Не указан профиль.", null); return@setMethodCallHandler }
                    worker.execute {
                        try { val millis = CoreProcess.measure(this, value); main.post { result.success(millis) } }
                        catch (_: Exception) { main.post { result.error("probe", "Профиль не прошёл проверку подключения.", null) } }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startPending() {
        val result = pending ?: return
        val config = pendingConfig
        val profileName = pendingProfileName ?: "VPN"
        pending = null; pendingConfig = null; pendingProfileName = null
        try {
            require(config != null)
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest + 1)
            }
            startForegroundService(VpnTileService.startIntent(this, config, profileName))
            result.success(null)
        } catch (_: Exception) { result.error("start", "Не удалось запустить VPN-службу.", null) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != permissionRequest) return
        if (resultCode == Activity.RESULT_OK) startPending()
        else { pending?.error("permission", "Разрешение VPN не предоставлено.", null); pending = null; pendingConfig = null; pendingProfileName = null }
    }

    override fun onDestroy() {
        pending?.error("cancelled", "Окно приложения закрыто.", null)
        pending = null; pendingConfig = null; pendingProfileName = null
        worker.shutdown()
        tcpWorkers.shutdown()
        super.onDestroy()
    }
}
