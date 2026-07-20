package com.determination.companion

import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.io.File

object NativePresenter {
    init {
        System.loadLibrary("det_presenter")
    }

    external fun nativeStart(
        surface: Surface,
        socketPath: String,
        width: Int,
        height: Int,
        refreshRate: Float
    ): Boolean
    external fun nativeResize(width: Int, height: Int)
    external fun nativeStop()
}

/**
 * Owns the Android external-display endpoint. KWin remains the compositor;
 * this class merely gives its gralloc buffers a normal app-owned SurfaceControl
 * on the presentation display, so Android can keep the phone display alive.
 */
class ExternalDisplayPresenter(private val context: Context) :
    DisplayManager.DisplayListener {

    companion object {
        private const val TAG = "DetExternalDisplay"
        const val SOCKET_NAME = "presenter.sock"
    }

    private val displays = context.getSystemService(DisplayManager::class.java)
    private val socketDir: File = context.createDeviceProtectedStorageContext()
        .filesDir.apply { mkdirs() }
    private var presentation: GuestPresentation? = null
    private var displaySignature: DisplaySignature? = null
    private var started = false

    private data class DisplaySignature(
        val displayId: Int,
        val modeId: Int,
        val width: Int,
        val height: Int,
        val refreshMilliHz: Int,
    )

    fun start() {
        if (started) return
        started = true
        displays.registerDisplayListener(this, null)
        refresh()
    }

    fun stop() {
        if (!started) return
        started = false
        displays.unregisterDisplayListener(this)
        presentation?.dismiss()
        presentation = null
        displaySignature = null
        NativePresenter.nativeStop()
    }

    override fun onDisplayAdded(displayId: Int) = refresh()
    override fun onDisplayRemoved(displayId: Int) = refresh()
    override fun onDisplayChanged(displayId: Int) = refresh()

    private fun refresh() {
        val candidate = displays
            .getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
            .firstOrNull { it.displayId != Display.DEFAULT_DISPLAY && it.isValid }
        val mode = candidate?.mode
        val signature = if (candidate != null && mode != null) {
            DisplaySignature(
                candidate.displayId,
                mode.modeId,
                mode.physicalWidth,
                mode.physicalHeight,
                (mode.refreshRate * 1000f).toInt(),
            )
        } else null
        if (signature == displaySignature && presentation?.isShowing == true) return

        presentation?.dismiss()
        presentation = null
        displaySignature = null
        NativePresenter.nativeStop()
        if (candidate != null) {
            Log.i(TAG, "attaching to ${candidate.name} (${candidate.displayId})")
            try {
                presentation = GuestPresentation(
                    context,
                    candidate,
                    File(socketDir, SOCKET_NAME).absolutePath,
                ).also { it.show() }
                displaySignature = signature
            } catch (error: Throwable) {
                presentation = null
                Log.w(TAG, "display disappeared while attaching: ${error.message}")
            }
        } else {
            Log.i(TAG, "no external presentation display")
        }
    }
}

private class GuestPresentation(
    context: Context,
    display: Display,
    private val socketPath: String
) : Presentation(context, display), SurfaceHolder.Callback {

    private lateinit var surfaceView: SurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        surfaceView = SurfaceView(context).also {
            it.setZOrderOnTop(false)
            it.holder.addCallback(this)
        }
        setContentView(surfaceView)
    }

    override fun surfaceCreated(holder: SurfaceHolder) = Unit

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (width <= 0 || height <= 0 || !holder.surface.isValid) return
        NativePresenter.nativeStop()
        val refreshRate = display.mode.refreshRate
        val nativeStarted = NativePresenter.nativeStart(
            holder.surface, socketPath, width, height, refreshRate,
        )
        Log.i(
            "DetExternalDisplay",
            "surface ${width}x$height @ $refreshRate: started=$nativeStarted",
        )
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        NativePresenter.nativeStop()
    }
}
