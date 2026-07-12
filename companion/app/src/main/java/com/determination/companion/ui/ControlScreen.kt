package com.determination.companion.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Article
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Healing
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Smartphone
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.determination.companion.DetViewModel
import com.determination.companion.RootState

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ControlScreen(vm: DetViewModel, wide: Boolean, modifier: Modifier = Modifier) {
    var confirmEnter by remember { mutableStateOf(false) }
    var confirmPower by remember { mutableStateOf<String?>(null) }

    val s = vm.status
    val desktop = s["mode"] == "desktop"
    val installed = s["installed"] == "yes"
    val rootOk = vm.rootState == RootState.GRANTED
    val busy = vm.busy != null

    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        RootChip(vm.rootState)

        if (vm.rootState == RootState.DENIED) {
            GlassCard {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Root required", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "This app drives Determination through Magisk su. Open Magisk → " +
                            "Superuser and grant Determination (screen must be unlocked), then retry.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    FilledTonalButton(onClick = { vm.refresh() }) { Text("Retry") }
                }
            }
            return@Column
        }

        if (wide) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Column(Modifier.weight(1f)) { StatusCard(vm, desktop) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Actions(vm, desktop, installed, rootOk, busy,
                        onEnter = { confirmEnter = true }, onPower = { confirmPower = it })
                }
            }
        } else {
            StatusCard(vm, desktop)
            Actions(vm, desktop, installed, rootOk, busy,
                onEnter = { confirmEnter = true }, onPower = { confirmPower = it })
        }

        SectionLabel("Diagnostics")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            vm.logs.take(if (wide) 4 else 2).forEach { LogChip(it, vm) }
        }
        if (!wide) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            vm.logs.drop(2).forEach { LogChip(it, vm) }
        }
    }

    if (confirmEnter) {
        AlertDialog(
            onDismissRequest = { confirmEnter = false },
            title = { Text("Enter desktop mode?") },
            text = {
                Text(
                    "The phone UI hands the panel to the Linux desktop. To come back, use " +
                        "“Exit to Phone Mode” inside the desktop, or the power menu.",
                )
            },
            confirmButton = {
                Button(onClick = {
                    confirmEnter = false
                    vm.act("enter", refreshAfter = false) { com.determination.companion.Root.enterDesktop() }
                }) { Text("Enter") }
            },
            dismissButton = { TextButton(onClick = { confirmEnter = false }) { Text("Cancel") } },
        )
    }

    confirmPower?.let { which ->
        AlertDialog(
            onDismissRequest = { confirmPower = null },
            icon = { Icon(Icons.Rounded.Warning, null) },
            title = { Text(if (which == "reboot") "Reboot the phone?" else "Power off the phone?") },
            text = { Text("This affects the whole phone, not just the Linux guest.") },
            confirmButton = {
                Button(
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError,
                    ),
                    onClick = {
                        confirmPower = null
                        vm.act("power", refreshAfter = false) {
                            if (which == "reboot") com.determination.companion.Root.rebootPhone()
                            else com.determination.companion.Root.powerOff()
                        }
                    },
                ) { Text(if (which == "reboot") "Reboot" else "Power off") }
            },
            dismissButton = { TextButton(onClick = { confirmPower = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun RootChip(state: RootState) {
    val (label, icon) = when (state) {
        RootState.CHECKING -> "Checking root…" to Icons.Rounded.Bolt
        RootState.GRANTED -> "Root granted · Magisk" to Icons.Rounded.VerifiedUser
        RootState.DENIED -> "Root not granted" to Icons.Rounded.Warning
    }
    AssistChip(onClick = {}, label = { Text(label) },
        leadingIcon = { Icon(icon, null, Modifier.size(18.dp)) })
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun StatusCard(vm: DetViewModel, desktop: Boolean) {
    val s = vm.status
    GlassCard {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (desktop) Icons.Rounded.DesktopWindows else Icons.Rounded.Smartphone,
                    null,
                    Modifier.size(32.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        if (desktop) "Desktop mode" else "Phone mode",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        if (s["installed"] == "yes") "Determination installed"
                        else "Not installed — see the Install tab",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            StatusRow("Guest", (s["guest"] ?: "?") +
                (s["ip"]?.takeIf { it.isNotBlank() }?.let { "  ·  $it" } ?: ""))
            StatusRow("SurfaceFlinger", s["sf"] ?: "?")
            StatusRow("Host agent", s["agent"] ?: "?")
            StatusRow("Kernel", s["kernel"] ?: "?")

            val batt = s["batt"]?.toIntOrNull()
            if (batt != null) {
                Spacer(Modifier.height(2.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Battery  $batt%  ·  ${s["battmv"] ?: "?"} mV  ·  ${s["battstat"] ?: ""}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                LinearWavyProgressIndicator(
                    progress = { batt / 100f },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun StatusRow(label: String, value: String) {
    Row {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(130.dp),
        )
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun Actions(
    vm: DetViewModel,
    desktop: Boolean,
    installed: Boolean,
    rootOk: Boolean,
    busy: Boolean,
    onEnter: () -> Unit,
    onPower: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Desktop")
        if (!desktop) {
            Button(
                onClick = onEnter,
                enabled = rootOk && installed && !busy,
                modifier = Modifier.fillMaxWidth().height(56.dp),
            ) {
                Icon(Icons.Rounded.DesktopWindows, null)
                Spacer(Modifier.width(8.dp))
                Text("Enter Desktop Mode", style = MaterialTheme.typography.titleMedium)
            }
        } else {
            Button(
                onClick = { vm.act("exit") { com.determination.companion.Root.exitDesktop() } },
                enabled = rootOk && !busy,
                modifier = Modifier.fillMaxWidth().height(56.dp),
            ) {
                Icon(Icons.Rounded.Smartphone, null)
                Spacer(Modifier.width(8.dp))
                Text("Exit Desktop Mode", style = MaterialTheme.typography.titleMedium)
            }
            FilledTonalButton(
                onClick = { vm.act("recover") { com.determination.companion.Root.recoverDesktop() } },
                enabled = rootOk && !busy,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Rounded.Healing, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Recover desktop (restart phoc)")
            }
        }

        SectionLabel("Guest & power")
        FilledTonalButton(
            onClick = { vm.act("guest") { com.determination.companion.Root.restartGuest() } },
            enabled = rootOk && installed && !desktop && !busy,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Rounded.RestartAlt, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Restart guest container")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = { onPower("reboot") },
                enabled = rootOk && !busy,
                modifier = Modifier.weight(1f),
            ) {
                Icon(Icons.Rounded.RestartAlt, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Reboot")
            }
            OutlinedButton(
                onClick = { onPower("poweroff") },
                enabled = rootOk && !busy,
                modifier = Modifier.weight(1f),
            ) {
                Icon(Icons.Rounded.PowerSettingsNew, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Power off")
            }
        }
    }
}

@Composable
private fun LogChip(name: String, vm: DetViewModel) {
    AssistChip(
        onClick = { vm.openLog(name) },
        label = { Text(name.removeSuffix(".log")) },
        leadingIcon = { Icon(Icons.AutoMirrored.Rounded.Article, null, Modifier.size(16.dp)) },
    )
}

@Composable
fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary,
        letterSpacing = MaterialTheme.typography.labelMedium.letterSpacing * 2,
        modifier = Modifier.padding(top = 10.dp, bottom = 2.dp),
    )
}

@Composable
fun GlassCard(content: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = glassColor()),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) { content() }
}
