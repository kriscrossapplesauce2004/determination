package com.determination.companion

import android.graphics.drawable.Icon
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
            val hasRoot = Root.hasRoot()
            val mode = if (hasRoot) Root.status()["mode"] ?: "?" else "?"
            val t = qsTile ?: return@execute
            when {
                !hasRoot -> {
                    t.state = Tile.STATE_UNAVAILABLE
                    t.label = getString(R.string.app_name)
                }
                mode == "desktop" -> {
                    t.state = Tile.STATE_ACTIVE
                    t.label = getString(R.string.tile_active)
                }
                else -> {
                    t.state = Tile.STATE_INACTIVE
                    t.label = getString(R.string.tile_label)
                }
            }
            t.icon = Icon.createWithResource(this, R.drawable.ic_desktop)
            t.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        io.execute {
            if (!Root.hasRoot()) return@execute
            val mode = Root.status()["mode"]
            if (mode == "desktop") Root.exitDesktop() else Root.enterDesktop()
            refreshTile()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        io.shutdownNow()
    }
}
