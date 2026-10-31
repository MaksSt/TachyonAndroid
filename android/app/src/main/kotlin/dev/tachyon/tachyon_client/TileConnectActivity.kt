package dev.tachyon.tachyon_client

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.widget.Toast
import java.util.concurrent.Executors

/** Неэкспортируемое окно для первого системного разрешения VPN из плитки. */
class TileConnectActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var awaitingPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        awaitingPermission = savedInstanceState?.getBoolean("awaitingPermission") == true
        if (awaitingPermission) return
        val permission = VpnService.prepare(this)
        if (permission == null) connect() else {
            awaitingPermission = true
            startActivityForResult(permission, REQUEST_VPN)
        }
    }

    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_VPN) return
        awaitingPermission = false
        if (resultCode == RESULT_OK) connect() else finish()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("awaitingPermission", awaitingPermission)
        super.onSaveInstanceState(outState)
    }

    private fun connect() {
        worker.execute {
            try {
                val selection = VpnTileService.selectedProfile(SecureStateStore(this).load())
                if (selection == null) {
                    runOnUiThread {
                        Toast.makeText(this, "Сначала выберите профиль в приложении.", Toast.LENGTH_LONG).show()
                        startActivity(Intent(this, MainActivity::class.java))
                        finish()
                    }
                } else {
                    startForegroundService(VpnTileService.startIntent(this, selection.outbound, selection.name))
                    runOnUiThread { finish() }
                }
            } catch (_: Exception) {
                runOnUiThread {
                    Toast.makeText(this, "Не удалось включить VPN. Откройте Tachyon.", Toast.LENGTH_LONG).show()
                    finish()
                }
            }
        }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    companion object { private const val REQUEST_VPN = 8302 }
}
