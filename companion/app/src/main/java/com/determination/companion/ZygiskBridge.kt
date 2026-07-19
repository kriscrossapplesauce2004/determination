package com.determination.companion

import android.net.LocalSocket
import android.net.LocalSocketAddress

/** Narrow root RPC supplied by the injected Determination Zygisk module. */
object ZygiskBridge {
    private const val SOCKET = "determination.companion.bridge"

    fun command(command: String): Root.Result? {
        if (command !in setOf("ping", "enter", "exit")) return null
        return try {
            LocalSocket().use { socket ->
                socket.connect(
                    LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.ABSTRACT),
                )
                socket.soTimeout = 5_000
                socket.outputStream.write("$command\n".toByteArray())
                socket.outputStream.flush()
                socket.shutdownOutput()
                val response = socket.inputStream.bufferedReader().readText().trim()
                when {
                    response.startsWith("ok") -> Root.Result(true, response.removePrefix("ok").trim(), "")
                    response.startsWith("error ") -> Root.Result(false, "", response.removePrefix("error "))
                    else -> Root.Result(false, "", response.ifBlank { "empty Zygisk response" })
                }
            }
        } catch (_: Exception) {
            null // Old/inactive module: caller uses the established su fallback.
        }
    }
}
