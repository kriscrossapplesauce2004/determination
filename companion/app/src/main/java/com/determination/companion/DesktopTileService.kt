package com.determination.companion

import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import java.util.concurrent.Executors

/**
 * Quick Settings tile. In phone mode a tap enters desktop mode (the fastest
 * path — pull down the shade, tap once). In desktop mode the Android shade is
 * gone (SurfaceFlinger is stopped), so the tile is really an enter-button;
 * the toggle-back path lives inside the guest (det-signal exit).
 */
class DesktopTileService : TileService() {

    private val io = Executors.newSingleThreadExecutor()

    override fun onStartListening() {
        super.onStartListening()
        refreshTile()
    }

    private fun refreshTile() {
        io.execute {
            // One su round-trip: status carries uid, which is the root check.
            val s = Root.status()
            val hasRoot = s["uid"] == "0"
            val mode = if (hasRoot) s["mode"] ?: "?" else "?"
            val t = qsTile ?: return@execute
            when {
                !hasRoot -> {
                    t.state = Tile.STATE_UNAVAILABLE
                    t.label = getString(R.string.app_name)
                    if (Build.VERSION.SDK_INT >= 29) t.subtitle = getString(R.string.tile_no_root)
                }
                mode == "desktop" -> {
                    t.state = Tile.STATE_ACTIVE
                    t.label = getString(R.string.tile_active)
                    if (Build.VERSION.SDK_INT >= 29) t.subtitle = getString(R.string.tile_tap_phone)
                }
                else -> {
                    t.state = Tile.STATE_INACTIVE
                    t.label = getString(R.string.tile_label)
                    if (Build.VERSION.SDK_INT >= 29) {
                        t.subtitle = if (s["guest"] == "running")
                            getString(R.string.tile_guest_ready)
                        else getString(R.string.tile_guest_stopped)
                    }
                }
            }
            t.icon = Icon.createWithResource(this, R.drawable.ic_desktop)
            t.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        io.execute {
            val s = Root.status()
            if (s["uid"] != "0") return@execute
            if (s["mode"] == "desktop") Root.exitDesktop() else Root.enterDesktop()
            refreshTile()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        io.shutdownNow()
    }
}
