package dev.tachyon.tachyon_client

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** Bootstrap DNS адресов прокси; DNS-запросы приложений внутри TUN задаются отдельно. */
object ProxyDns {
    fun load(context: Context): JSONObject {
        val text = SecureStateStore(context).load() ?: return configuration(null)
        val options = try {
            val state = JSONObject(text)
            if (state.isNull("dns")) null else state.optJSONObject("dns") ?: error("Invalid DNS settings")
        } catch (_: Exception) { throw IllegalArgumentException("Invalid saved DNS settings") }
        return configuration(options)
    }

    internal fun configuration(options: JSONObject?): JSONObject {
        val mode = options?.optString("mode", "system") ?: "system"
        require(mode in setOf("system", "udp", "tcp", "doh", "dot")) { "Unknown bootstrap DNS mode" }
        if (mode == "system") return JSONObject()
            .put("servers", JSONArray().put(JSONObject().put("type", "local").put("tag", "bootstrap")))
            .put("final", "bootstrap")
        val value = options!!.getString("address").trim()
        require(value.isNotEmpty() && value.none { it.isWhitespace() || it.code < 32 || it.code == 127 }) { "Invalid bootstrap DNS address" }
        val uri = try { URI(if (mode == "doh") value else "dns://$value") }
            catch (_: Exception) { throw IllegalArgumentException("Invalid bootstrap DNS address") }
        val host = uri.host?.removeSurrounding("[", "]") ?: error("Invalid bootstrap DNS host")
        require(host.isNotEmpty() && uri.userInfo == null && uri.query == null && uri.fragment == null) { "Invalid bootstrap DNS address" }
        require(uri.port == -1 || uri.port in 1..65535) { "Invalid bootstrap DNS port" }
        require(if (mode == "doh") uri.scheme == "https" else uri.rawPath.isNullOrEmpty()) { "Invalid bootstrap DNS protocol" }
        val type = when (mode) { "doh" -> "https"; "dot" -> "tls"; else -> mode }
        val port = if (uri.port != -1) uri.port else when (mode) { "doh" -> 443; "dot" -> 853; else -> 53 }
        val upstream = JSONObject().put("type", type).put("tag", "bootstrap")
            .put("server", host).put("server_port", port).put("domain_resolver", "bootstrap-system")
        if (mode in setOf("doh", "dot")) {
            upstream.put("tls", JSONObject().put("enabled", true).put("server_name", host))
        }
        if (mode == "doh") upstream.put("path", uri.rawPath.takeUnless { it.isNullOrEmpty() } ?: "/dns-query")
        return JSONObject().put("servers", JSONArray()
            .put(JSONObject().put("type", "local").put("tag", "bootstrap-system"))
            .put(upstream)).put("final", "bootstrap")
    }

    fun redactions(dns: JSONObject): List<String> {
        val servers = dns.getJSONArray("servers")
        return (0 until servers.length()).flatMap { index ->
            val item = servers.getJSONObject(index)
            listOf(item.optString("server"), item.optString("path"))
        }.filter { it.length > 1 }
    }
}
