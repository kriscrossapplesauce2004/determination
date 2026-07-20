package com.determination.companion

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Versioned, same-UID app bridge to the root-owned Determination control API. */
object ZygiskBridge {
    private const val SOCKET = "determination.companion.bridge"
    private const val MAGIC = 0x44544331
    private const val MAJOR: Short = 1
    private const val MINOR: Short = 0
    private const val HEADER_SIZE = 48
    private const val MAX_PAYLOAD = 16 * 1024

    const val OP_HELLO = 1
    const val OP_PING = 2
    const val OP_STATUS = 3
    const val OP_DOCTOR = 4
    const val OP_CAPABILITIES = 5
    const val OP_METRICS = 6
    const val OP_MODE_GET = 0x100
    const val OP_MODE_SET = 0x101
    const val OP_MODE_RECOVER = 0x102

    const val STATUS_OK = 0
    const val STATUS_ACCEPTED = 1
    const val STATUS_REJECTED = -1
    const val STATUS_UNAVAILABLE = -2
    const val STATUS_DEADLINE = -3
    const val STATUS_BUSY = -4
    const val STATUS_PROTOCOL = -5
    const val STATUS_INVALID = -6
    const val STATUS_PERMISSION = -7
    const val STATUS_RECOVERY = -8
    const val STATUS_INTERNAL = -9

    data class Response(
        val status: Int,
        val payload: String,
        val generation: Long,
        val requestId: Long,
    ) {
        val ok: Boolean get() = status == STATUS_OK || status == STATUS_ACCEPTED
    }

    fun request(
        operation: Int,
        payload: String = "",
        deadlineMs: Int = 15_000,
    ): Response? {
        val payloadBytes = payload.toByteArray(Charsets.UTF_8)
        if (payloadBytes.size > MAX_PAYLOAD) return null
        val requestId = (Process.myPid().toLong() shl 32) xor SystemClock.elapsedRealtimeNanos()
        val header = ByteBuffer.allocate(HEADER_SIZE)
            .order(ByteOrder.nativeOrder())
            .putInt(MAGIC)
            .putShort(MAJOR)
            .putShort(MINOR)
            .putShort(HEADER_SIZE.toShort())
            .putShort(0)
            .putInt(operation)
            .putInt(0)
            .putInt(payloadBytes.size)
            .putLong(requestId)
            .putLong(0)
            .putInt(deadlineMs.coerceIn(0, 300_000))
            .putInt(0)
            .array()

        return try {
            LocalSocket().use { socket ->
                socket.connect(
                    LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.ABSTRACT),
                )
                socket.soTimeout = deadlineMs.coerceIn(1_000, 300_000)
                socket.outputStream.apply {
                    write(header)
                    write(payloadBytes)
                    flush()
                }
                socket.shutdownOutput()

                val responseHeaderBytes = socket.inputStream.readExactly(HEADER_SIZE)
                val responseHeader = ByteBuffer.wrap(responseHeaderBytes)
                    .order(ByteOrder.nativeOrder())
                val magic = responseHeader.int
                val major = responseHeader.short
                responseHeader.short // minor
                val headerSize = responseHeader.short.toInt() and 0xffff
                val flags = responseHeader.short.toInt() and 0xffff
                responseHeader.int // echoed operation
                val status = responseHeader.int
                val responseSize = responseHeader.int
                val echoedRequestId = responseHeader.long
                val generation = responseHeader.long
                responseHeader.int // deadline
                responseHeader.int // reserved
                if (
                    magic != MAGIC || major != MAJOR || headerSize != HEADER_SIZE ||
                    flags and 1 == 0 || responseSize !in 0..MAX_PAYLOAD ||
                    echoedRequestId != requestId
                ) return null
                val responsePayload = socket.inputStream.readExactly(responseSize)
                    .toString(Charsets.UTF_8)
                Response(status, responsePayload, generation, requestId)
            }
        } catch (_: Exception) {
            null // Old/inactive module: caller uses the proven su fallback.
        }
    }

    fun mode(target: String): Response? =
        if (target == "phone" || target == "desktop") {
            request(OP_MODE_SET, target, 180_000)
        } else {
            null
        }

    private fun java.io.InputStream.readExactly(size: Int): ByteArray {
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = read(result, offset, size - offset)
            if (count <= 0) throw java.io.EOFException("control bridge closed early")
            offset += count
        }
        return result
    }
}
