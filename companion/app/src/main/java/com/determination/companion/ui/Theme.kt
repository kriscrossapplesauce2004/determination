package com.determination.companion.ui

import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.expressiveLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

// Fallback (pre-Android 12, no dynamic color): the red SOUL.
private val SoulRed = Color(0xFFB3261E)

private fun soulLight(): ColorScheme = expressiveFallbackLight()
private fun soulDark(): ColorScheme = darkColorScheme(
    primary = Color(0xFFFFB4AB),
    onPrimary = Color(0xFF690005),
    primaryContainer = Color(0xFF93000A),
    onPrimaryContainer = Color(0xFFFFDAD6),
    secondary = Color(0xFFE7BDB8),
    tertiary = Color(0xFFDFC38C),
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
private fun expressiveFallbackLight(): ColorScheme =
    expressiveLightColorScheme().copy(
        primary = SoulRed,
        primaryContainer = Color(0xFFFFDAD6),
        onPrimaryContainer = Color(0xFF410002),
    )

/**
 * Material 3 Expressive theme: wallpaper-derived dynamic color on Android 12+,
 * soul-red fallback below, expressive (springy) motion scheme everywhere.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DetTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> soulDark()
        else -> soulLight()
    }
    MaterialExpressiveTheme(
        colorScheme = scheme,
        motionScheme = MotionScheme.expressive(),
        content = content,
    )
}

/**
 * "Aurora glass" backdrop: three big soft radial blobs in the theme's accent
 * colors under every screen. Translucent surfaces above it read as frosted
 * glass without needing (unavailable) backdrop blur.
 */
@Composable
fun AuroraBackground(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Box(modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(cs.surface)
            val w = size.width
            val h = size.height
            drawCircle(
                brush = Brush.radialGradient(
                    listOf(cs.primary.copy(alpha = 0.30f), Color.Transparent),
                    center = Offset(w * 0.15f, h * 0.05f), radius = w * 0.9f,
                ),
                center = Offset(w * 0.15f, h * 0.05f), radius = w * 0.9f,
            )
            drawCircle(
                brush = Brush.radialGradient(
                    listOf(cs.tertiary.copy(alpha = 0.22f), Color.Transparent),
                    center = Offset(w * 1.05f, h * 0.35f), radius = w * 0.8f,
                ),
                center = Offset(w * 1.05f, h * 0.35f), radius = w * 0.8f,
            )
            drawCircle(
                brush = Brush.radialGradient(
                    listOf(cs.secondary.copy(alpha = 0.18f), Color.Transparent),
                    center = Offset(w * 0.3f, h * 0.95f), radius = w,
                ),
                center = Offset(w * 0.3f, h * 0.95f), radius = w,
            )
        }
        content()
    }
}

/** Card container color for the frosted-glass look. */
@Composable
fun glassColor(): Color =
    MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.72f)
