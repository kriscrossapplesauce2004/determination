package com.determination.companion.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.determination.companion.DetViewModel
import com.determination.companion.RootState

/** Poll choices: label → seconds (0 = manual refresh only). */
private val POLL_CHOICES = listOf("5 s" to 5, "15 s" to 15, "60 s" to 60, "Off" to 0)

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SettingsScreen(
    vm: DetViewModel,
    modifier: Modifier = Modifier,
    bottomPad: Dp = 0.dp,
) {
    val rootOk = vm.rootState == RootState.GRANTED
    val guestRunning = vm.status["guest"] == "running"

    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp + bottomPad),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // (dog check: 20 pets and the battery section briefly smells of chips)
        var pets by remember { mutableIntStateOf(0) }
        Text(
            "BATTERY SAVER",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.primary,
            letterSpacing = MaterialTheme.typography.labelMedium.letterSpacing * 2,
            modifier = Modifier
                .padding(top = 10.dp, bottom = 2.dp)
                .combinedClickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {
                        if (++pets == 20) {
                            pets = 0
                            vm.message = "* (You pet the battery. It was not a dog.)"
                        }
                    },
                ),
        )

        GlassCard {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                SettingRow(
                    title = "Stop guest when leaving desktop",
                    blurb = "desktop-off also shuts the Linux container down, so it stops " +
                        "burning CPU wakeups and RAM while you're in phone mode. Entering " +
                        "desktop mode restarts it (a few seconds slower).",
                    checked = vm.stopGuestOnExit,
                    enabled = rootOk,
                    onChange = { vm.updateStopGuestOnExit(it) },
                )
                SettingRow(
                    title = "Guest audio bridge at boot",
                    blurb = "Keeps a PCM listener + notification alive from boot. Turn off " +
                        "if you don't use guest audio — the bridge (and its wakelock-ish " +
                        "socket loop) then only runs after you open this app's toggle again.",
                    checked = vm.audioBridgeAtBoot,
                    enabled = true,
                    onChange = { vm.updateAudioBridgeAtBoot(it) },
                )

                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Status poll while app is open", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "Each poll is a root round-trip that briefly wakes the CPU. " +
                            "Slower or off = less battery; pull-to-refresh always works.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        POLL_CHOICES.forEach { (label, secs) ->
                            FilterChip(
                                selected = vm.pollSeconds == secs,
                                onClick = { vm.updatePollSeconds(secs) },
                                label = { Text(label) },
                            )
                        }
                    }
                }

                OutlinedButton(
                    onClick = { vm.stopGuestNow() },
                    enabled = rootOk && guestRunning && vm.busy == null,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Rounded.PowerSettingsNew, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (guestRunning) "Stop guest container now" else "Guest already stopped")
                }
            }
        }

        Text(
            "The guest itself is the big battery item: stopped, Determination costs " +
                "roughly nothing beyond the flashed kernel. Everything here only " +
                "matters while the container or bridge is running.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun SettingRow(
    title: String,
    blurb: String,
    checked: Boolean,
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(
                blurb,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}
