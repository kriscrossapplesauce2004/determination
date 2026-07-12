package com.determination.companion

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

enum class RootState { CHECKING, GRANTED, DENIED }

/** One entry in the guest software catalog. */
data class CatalogApp(
    val pkg: String,
    val title: String,
    val blurb: String,
    val category: String,
)

data class CompositorChoice(
    val id: String,
    val title: String,
    val blurb: String,
    val status: CompositorStatus,
    val aptPkg: String? = null,
)

enum class CompositorStatus { ACTIVE, EXPERIMENTAL, INCOMPATIBLE }

val COMPOSITORS = listOf(
    CompositorChoice(
        "phosh", "Phosh · phoc",
        "The verified stack: phoc 0.47 on the droidian wlroots hwcomposer backend, " +
            "phosh mobile shell, squeekboard OSK. This is what desktop mode runs.",
        CompositorStatus.ACTIVE,
    ),
    CompositorChoice(
        "labwc", "labwc",
        "Openbox-style stacking Wayland compositor. Installs from Debian; session " +
            "wiring into desktop-on is still pending, so selecting it stores the preference only.",
        CompositorStatus.EXPERIMENTAL, aptPkg = "labwc",
    ),
    CompositorChoice(
        "wayfire", "Wayfire",
        "3D-effects compositor. Installs from Debian; same caveat — the session " +
            "launcher only starts phoc today.",
        CompositorStatus.EXPERIMENTAL, aptPkg = "wayfire",
    ),
    CompositorChoice(
        "sway", "Sway",
        "Dead end on this device: incompatible with the droidian wlroots hybrid " +
            "0.17/0.18 API the display stack depends on.",
        CompositorStatus.INCOMPATIBLE,
    ),
)

val CATALOG = listOf(
    CatalogApp("firefox-esr", "Firefox ESR", "Full desktop browser", "Browsers"),
    CatalogApp("chromium", "Chromium", "Blink engine, wayland-native", "Browsers"),
    CatalogApp("epiphany-browser", "GNOME Web", "Lightweight WebKit browser", "Browsers"),
    CatalogApp("mpv", "mpv", "Minimal, GPU-accelerated video player", "Media"),
    CatalogApp("vlc", "VLC", "Plays everything", "Media"),
    CatalogApp("gnome-loupe", "Image Viewer", "GNOME Loupe, touch-friendly", "Media"),
    CatalogApp("libreoffice", "LibreOffice", "Full office suite (large!)", "Productivity"),
    CatalogApp("gnome-text-editor", "Text Editor", "GNOME's modern editor", "Productivity"),
    CatalogApp("evince", "Document Viewer", "PDF and friends", "Productivity"),
    CatalogApp("gnome-calculator", "Calculator", "GNOME calculator", "Productivity"),
    CatalogApp("nautilus", "Files", "GNOME file manager", "Productivity"),
    CatalogApp("phosh-mobile-settings", "Mobile Settings", "Phosh tweaks & scaling", "System"),
    CatalogApp("feedbackd", "feedbackd", "Haptics + LED event feedback", "System"),
    CatalogApp("htop", "htop", "Interactive process viewer", "System"),
    CatalogApp("fastfetch", "fastfetch", "System info, for screenshots", "System"),
    CatalogApp("foot", "foot", "Fast Wayland terminal", "System"),
)

class DetViewModel : ViewModel() {

    // Control
    var rootState by mutableStateOf(RootState.CHECKING); private set
    var status by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var busy by mutableStateOf<String?>(null); private set
    var message by mutableStateOf<String?>(null)  // one-shot snackbar text
    var logText by mutableStateOf<String?>(null)
    var logName by mutableStateOf<String?>(null)

    // Installer
    var inventory by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var artifacts by mutableStateOf<List<String>>(emptyList()); private set

    // Software
    var pkgStatus by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var guestUp by mutableStateOf(false); private set
    var compositor by mutableStateOf("phosh"); private set
    var installingPkg by mutableStateOf<String?>(null); private set

