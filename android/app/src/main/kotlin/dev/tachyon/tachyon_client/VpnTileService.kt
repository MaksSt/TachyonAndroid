package dev.tachyon.tachyon_client

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import java.util.concurrent.Executors
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/** Плитка не хранит копию профиля: каждое подключение читает текущий выбор. */
class VpnTileService : TileService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val clicking = AtomicBoolean()
    private var listening = false
    private val stateListener: () -> Unit = {
        main.post { if (listening) updateState() }
        Unit
    }

    override fun onStartListening() {
        super.onStartListening()
        listening = true
        addStateListener(stateListener)
        updateState()
    }

    private fun updateState() {
        val connectionState = RuntimeState.state
        qsTile?.apply {
            label = "Tachyon"
            state = tileState(connectionState)
            subtitle = when (connectionState) {
                "running" -> "Подключено"
                "connecting" -> "Подключение…"
                "error" -> "Ошибка подключения"
                else -> "Отключено"
            }
            contentDescription = "Tachyon VPN: $subtitle"
            updateTile()
        }
    }

    override fun onStopListening() {
        listening = false
        removeStateListener(stateListener)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { toggle() } else toggle()
    }

    private fun toggle() {
        if (!clicking.compareAndSet(false, true)) return
        worker.execute {
            try {
                if (RuntimeState.state in setOf("running", "connecting")) {
                    startService(Intent(this, TachyonVpnService::class.java).setAction(TachyonVpnService.STOP))
                } else {
                    val selection = selectedProfile(SecureStateStore(this).load())
                    if (selection == null) {
                        main.post {
                            Toast.makeText(this, "Сначала выберите профиль в приложении.", Toast.LENGTH_LONG).show()
                            openCollapsed(MainActivity::class.java)
                        }
                    } else if (VpnService.prepare(this) != null) {
                        main.post { openCollapsed(TileConnectActivity::class.java) }
                    } else {
                        startForegroundService(startIntent(this, selection.outbound, selection.name))
                    }
                }
            } catch (_: Exception) {
                main.post { Toast.makeText(this, "Не удалось переключить VPN. Откройте Tachyon.", Toast.LENGTH_LONG).show() }
            } finally {
                clicking.set(false)
                refresh(this)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun openCollapsed(activity: Class<*>) {
        val intent = Intent(this, activity).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 8301, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        } else {
            startActivityAndCollapse(intent)
        }
    }

    override fun onDestroy() {
        listening = false
        removeStateListener(stateListener)
        worker.shutdown()
        super.onDestroy()
    }

    companion object {
        private val stateListeners = CopyOnWriteArraySet<() -> Unit>()

        internal fun addStateListener(listener: () -> Unit) { stateListeners.add(listener) }
        internal fun removeStateListener(listener: () -> Unit) { stateListeners.remove(listener) }

        fun refresh(context: Context) {
            // requestListeningState не заменяет обновление уже слушающего экземпляра.
            stateListeners.forEach { it() }
            // Плитка может ещё не быть добавлена пользователем.
            runCatching { requestListeningState(context, ComponentName(context, VpnTileService::class.java)) }
        }

        fun tileState(state: String): Int =
            if (state == "running") Tile.STATE_ACTIVE else Tile.STATE_INACTIVE

        data class Selection(val outbound: String, val name: String)

        fun selectedOutbound(saved: String?): String? = selectedProfile(saved)?.outbound

        fun selectedProfile(saved: String?): Selection? {
            if (saved == null) return null
            val root = JSONObject(saved)
            if (root.isNull("selectedId")) return null
            val selected = root.optString("selectedId")
            if (selected.isEmpty()) return null
            val profiles = root.optJSONArray("profiles") ?: return null
            for (index in 0 until profiles.length()) {
                val profile = profiles.optJSONObject(index) ?: continue
                if (profile.optString("id") != selected) continue
                val outbound = profile.getJSONObject("outbound")
                require(outbound.getString("type").isNotBlank())
                val extra = profile.optJSONArray("extraOutbounds")
                val group = org.json.JSONArray().put(outbound)
                if (extra != null) for (position in 0 until extra.length()) group.put(extra.getJSONObject(position))
                val config = (if (group.length() == 1) outbound.toString() else group.toString()).also { require(it.length <= 1_048_576) }
                CoreProcess.parseOutbounds(config)
                return Selection(config, VpnNotification.profileName(profile.optString("name")))
            }
            return null
        }

        fun startIntent(context: Context, outbound: String, profileName: String = "VPN"): Intent =
            Intent(context, TachyonVpnService::class.java).setAction(TachyonVpnService.START)
                .putExtra("outbound", outbound).putExtra("profileName", VpnNotification.profileName(profileName))
    }
}
