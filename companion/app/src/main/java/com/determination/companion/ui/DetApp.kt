package com.determination.companion.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material.icons.outlined.SystemUpdateAlt
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Smartphone
import androidx.compose.material.icons.rounded.SystemUpdateAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.windowsizeclass.WindowHeightSizeClass
import androidx.compose.material3.windowsizeclass.WindowSizeClass
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.determination.companion.DetViewModel
import com.determination.companion.R
import com.determination.companion.Root
import com.determination.companion.RootState

enum class Dest(
    val label: String,
    val icon: ImageVector,
    val activeIcon: ImageVector,
    val headline: String,
    val tagline: String,
) {
    Control(
        "Control", Icons.Outlined.Smartphone, Icons.Rounded.Smartphone,
        "Determination", "Android ↔ Linux convergence",
    ),
    Install(
        "Install", Icons.Outlined.SystemUpdateAlt, Icons.Rounded.SystemUpdateAlt,
        "Install & update", "Kernel · module · guest",
    ),
    Software(
        "Software", Icons.Outlined.Apps, Icons.Rounded.Apps,
        "Software", "Compositors & guest apps",
    ),
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DetApp(vm: DetViewModel, windowSize: WindowSizeClass) {
    var dest by rememberSaveable { mutableStateOf(Dest.Control) }
    val snackbar = remember { SnackbarHostState() }
    val compact = windowSize.widthSizeClass == WindowWidthSizeClass.Compact
    val expanded = windowSize.widthSizeClass == WindowWidthSizeClass.Expanded
    // Landscape phone: barely any height — swap the large collapsing bar for a
    // pinned small one so content gets the room.
    val shortScreen = windowSize.heightSizeClass == WindowHeightSizeClass.Compact

    LaunchedEffect(vm.message) {
        vm.message?.let { snackbar.showSnackbar(it); vm.message = null }
    }
    LaunchedEffect(dest, vm.rootState) {
        if (vm.rootState != RootState.GRANTED) return@LaunchedEffect
        when (dest) {
            Dest.Control -> vm.refresh()
            Dest.Install -> vm.refreshInstaller()
            Dest.Software -> vm.refreshSoftware()
        }
    }

    AuroraBackground {
        Row(Modifier.fillMaxSize()) {
            if (!compact) {
                NavigationRail(containerColor = Color.Transparent) {
                    Box(Modifier.size(8.dp))
                    Dest.entries.forEach { d ->
                        NavigationRailItem(
                            selected = dest == d,
                            onClick = { dest = d },
                            icon = { Icon(if (dest == d) d.activeIcon else d.icon, d.label) },
                            label = { Text(d.label) },
                        )
                    }
                }
            }
            val scroll =
                if (shortScreen) TopAppBarDefaults.pinnedScrollBehavior()
                else TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
            val barTitle: @Composable () -> Unit = {
                Column {
                    Text(dest.headline)
                    if (!shortScreen) Text(
                        dest.tagline,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            val barNav: @Composable () -> Unit = {
                Image(
                    painterResource(R.drawable.ic_soul),
                    contentDescription = null,
                    modifier = Modifier.padding(horizontal = 12.dp).size(28.dp),
                )
            }
            val refreshCurrent = {
                when (dest) {
                    Dest.Control -> vm.refresh()
                    Dest.Install -> vm.refreshInstaller()
                    Dest.Software -> vm.refreshSoftware()
                }
            }
            // On compact the refresh affordance lives in the floating bubble
            // next to the nav pill; elsewhere it stays in the top bar.
            val barActions: @Composable RowScope.() -> Unit = {
                if (!compact) {
                    if (vm.busy != null) {
                        LoadingIndicator(Modifier.size(40.dp))
                    } else {
                        IconButton(onClick = refreshCurrent) { Icon(Icons.Rounded.Refresh, "Refresh") }
                    }
                }
            }
            val barColors = TopAppBarDefaults.topAppBarColors(
                containerColor = Color.Transparent,
                scrolledContainerColor =
                    MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.88f),
            )
            Scaffold(
                modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
                containerColor = Color.Transparent,
                topBar = {
                    if (shortScreen) {
                        TopAppBar(
                            title = barTitle, navigationIcon = barNav, actions = barActions,
                            colors = barColors, scrollBehavior = scroll,
                        )
                    } else {
                        LargeTopAppBar(
                            title = barTitle, navigationIcon = barNav, actions = barActions,
                            colors = barColors, scrollBehavior = scroll,
                        )
                    }
                },
                snackbarHost = {
                    SnackbarHost(
                        snackbar,
                        Modifier.padding(bottom = if (compact) 84.dp else 0.dp),
                    )
                },
            ) { pad ->
                Box(Modifier.fillMaxSize().padding(pad)) {
                    AnimatedContent(
                        targetState = dest,
                        transitionSpec = {
                            (fadeIn() + slideInVertically { it / 12 })
                                .togetherWith(fadeOut() + slideOutVertically { -it / 16 })
                        },
                        label = "screen",
                    ) { d ->
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                            val content = Modifier.widthIn(
                                max = when {
                                    expanded -> 1080.dp
                                    !compact -> 760.dp
                                    else -> 640.dp
                                },
                            )
                            // Content scrolls UNDER the floating pill; screens
                            // add this much extra end-of-scroll padding.
                            val bottomPad = if (compact) 84.dp else 0.dp
                            when (d) {
                                Dest.Control -> ControlScreen(vm, expanded, content, bottomPad)
                                Dest.Install -> InstallScreen(vm, expanded, content, bottomPad)
                                Dest.Software -> SoftwareScreen(vm, expanded, content, bottomPad)
                            }
                        }
                    }
                    if (compact) {
                        FloatingNav(
                            dest = dest,
                            onSelect = { dest = it },
                            busy = vm.busy != null,
                            onRefresh = refreshCurrent,
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .padding(bottom = 14.dp),
                        )
                    }
                }
            }
        }
    }

    // Log viewer sheet (shared by every screen).
    LogSheetAndDialogs(vm)
}

/**
 * Floating pill navigation (the Google-Photos look): a translucent glass pill
 * hovering over the content with the selected destination highlighted as a
 * chip, plus a round refresh bubble beside it that doubles as the busy
 * indicator on compact screens.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun FloatingNav(
    dest: Dest,
    onSelect: (Dest) -> Unit,
    busy: Boolean,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val glass = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.82f)
    val stroke = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f))
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Surface(
            shape = CircleShape,
            color = glass,
            contentColor = MaterialTheme.colorScheme.onSurface,
            border = stroke,
            shadowElevation = 6.dp,
        ) {
            Row(
                Modifier.padding(6.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Dest.entries.forEach { d ->
                    val selected = d == dest
                    Surface(
                        onClick = { onSelect(d) },
                        shape = CircleShape,
                        color = if (selected) MaterialTheme.colorScheme.secondaryContainer
                        else Color.Transparent,
                        contentColor = if (selected) MaterialTheme.colorScheme.onSecondaryContainer
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    ) {
                        Row(
                            Modifier
                                .animateContentSize()
                                .padding(horizontal = 16.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            if (selected) Icon(d.activeIcon, null, Modifier.size(18.dp))
                            Text(
                                d.label,
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        }
                    }
                }
            }
        }
        Surface(
            onClick = onRefresh,
            shape = CircleShape,
            color = glass,
            contentColor = MaterialTheme.colorScheme.onSurface,
            border = stroke,
            shadowElevation = 6.dp,
        ) {
            Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
                if (busy) LoadingIndicator(Modifier.size(28.dp))
                else Icon(Icons.Rounded.Refresh, "Refresh", Modifier.size(22.dp))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun LogSheetAndDialogs(vm: DetViewModel) {
    if (vm.logName != null) {
        val clipboard = LocalClipboardManager.current
        ModalBottomSheet(
            onDismissRequest = { vm.closeLog() },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) {
            Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        vm.logName ?: "",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = {
                        vm.logText?.let { clipboard.setText(AnnotatedString(it)) }
                    }) { Icon(Icons.Rounded.ContentCopy, "Copy") }
                    IconButton(onClick = { vm.openLog(vm.logName ?: return@IconButton) }) {
                        Icon(Icons.Rounded.Refresh, "Reload")
                    }
                }
                Box(Modifier.size(8.dp))
                val text = vm.logText
                if (text == null) {
                    Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                        LoadingIndicator()
                    }
                } else {
                    Text(
                        text,
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                        softWrap = false,
                        modifier = Modifier
                            .verticalScroll(rememberScrollState())
                            .horizontalScroll(rememberScrollState())
                            .fillMaxWidth(),
                    )
                }
            }
        }
    }

    // "Reboot to apply" prompt after a successful module install / boot flash.
    vm.rebootPrompt?.let { why ->
        AlertDialog(
            onDismissRequest = { vm.rebootPrompt = null },
            icon = { Icon(Icons.Rounded.RestartAlt, null) },
            title = { Text("Reboot to apply?") },
            text = { Text(why) },
            confirmButton = {
                Button(onClick = {
                    vm.rebootPrompt = null
                    vm.act("power", refreshAfter = false) { Root.rebootPhone() }
                }) { Text("Reboot now") }
            },
            dismissButton = {
                TextButton(onClick = { vm.rebootPrompt = null }) { Text("Later") }
            },
        )
    }
}
