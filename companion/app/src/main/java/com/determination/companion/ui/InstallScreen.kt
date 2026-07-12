package com.determination.companion.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Android
import androidx.compose.material.icons.rounded.Archive
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.determination.companion.BuildConfig
import com.determination.companion.DetViewModel
import com.determination.companion.RootState

@Composable
fun InstallScreen(vm: DetViewModel, wide: Boolean, modifier: Modifier = Modifier) {
    var confirmFlash by remember { mutableStateOf<String?>(null) }
    var confirmFlashArmed by remember { mutableStateOf(false) }
    val inv = vm.inventory
    val busy = vm.busy != null
    val rootOk = vm.rootState == RootState.GRANTED

    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        SectionLabel("This device")
        if (wide) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Column(Modifier.weight(1f)) { InventoryCard(inv) }
                Column(Modifier.weight(1f)) { ArtifactsSection(vm, rootOk, busy) { confirmFlash = it } }
            }
        } else {
            InventoryCard(inv)
            ArtifactsSection(vm, rootOk, busy) { confirmFlash = it }
        }
    }

    confirmFlash?.let { path ->
        AlertDialog(
            onDismissRequest = { confirmFlash = null; confirmFlashArmed = false },
            icon = { Icon(Icons.Rounded.Warning, null, tint = MaterialTheme.colorScheme.error) },
            title = { Text(if (confirmFlashArmed) "Really flash boot?" else "Flash boot image?") },
            text = {
                Text(
                    if (!confirmFlashArmed)
                        "This writes\n$path\nto the active boot partition. A bad image can " +
                            "brick the phone until a fastboot restore. The image header is " +
                            "verified (ANDROID! magic) before writing."
                    else
                        "Second confirmation. Keep the USB cable handy for fastboot recovery. " +
                            "Flash ${path.substringAfterLast('/')} to boot${inv["slot"] ?: ""} now?",
                )
            },
            confirmButton = {
                Button(
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError,
                    ),
                    onClick = {
                        if (!confirmFlashArmed) confirmFlashArmed = true
                        else {
                            vm.flashBoot(path)
                            confirmFlash = null
                            confirmFlashArmed = false
                        }
                    },
                ) { Text(if (confirmFlashArmed) "Flash now" else "Continue") }
            },
            dismissButton = {
                TextButton(onClick = { confirmFlash = null; confirmFlashArmed = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun InventoryCard(inv: Map<String, String>) {
    GlassCard {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            InventoryRow(
                Icons.Rounded.Memory, "Kernel",
                inv["kernel"] ?: "?",
                ok = inv["det_kernel"] == "yes",
                okText = "Determination kernel", badText = "stock kernel — flash needed",
            )
            InventoryRow(
                Icons.Rounded.Archive, "Magisk module",
                inv["module_ver"]?.takeIf { it.isNotBlank() }
                    ?.let { "$it (${inv["module_code"] ?: "?"})" } ?: "not installed",
                ok = !inv["module_ver"].isNullOrBlank() && inv["module_state"] != "disabled",
                okText = "enabled", badText = if (inv["module_state"] == "disabled") "disabled" else "missing",
            )
            InventoryRow(
                Icons.Rounded.Storage, "Guest rootfs",
                inv["guest"]?.takeIf { it.isNotBlank() }?.let { "Debian $it" } ?: "not found",
                ok = !inv["guest"].isNullOrBlank(),
                okText = "present", badText = "missing",
            )
            InventoryRow(
                Icons.Rounded.Android, "Companion app",
                "v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                ok = true, okText = "this app", badText = "",
            )
            val slot = inv["slot"]
            if (!slot.isNullOrBlank()) {
                Text(
                    "Active slot $slot  ·  ${inv["boot_part"] ?: ""}",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun InventoryRow(
    icon: ImageVector,
    title: String,
    value: String,
    ok: Boolean,
    okText: String,
    badText: String,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(
                value,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            if (ok) Icons.Rounded.CheckCircle else Icons.Rounded.ErrorOutline,
            if (ok) okText else badText,
            Modifier.size(20.dp),
            tint = if (ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
        )
    }
}

@Composable
private fun ArtifactsSection(
    vm: DetViewModel,
    rootOk: Boolean,
    busy: Boolean,
    onFlash: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionLabel("Updates found on device")
        Text(
            "Drop artifacts into Download or /data/local/tmp: module zips " +
                "(determination-magisk-*.zip), boot images (*.img), or a companion APK. " +
                "Note: /sdcard is unreachable while in desktop mode — stage from phone mode.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (vm.artifacts.isEmpty()) {
            GlassCard {
                Text(
                    "Nothing found.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(20.dp),
                )
            }
        }
        vm.artifacts.forEach { path ->
            val name = path.substringAfterLast('/')
            GlassCard {
                Row(
                    Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(name, style = MaterialTheme.typography.titleSmall)
                        Text(
                            path.substringBeforeLast('/'),
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    when {
                        name.endsWith(".zip") -> FilledTonalButton(
                            enabled = rootOk && !busy,
                            onClick = { vm.installModule(path) },
                        ) { Text("Install") }
                        name.endsWith(".img") -> FilledTonalButton(
                            enabled = rootOk && !busy,
                            colors = ButtonDefaults.filledTonalButtonColors(
                                containerColor = MaterialTheme.colorScheme.errorContainer,
                                contentColor = MaterialTheme.colorScheme.onErrorContainer,
                            ),
                            onClick = { onFlash(path) },
                        ) { Text("Flash") }
                        name.endsWith(".apk") -> FilledTonalButton(
                            enabled = rootOk && !busy,
                            onClick = { vm.installApk(path) },
                        ) { Text("Update") }
                    }
                }
            }
        }
    }
}
