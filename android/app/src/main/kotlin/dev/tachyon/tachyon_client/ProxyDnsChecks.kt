package dev.tachyon.tachyon_client

import android.content.Context
import org.json.JSONObject

object ProxyDnsChecks {
    fun run(context: Context): Map<String, Boolean> {
        require(context.packageName.endsWith(".checks"))
        val examples = listOf(
            "system" to "", "udp" to "127.0.0.1:5353", "tcp" to "[::1]:5353",
            "doh" to "https://dns.example/custom/dns-query", "dot" to "dns.example:8853"
        )
        for ((mode, address) in examples) {
            val config = ProxyDns.configuration(JSONObject().put("mode", mode).put("address", address))
            val result = CoreProcess.checkOutbounds(context, "{\"type\":\"direct\",\"tag\":\"proxy\"}", config)
            check(result["valid"] == true) { "DNS mode rejected by core: $mode" }
            val servers = config.getJSONArray("servers")
            if (mode != "system") {
                val upstream = servers.getJSONObject(1)
                check(upstream.getString("domain_resolver") == "bootstrap-system")
                if (mode in setOf("doh", "dot")) {
                    check(upstream.getJSONObject("tls").getBoolean("enabled"))
                    check(!upstream.getJSONObject("tls").optBoolean("insecure"))
                    check(upstream.getJSONObject("tls").getString("server_name") == "dns.example")
                }
                if (mode == "doh") check(upstream.getString("path") == "/custom/dns-query")
                if (mode == "dot") check(upstream.getInt("server_port") == 8853)
                if (mode == "tcp") check(upstream.getString("server") == "::1")
            }
        }
        for ((mode, value) in listOf("doh" to "http://dns.example/query", "doh" to "https://u:p@dns.example/query", "doh" to "https://dns.example/query?token=example", "tcp" to "1.1.1.1:99999", "dot" to "dns.example/path")) {
            check(runCatching { ProxyDns.configuration(JSONObject().put("mode", mode).put("address", value)) }.isFailure)
        }
        return mapOf("allModesAcceptedByCore" to true, "verifiedTls" to true, "localBootstrap" to true, "invalidRejected" to true)
    }
}