    val logs = listOf("compositor.log", "toggle.log", "hostagent.log", "service.log")

    fun refresh() {
        busy = "status"
        viewModelScope.launch(Dispatchers.IO) {
            val hasRoot = Root.hasRoot()
            rootState = if (hasRoot) RootState.GRANTED else RootState.DENIED
            status = if (hasRoot) Root.status() else emptyMap()
            busy = null
        }
    }

    fun refreshInstaller() {
        if (rootState != RootState.GRANTED) return
        busy = "inventory"
        viewModelScope.launch(Dispatchers.IO) {
            inventory = Root.inventory()
            artifacts = Root.findArtifacts()
            busy = null
        }
    }

    fun refreshSoftware() {
        if (rootState != RootState.GRANTED) return
        busy = "software"
        viewModelScope.launch(Dispatchers.IO) {
            compositor = Root.getCompositor()
            guestUp = Root.guestRunning()
            pkgStatus =
                if (guestUp) Root.dpkgStatus(CATALOG.map { it.pkg } + COMPOSITORS.mapNotNull { it.aptPkg })
                else emptyMap()
            busy = null
        }
    }

    /** Run a Root action with a busy label, then refresh control status. */
    fun act(label: String, refreshAfter: Boolean = true, action: () -> Root.Result) {
        busy = label
        viewModelScope.launch(Dispatchers.IO) {
            val r = action()
            if (!r.ok) message = r.err.ifBlank { r.out }.ifBlank { "failed" }
            busy = null
            if (refreshAfter) refresh()
        }
    }

    fun installModule(path: String) {
        busy = "module"
        viewModelScope.launch(Dispatchers.IO) {
            val r = Root.installModuleZip(path)
            message = if (r.ok) "Module installed — reboot to apply"
            else "Install failed: ${r.err.ifBlank { r.out }}"
            inventory = Root.inventory()
            busy = null
        }
    }

    fun flashBoot(path: String) {
        busy = "flash"
        viewModelScope.launch(Dispatchers.IO) {
            val r = Root.flashBootImage(path)
            message = if (r.ok) "Boot image flashed — reboot to apply"
            else "Flash failed: ${r.err.ifBlank { r.out }}"
            busy = null
        }
    }

    fun installApk(path: String) {
        busy = "apk"
        viewModelScope.launch(Dispatchers.IO) {
            val r = Root.installApk(path)
            message = if (r.ok) "App updated" else "APK install failed: ${r.err.ifBlank { r.out }}"
            busy = null
        }
    }

    fun installPkg(pkg: String) {
        installingPkg = pkg
        viewModelScope.launch(Dispatchers.IO) {
            val r = Root.aptInstall(pkg)
            message = if (r.ok) "$pkg installed" else "apt failed: ${r.out.ifBlank { r.err }}"
            pkgStatus = Root.dpkgStatus(CATALOG.map { it.pkg } + COMPOSITORS.mapNotNull { it.aptPkg })
            installingPkg = null
        }
    }

    fun removePkg(pkg: String) {
        installingPkg = pkg
        viewModelScope.launch(Dispatchers.IO) {
            val r = Root.aptRemove(pkg)
            message = if (r.ok) "$pkg removed" else "apt failed: ${r.out.ifBlank { r.err }}"
            pkgStatus = Root.dpkgStatus(CATALOG.map { it.pkg } + COMPOSITORS.mapNotNull { it.aptPkg })
            installingPkg = null
        }
    }

    fun selectCompositor(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            Root.setCompositor(id)
            compositor = id
            if (id != "phosh") message = "Preference stored — session wiring for $id is still pending"
        }
    }

    fun openLog(name: String) {
        logName = name
        logText = null
        viewModelScope.launch(Dispatchers.IO) { logText = Root.tailLog(name) }
    }

    fun closeLog() { logName = null; logText = null }
}
