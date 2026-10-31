package dev.tachyon.tachyon_client

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import java.util.Locale

object VpnNotification {
    fun profileName(value: String?): String = value?.replace(Regex("[\\x00-\\x1f\\x7f]"), " ")
        ?.trim()?.take(200)?.takeIf { it.isNotEmpty() } ?: "VPN"

    fun formatBytes(value: Long): String {
        val units = arrayOf("Б", "КиБ", "МиБ", "ГиБ", "ТиБ")
        var amount = value.coerceAtLeast(0).toDouble()
        var unit = 0
        while (amount >= 1024 && unit < units.lastIndex) { amount /= 1024; unit++ }
        return if (unit == 0) "${amount.toLong()} ${units[unit]}"
            else String.format(Locale.US, "%.1f %s", amount, units[unit])
    }

    fun trafficText(traffic: SessionTraffic): String =
        "↓ ${formatBytes(traffic.download)} · ↑ ${formatBytes(traffic.upload)}"

    fun build(context: Context, channel: String, name: String, text: String, startedAt: Long): Notification {
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(context, 1, Intent(context, TachyonVpnService::class.java).setAction(TachyonVpnService.STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(context, channel).setContentTitle(profileName(name)).setContentText(text)
            .setWhen(startedAt).setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_stat_tachyon).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Отключить", stop).build()).build()
    }
}
