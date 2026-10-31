package dev.tachyon.tachyon_client

import android.app.Notification
import android.content.Context

object VpnNotificationChecks {
    fun run(context: Context): Map<String, Boolean> {
        check(context.packageName.endsWith(".checks"))
        val text = VpnNotification.trafficText(SessionTraffic(upload = 1024, download = 2_097_152))
        check(text == "↓ 2.0 МиБ · ↑ 1.0 КиБ")
        check(VpnNotification.trafficText(SessionTraffic(0, 0)) == "↓ 0 Б · ↑ 0 Б")
        check(VpnNotification.formatBytes(-1) == "0 Б")
        val first = VpnNotification.build(context, "checks-vpn", "Финляндия", text, 123456789L)
        check(first.extras.getCharSequence(Notification.EXTRA_TITLE).toString() == "Финляндия")
        check(first.extras.getCharSequence(Notification.EXTRA_TEXT).toString() == text)
        check(first.flags and Notification.FLAG_ONGOING_EVENT != 0)
        check(first.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        check(first.actions.single().title.toString() == "Отключить")
        val next = VpnNotification.build(context, "checks-vpn", "Финляндия",
            VpnNotification.trafficText(SessionTraffic(2048, 4_194_304)), 123456789L)
        check(next.`when` == first.`when`)
        check(next.extras.getCharSequence(Notification.EXTRA_TEXT).toString() == "↓ 4.0 МиБ · ↑ 2.0 КиБ")
        check(VpnNotification.profileName("\nФинляндия\r") == "Финляндия")
        check(VpnNotification.profileName(null) == "VPN")
        return mapOf("serverTitle" to true, "sessionTrafficText" to true, "quietUpdates" to true,
            "stableTimestamp" to true, "disconnectAction" to true)
    }
}
