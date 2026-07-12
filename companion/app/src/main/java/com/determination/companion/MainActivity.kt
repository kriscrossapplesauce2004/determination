package com.determination.companion

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import com.determination.companion.ui.DetApp
import com.determination.companion.ui.DetTheme

/**
 * Compose host. All state + root plumbing lives in [DetViewModel]; the UI is
 * Material 3 Expressive, edge-to-edge, and adapts to compact/medium/expanded
 * window size classes (phone, landscape/tablet, DP-alt desktop).
 */
class MainActivity : ComponentActivity() {

    private val vm: DetViewModel by viewModels()

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            DetTheme {
                DetApp(vm, calculateWindowSizeClass(this))
            }
        }
    }

    override fun onResume() {
        super.onResume()
        vm.refresh()
    }
}
