package com.determination.companion.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material.icons.outlined.SystemUpdateAlt
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Smartphone
import androidx.compose.material.icons.rounded.SystemUpdateAlt
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.determination.companion.DetViewModel
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
            val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
            Scaffold(
                modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
                containerColor = Color.Transparent,
                topBar = {
                    LargeTopAppBar(
                        title = {
                            Column {
                                Text(dest.headline)
                                Text(
                                    dest.tagline,
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        },
                        actions = {
                            if (vm.busy != null) {
                                LoadingIndicator(Modifier.size(40.dp))
                            } else {
                                IconButton(onClick = {
                                    when (dest) {
                                        Dest.Control -> vm.refresh()
                                        Dest.Install -> vm.refreshInstaller()
                                        Dest.Software -> vm.refreshSoftware()
                                    }
                                }) { Icon(Icons.Rounded.Refresh, "Refresh") }
                            }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = Color.Transparent,
                            scrolledContainerColor =
                                MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.88f),
                        ),
                        scrollBehavior = scroll,
                    )
                },
                bottomBar = {
                    if (compact) {
                        NavigationBar(
                            containerColor =
                                MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.88f),
                        ) {
                            Dest.entries.forEach { d ->
                                NavigationBarItem(
                                    selected = dest == d,
                                    onClick = { dest = d },
                                    icon = { Icon(if (dest == d) d.activeIcon else d.icon, d.label) },
                                    label = { Text(d.label) },
                                )
                            }
                        }
                    }
                },
                snackbarHost = { SnackbarHost(snackbar) },
            ) { pad ->
                AnimatedContent(
                    targetState = dest,
                    transitionSpec = {
                        (fadeIn() + slideInVertically { it / 12 })
                            .togetherWith(fadeOut() + slideOutVertically { -it / 16 })
                    },
                    label = "screen",
                ) { d ->
                    Box(
                        Modifier
                            .fillMaxSize()
                            .padding(pad),
                        contentAlignment = Alignment.TopCenter,
                    ) {
                        val content = Modifier.widthIn(max = if (expanded) 1040.dp else 640.dp)
                        when (d) {
                            Dest.Control -> ControlScreen(vm, expanded, content)
                            Dest.Install -> InstallScreen(vm, expanded, content)
                            Dest.Software -> SoftwareScreen(vm, expanded, content)
                        }
                    }
                }
            }
        }
    }

    // Log viewer sheet (shared by every screen).
    if (vm.logName != null) {
        ModalBottomSheet(
            onDismissRequest = { vm.closeLog() },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) {
            Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
                Text(vm.logName ?: "", style = MaterialTheme.typography.titleMedium)
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
                        modifier = Modifier
                            .verticalScroll(rememberScrollState())
                            .fillMaxWidth(),
                    )
                }
            }
        }
    }
}
