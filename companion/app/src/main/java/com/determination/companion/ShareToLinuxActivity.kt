package com.determination.companion

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.concurrent.thread

/** Android share-sheet bridge into the Linux guest's Downloads directory. */
class ShareToLinuxActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.action != Intent.ACTION_SEND) {
            finish()
            return
        }
        Toast.makeText(this, R.string.share_working, Toast.LENGTH_SHORT).show()
        thread(name = "det-share-to-linux", isDaemon = true) {
            val result = runCatching { stageIncoming(intent) }
                .fold(
                    onSuccess = { staged ->
                        try { Root.importToGuest(staged.absolutePath, staged.name) }
                        finally { staged.delete() }
                    },
                    onFailure = { Root.Result(false, "", it.message ?: "invalid share") },
                )
            runOnUiThread {
                val message = if (result.ok) getString(R.string.share_done)
                else getString(R.string.share_failed, result.err.ifBlank { result.out })
                Toast.makeText(this, message, Toast.LENGTH_LONG).show()
                finish()
            }
        }
    }

    private fun stageIncoming(source: Intent): File {
        val staging = File(externalCacheDir ?: cacheDir, "linux-inbox").apply { mkdirs() }
        val uri = source.streamUri()
        if (uri != null) {
            val name = safeName(displayName(uri) ?: uri.lastPathSegment ?: "Shared file")
            val target = uniqueFile(staging, name)
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "shared file could not be opened" }
                target.outputStream().use { input.copyTo(it) }
            }
            return target
        }

        val text = source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: error("share contained neither a file nor text")
        val stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH-mm-ss"))
        return uniqueFile(staging, "Shared text $stamp.txt").apply { writeText(text) }
    }

    @Suppress("DEPRECATION")
    private fun Intent.streamUri(): Uri? = getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    private fun displayName(uri: Uri): String? = contentResolver
        .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }

    private fun safeName(raw: String): String = raw
        .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
        .trim().trimStart('.')
        .take(120)
        .ifBlank { "Shared file" }

    private fun uniqueFile(dir: File, name: String): File {
        var candidate = File(dir, name)
        var n = 2
        while (candidate.exists()) {
            val dot = name.lastIndexOf('.')
            val stem = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            candidate = File(dir, "$stem ($n)$ext")
            n++
        }
        return candidate
    }
}
