package dev.tachyon.tachyon_client

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.service.quicksettings.Tile
import org.json.JSONArray
import org.json.JSONObject

object VpnTileChecks {
    @Suppress("DEPRECATION")
    fun run(context: Context): Map<String, Boolean> {
        check(context.packageName.endsWith(".checks"))
        val store = SecureStateStore(context)
        val old = store.load()
        val first = JSONObject().put("id", "first").put("outbound", JSONObject().put("type", "direct"))
        val selected = JSONObject().put("id", "selected").put("name", "Тестовый сервер").put("outbound",
            JSONObject().put("type", "trojan").put("server", "example.invalid").put("server_port", 443))
        val state = JSONObject().put("schema", 2).put("selectedId", "selected")
            .put("profiles", JSONArray().put(first).put(selected))
        try {
            store.save(state.toString())
            // Другой экземпляр, как при холодном запуске TileService.
            val selection = VpnTileService.selectedProfile(SecureStateStore(context).load())!!
            val outbound = selection.outbound
            check(JSONObject(outbound).getString("type") == "trojan")
            check(selection.name == "Тестовый сервер")
            selected.getJSONObject("outbound").put("detour", "chain-1")
            selected.put("extraOutbounds", JSONArray().put(JSONObject().put("type", "vless").put("tag", "chain-1").put("server", "relay.invalid").put("server_port", 443)))
            store.save(state.toString())
            val chained = CoreProcess.parseOutbounds(VpnTileService.selectedProfile(SecureStateStore(context).load())!!.outbound)
            check(chained.length() == 2 && chained.getJSONObject(0).getString("detour") == "chain-1")
            check(chained.getJSONObject(1).getString("server") == "relay.invalid")
            state.put("selectedId", "removed")
            check(VpnTileService.selectedOutbound(state.toString()) == null)
            state.put("selectedId", JSONObject.NULL)
            check(VpnTileService.selectedOutbound(state.toString()) == null)
            check(VpnTileService.selectedOutbound(null) == null)
            check(runCatching { VpnTileService.selectedOutbound("invalid JSON") }.isFailure)
            val tile = context.packageManager.getServiceInfo(ComponentName(context, VpnTileService::class.java), PackageManager.GET_META_DATA)
            check(tile.exported && tile.permission == "android.permission.BIND_QUICK_SETTINGS_TILE")
            check(tile.metaData.getBoolean("android.service.quicksettings.ACTIVE_TILE"))
            check(tile.metaData.getBoolean("android.service.quicksettings.TOGGLEABLE_TILE"))
            val activity = context.packageManager.getActivityInfo(ComponentName(context, TileConnectActivity::class.java), 0)
            check(!activity.exported)
            check(VpnTileService.tileState("running") == Tile.STATE_ACTIVE)
            check(VpnTileService.tileState("connecting") == Tile.STATE_INACTIVE)
            check(VpnTileService.tileState("stopped") == Tile.STATE_INACTIVE)
            check(VpnTileService.tileState("error") == Tile.STATE_INACTIVE)
            var updates = 0
            val listener: () -> Unit = { updates++ }
            VpnTileService.addStateListener(listener)
            try {
                VpnTileService.refresh(context)
                check(updates == 1)
            } finally { VpnTileService.removeStateListener(listener) }
            VpnTileService.refresh(context)
            check(updates == 1)
            val intent = VpnTileService.startIntent(context, outbound, selection.name)
            check(intent.component == ComponentName(context, TachyonVpnService::class.java))
            check(intent.action == TachyonVpnService.START && intent.getStringExtra("outbound") == outbound)
            check(intent.getStringExtra("profileName") == selection.name)
            return mapOf("selectedEncryptedProfile" to true, "noFallbackProfile" to true,
                "protectedTileAndPermissionActivity" to true, "stateMapping" to true, "vpnStartIntent" to true,
                "liveStateUpdates" to true, "proxyChains" to true)
        } finally { store.save(old ?: "{}") }
    }
}
