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
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material.icons.outlined.SystemUpdateAlt
import androidx.compose.material.icons.rounded.Settings
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
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.draw.clip
import com.determination.companion.DetViewModel
import com.determination.companion.R
import com.determination.companion.Root
import com.determination.companion.RootState
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import dev.chrisbanes.haze.materials.HazeMaterials

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
    Settings(
        "Settings", Icons.Outlined.Settings, Icons.Rounded.Settings,
        "Settings", "Battery & behavior",
    ),
}

// Long-press the refresh bubble. Nobody long-presses a refresh button.
private val EGG_QUOTES = listOf(
    "* (You feel your sins crawling on your back.)",
    "* [[Hyperlink blocked.]]",
    "* You're going to have a good time.",
    "* (The refresh bubble refuses to elaborate.)",
    "* THE POWER OF FLUFFY BOYS SHINES WITHIN YOU.",
    "* (It's a phone. It fills you with determination.)",
)

@OptIn(
    ExperimentalMaterial3Api::class,
    ExperimentalMaterial3ExpressiveApi::class,
    ExperimentalHazeMaterialsApi::class,
)
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
            Dest.Settings -> vm.refresh()
        }
    }

    val hazeState = rememberHazeState()

    AuroraBackground {
        Row(Modifier.fillMaxSize()) {
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
            // (7 quick taps on the soul — the number of human souls.)
            var soulTaps by remember { mutableStateOf(0) }
            var soulLast by remember { mutableStateOf(0L) }
            val barNav: @Composable () -> Unit = {
                Image(
                    painterResource(R.drawable.ic_soul),
                    contentDescription = null,
                    modifier = Modifier
                        .padding(horizontal = 12.dp)
                        .size(28.dp)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) {
                            val now = System.currentTimeMillis()
                            soulTaps = if (now - soulLast < 1500) soulTaps + 1 else 1
                            soulLast = now
                            if (soulTaps >= 7) {
                                soulTaps = 0
                                vm.message = "* Despite everything, it's still you."
                            }
                        },
                )
            }
            val refreshCurrent = {
                when (dest) {
                    Dest.Control -> vm.refresh()
                    Dest.Install -> vm.refreshInstaller()
                    Dest.Software -> vm.refreshSoftware()
                    Dest.Settings -> vm.refresh()
                }
            }
            // Refresh lives in the floating bubble on every size class; the
            // top bar stays clean and frosts (haze) over passing content.
            val barColors = TopAppBarDefaults.topAppBarColors(
                containerColor = Color.Transparent,
                scrolledContainerColor = Color.Transparent,
            )
            // Slightly gentler frost than the material default (24dp).
            val barModifier = Modifier.hazeEffect(hazeState, HazeMaterials.ultraThin()) {
                blurRadius = 14.dp
            }
            Scaffold(
                modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
                containerColor = Color.Transparent,
                topBar = {
                    if (shortScreen) {
                        TopAppBar(
                            title = barTitle, navigationIcon = barNav,
                            colors = barColors, scrollBehavior = scroll,
                            modifier = barModifier,
                        )
                    } else {
                        LargeTopAppBar(
                            title = barTitle, navigationIcon = barNav,
                            colors = barColors, scrollBehavior = scroll,
                            modifier = barModifier,
                        )
                    }
                },
                snackbarHost = {
                    SnackbarHost(snackbar, Modifier.padding(bottom = 84.dp))
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
                        modifier = Modifier.fillMaxSize().hazeSource(hazeState),
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
                            val bottomPad = 84.dp
                            when (d) {
                                Dest.Control -> ControlScreen(vm, expanded, content, bottomPad)
                                Dest.Install -> InstallScreen(vm, expanded, content, bottomPad)
                                Dest.Software -> SoftwareScreen(vm, expanded, content, bottomPad)
                                Dest.Settings -> SettingsScreen(vm, content, bottomPad)
                            }
                        }
                    }
                    FloatingNav(
                        dest = dest,
                        onSelect = { dest = it },
                        busy = vm.busy != null,
                        onRefresh = refreshCurrent,
                        onRefreshLongPress = { vm.message = EGG_QUOTES.random() },
                        wide = !compact,
                        hazeState = hazeState,
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 14.dp),
                    )
                }
            }
        }
    }

    // Log viewer sheet (shared by every screen).
    LogSheetAndDialogs(vm)
}

/**
 * Floating pill navigation (the Google-Photos look) on every size class: a
 * frosted-glass pill hovering over the content — real backdrop blur via haze —
 * with the selected destination highlighted as a chip, plus a round refresh
 * bubble beside it that doubles as the busy indicator. On wide screens the
 * pill expands: every destination shows its icon and items breathe more.
 */
@OptIn(
    ExperimentalMaterial3ExpressiveApi::class,
    ExperimentalHazeMaterialsApi::class,
    ExperimentalFoundationApi::class,
)
@Composable
private fun FloatingNav(
    dest: Dest,
    onSelect: (Dest) -> Unit,
    busy: Boolean,
    onRefresh: () -> Unit,
    onRefreshLongPress: () -> Unit,
    wide: Boolean,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val stroke = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f))
    val frost = HazeMaterials.thin(MaterialTheme.colorScheme.surfaceContainerHigh)
    val itemPadH = if (wide) 20.dp else 16.dp
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Surface(
            shape = CircleShape,
            color = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onSurface,
            border = stroke,
            shadowElevation = 6.dp,
        ) {
            Row(
                Modifier
                    .clip(CircleShape)
                    .hazeEffect(hazeState, frost) { blurRadius = 14.dp }
                    .padding(6.dp),
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
                                .padding(horizontal = itemPadH, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            if (selected || wide) {
                                Icon(
                                    if (selected) d.activeIcon else d.icon,
                                    null,
                                    Modifier.size(18.dp),
                                )
                            }
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
            shape = CircleShape,
            color = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onSurface,
            border = stroke,
            shadowElevation = 6.dp,
        ) {
            Box(
                Modifier
                    .clip(CircleShape)
                    .hazeEffect(hazeState, frost) { blurRadius = 14.dp }
                    .combinedClickable(onClick = onRefresh, onLongClick = onRefreshLongPress)
                    .size(52.dp),
                contentAlignment = Alignment.Center,
            ) {
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
