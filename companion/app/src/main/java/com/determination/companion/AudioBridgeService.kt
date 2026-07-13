package com.determination.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Determination guest-audio bridge.
 *
 * Android 16 moved AudioFlinger/AAudio native services into system_server's
 * AIDL `audio` service; a native binary in the shell/`magisk` SELinux context
 * can no longer reach them (getService for IAudioFlinger returns null even
 * with sepolicy grants, because service_manager doesn't publish them anymore).
 * Native Android audio still works from ordinary app contexts, so the bridge
 * has to run inside an app — this one. AudioTrack from `untrusted_app` reaches
 * the framework audio service the same way any music app does, so we inherit
 * volume-key handling, ringtone ducking, and DP-audio routing for free.
 *
 * Wire format: raw interleaved PCM, s16le, 48000 Hz, 2ch, big-endian frames
 * of FRAME_BYTES bytes. The service listens on the veth-facing address the
 * guest already routes to (192.168.117.1:4713) — no ADB/Wi-Fi involvement.
 * The guest's PulseAudio is configured with a matching module-simple-protocol-tcp
 * client sink pointing at this port.
 */
class AudioBridgeService : Service() {

    companion object {
        const val EXTRA_FROM_BOOT = "from-boot"
        private const val TAG = "DetAudioBridge"
        private const val NOTIF_CHAN = "det-audio-bridge"
        private const val NOTIF_ID = 0x0DE7
        private const val LISTEN_HOST = "192.168.117.1"
        private const val LISTEN_PORT = 4713
        private const val RATE = 48000
        private const val CHANS = 2
        // 40ms chunks — matches det-audiobridge (deprecated) and the guest PA
        // module chunking; large enough for battery, small enough for keys.
        private const val FRAMES_PER_CHUNK = 1920
        private const val FRAME_BYTES = FRAMES_PER_CHUNK * CHANS * 2
    }

    private val running = AtomicBoolean(false)
    private var acceptor: Thread? = null
    private var server: ServerSocket? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val fromBoot = intent?.getBooleanExtra(EXTRA_FROM_BOOT, false) == true
        try {
            startForeground(NOTIF_ID, buildNotification(), foregroundType(fromBoot))
        } catch (e: Exception) {
            // Never crashloop over FGS-type policy (Android 15+ restricts what
            // can start from BOOT_COMPLETED); run demoted-to-background instead.
            Log.w(TAG, "startForeground denied, running in background: ${e.message}")
        }
        if (running.compareAndSet(false, true)) {
            acceptor = thread(name = "det-audio-acceptor", isDaemon = true) { acceptLoop() }
        }
        // START_STICKY: if killed for memory, come back on its own — the guest
        // reconnects opportunistically, so a restart is transparent.
        return START_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        try { server?.close() } catch (_: Exception) {}
        acceptor?.interrupt()
        super.onDestroy()
    }

    private fun acceptLoop() {
        while (running.get()) {
            try {
                val s = ServerSocket()
                s.reuseAddress = true
                s.bind(InetSocketAddress(LISTEN_HOST, LISTEN_PORT))
                server = s
                Log.i(TAG, "listening on $LISTEN_HOST:$LISTEN_PORT")
                while (running.get()) {
                    val client = s.accept()
                    // One playback per connection: dedicated AudioTrack so a
                    // dropped guest doesn't stall the bind, and reconnects
                    // start clean without leftover jitter buffer.
                    thread(name = "det-audio-play", isDaemon = true) {
                        try { playFrom(client) } catch (t: Throwable) {
                            Log.w(TAG, "play thread died: ${t.message}")
                        }
                    }
                }
            } catch (t: Throwable) {
                if (!running.get()) return
                Log.w(TAG, "accept loop error, retry in 2s: ${t.message}")
                try { Thread.sleep(2000) } catch (_: InterruptedException) { return }
            }
        }
    }

    private fun playFrom(client: Socket) {
        client.use { sock ->
            Log.i(TAG, "connection from ${sock.remoteSocketAddress}")
            val minBuf = AudioTrack.getMinBufferSize(
                RATE,
                AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            val bufBytes = maxOf(minBuf, FRAME_BYTES * 4)

            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            try {
                track.play()
                val buf = ByteArray(FRAME_BYTES)
                val ins = sock.getInputStream()
                while (running.get()) {
                    var read = 0
                    while (read < buf.size) {
                        val n = ins.read(buf, read, buf.size - read)
                        if (n <= 0) return
                        read += n
                    }
                    // Blocking write; back-pressure the guest naturally when
                    // the ring buffer fills. WRITE_BLOCKING is default in
                    // MODE_STREAM but state it for readers.
                    track.write(buf, 0, buf.size, AudioTrack.WRITE_BLOCKING)
                }
            } finally {
                try { track.stop() } catch (_: Exception) {}
                track.release()
                Log.i(TAG, "playback ended for ${sock.remoteSocketAddress}")
            }
        }
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(NOTIF_CHAN) != null) return
        val ch = NotificationChannel(
            NOTIF_CHAN,
            "Determination guest audio",
            NotificationManager.IMPORTANCE_MIN
        ).apply { setShowBadge(false) }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, NOTIF_CHAN)
            .setContentTitle(getString(R.string.audio_bridge_notif))
            .setSmallIcon(R.drawable.ic_desktop)
            .setOngoing(true)
            .build()

    // Android 14+ requires a service-type. mediaPlayback is banned when the
    // start comes from BOOT_COMPLETED (15+), so boot uses connectedDevice.
    private fun foregroundType(fromBoot: Boolean): Int = when {
        Build.VERSION.SDK_INT < 34 -> 0
        fromBoot -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    }
}
