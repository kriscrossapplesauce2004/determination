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
import androidx.compose.material.icons.rounded.Block
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.determination.companion.CATALOG
import com.determination.companion.COMPOSITORS
import com.determination.companion.CompositorStatus
import com.determination.companion.DetViewModel
import com.determination.companion.RootState

@Composable
fun SoftwareScreen(vm: DetViewModel, wide: Boolean, modifier: Modifier = Modifier) {
    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (!vm.guestUp) {
            GlassCard {
                Text(
                    "Guest container is not running — package status and installs need it up. " +
                        "Start it from the Control tab.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(20.dp),
                )
            }
        }

        if (wide) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    CompositorSection(vm)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    CatalogSection(vm)
                }
            }
        } else {
            CompositorSection(vm)
            CatalogSection(vm)
        }
    }
}

@Composable
private fun CompositorSection(vm: DetViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionLabel("Session · compositor")
        COMPOSITORS.forEach { c ->
            val selected = vm.compositor == c.id
            val incompatible = c.status == CompositorStatus.INCOMPATIBLE
            GlassCard {
                Row(
                    Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(
                        selected = selected,
                        onClick = { if (!incompatible) vm.selectCompositor(c.id) },
                        enabled = !incompatible && vm.rootState == RootState.GRANTED,
                    )
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(c.title, style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.width(8.dp))
                            when (c.status) {
                                CompositorStatus.ACTIVE -> Icon(
                                    Icons.Rounded.CheckCircle, "verified",
                                    Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                                CompositorStatus.EXPERIMENTAL -> Icon(
                                    Icons.Rounded.Science, "experimental",
                                    Modifier.size(16.dp), tint = MaterialTheme.colorScheme.tertiary)
                                CompositorStatus.INCOMPATIBLE -> Icon(
                                    Icons.Rounded.Block, "incompatible",
                                    Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
                            }
                        }
                        Text(
                            c.blurb,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        val pkg = c.aptPkg
                        if (pkg != null && vm.guestUp && vm.pkgStatus[pkg] != "installed") {
                            InstallButton(vm, pkg, label = "Install ${c.title}")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CatalogSection(vm: DetViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        CATALOG.groupBy { it.category }.forEach { (category, apps) ->
            SectionLabel(category)
            GlassCard {
                Column(Modifier.padding(vertical = 6.dp)) {
                    apps.forEach { app ->
                        val installed = vm.pkgStatus[app.pkg] == "installed"
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(app.title, style = MaterialTheme.typography.titleSmall)
                                Text(
                                    "${app.blurb} · ${app.pkg}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            when {
                                !vm.guestUp -> Text(
                                    "—",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                installed -> OutlinedButton(
                                    enabled = vm.installingPkg == null,
                                    onClick = { vm.removePkg(app.pkg) },
                                ) { Text("Remove") }
                                else -> InstallButton(vm, app.pkg)
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun InstallButton(vm: DetViewModel, pkg: String, label: String = "Install") {
    val installingThis = vm.installingPkg == pkg
    FilledTonalButton(
        enabled = vm.installingPkg == null && vm.rootState == RootState.GRANTED,
        onClick = { vm.installPkg(pkg) },
    ) {
        if (installingThis) {
            LoadingIndicator(Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(if (installingThis) "Installing…" else label)
    }
}
