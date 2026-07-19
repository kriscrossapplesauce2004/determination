package com.determination.companion

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * A purely cosmetic cover for the internal-panel ownership handoff.
 *
 * The toggle scripts remain authoritative and only give this activity a
 * bounded opportunity to draw. Enter settles onto an opaque final frame
 * before SurfaceFlinger stops; exit fades a matching frame away after Android
 * has returned. There is intentionally no root or toggle logic in here.
 */
class ModeTransitionActivity : Activity() {
    private val emphasized = PathInterpolator(0.05f, 0.7f, 0.1f, 1f)
    private val snappy = PathInterpolator(0.16f, 1f, 0.3f, 1f)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.addFlags(
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
        )
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)

        val direction = intent.getStringExtra(EXTRA_DIRECTION)
        val enteringDesktop = direction != DIRECTION_PHONE
        val scene = buildScene(enteringDesktop)
        setContentView(scene.root)
        scene.root.post {
            if (!ValueAnimator.areAnimatorsEnabled()) {
                showReducedMotion(scene, enteringDesktop)
            } else if (enteringDesktop) {
                animateIntoDesktop(scene)
            } else {
                animateIntoPhone(scene)
            }
        }
    }

    private data class Scene(
        val root: FrameLayout,
        val veil: View,
        val soul: ImageView,
        val title: TextView,
        val detail: TextView,
        val rule: View,
    )

    private fun buildScene(enteringDesktop: Boolean): Scene {
        val root = FrameLayout(this).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        val veil = View(this).apply {
            setBackgroundColor(Color.rgb(8, 8, 10))
            alpha = if (enteringDesktop) 0f else 1f
        }
        root.addView(veil, FrameLayout.LayoutParams(MATCH, MATCH))

        val stack = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        root.addView(
            stack,
            FrameLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER).apply {
                marginStart = dp(40)
                marginEnd = dp(40)
            },
        )

        val soul = ImageView(this).apply {
            setImageResource(R.drawable.ic_soul)
            alpha = if (enteringDesktop) 0f else 1f
            scaleX = if (enteringDesktop) 0.72f else 1f
            scaleY = scaleX
        }
        stack.addView(soul, LinearLayout.LayoutParams(dp(78), dp(68)))

        val title = TextView(this).apply {
            text = getString(if (enteringDesktop) R.string.transition_desktop else R.string.transition_phone)
            setTextColor(Color.WHITE)
            textSize = 17f
            letterSpacing = 0.22f
            gravity = Gravity.CENTER
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            alpha = if (enteringDesktop) 0f else 1f
            translationY = if (enteringDesktop) dp(14).toFloat() else 0f
        }
        stack.addView(
            title,
            LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(26)
            },
        )

        val rule = View(this).apply {
            setBackgroundColor(Color.rgb(255, 32, 48))
            pivotX = 0f
            scaleX = if (enteringDesktop) 0f else 1f
            alpha = if (enteringDesktop) 0f else 1f
        }
        stack.addView(
            rule,
            LinearLayout.LayoutParams(dp(132), dp(2)).apply { topMargin = dp(17) },
        )

        val detail = TextView(this).apply {
            text = getString(
                if (enteringDesktop) R.string.transition_desktop_detail
                else R.string.transition_phone_detail,
            )
            setTextColor(Color.rgb(176, 176, 184))
            textSize = 10f
            letterSpacing = 0.28f
            gravity = Gravity.CENTER
            typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            alpha = if (enteringDesktop) 0f else 1f
            translationY = if (enteringDesktop) dp(10).toFloat() else 0f
        }
        stack.addView(
            detail,
            LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(14)
            },
        )
        return Scene(root, veil, soul, title, detail, rule)
    }

    private fun animateIntoDesktop(scene: Scene) {
        scene.veil.animate().alpha(1f).setDuration(360).setInterpolator(emphasized).start()
        scene.soul.animate()
            .alpha(1f).scaleX(1f).scaleY(1f)
            .setStartDelay(45).setDuration(470)
            .setInterpolator(OvershootInterpolator(0.55f)).start()
        scene.title.animate()
            .alpha(1f).translationY(0f)
            .setStartDelay(105).setDuration(390).setInterpolator(snappy).start()
        scene.rule.animate()
            .alpha(1f).scaleX(1f)
            .setStartDelay(165).setDuration(360).setInterpolator(emphasized).start()
        scene.detail.animate()
            .alpha(1f).translationY(0f)
            .setStartDelay(220).setDuration(330).setInterpolator(snappy).start()
    }

    private fun animateIntoPhone(scene: Scene) {
        // Hold the opaque frame briefly so bootanim can disappear behind us,
        // then reveal Android in one composed motion.
        scene.detail.animate().alpha(0f).translationY(-dp(6).toFloat())
            .setStartDelay(125).setDuration(220).setInterpolator(snappy).start()
        scene.rule.pivotX = scene.rule.width.toFloat()
        scene.rule.animate().alpha(0f).scaleX(0f)
            .setStartDelay(145).setDuration(300).setInterpolator(emphasized).start()
        scene.title.animate().alpha(0f).translationY(-dp(9).toFloat())
            .setStartDelay(165).setDuration(260).setInterpolator(snappy).start()
        scene.soul.animate().alpha(0f).scaleX(1.16f).scaleY(1.16f)
            .setStartDelay(185).setDuration(330).setInterpolator(emphasized).start()
        scene.veil.animate().alpha(0f)
            .setStartDelay(205).setDuration(390).setInterpolator(emphasized)
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) = finishWithoutWindowAnimation()
            }).start()
    }

    private fun showReducedMotion(scene: Scene, enteringDesktop: Boolean) {
        scene.veil.alpha = if (enteringDesktop) 1f else 0f
        scene.soul.alpha = if (enteringDesktop) 1f else 0f
        scene.title.alpha = if (enteringDesktop) 1f else 0f
        scene.detail.alpha = if (enteringDesktop) 1f else 0f
        scene.rule.alpha = if (enteringDesktop) 1f else 0f
        if (!enteringDesktop) scene.root.postDelayed(::finishWithoutWindowAnimation, 80)
    }

    private fun finishWithoutWindowAnimation() {
        finishAndRemoveTask()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_DIRECTION = "direction"
        const val DIRECTION_DESKTOP = "desktop"
        const val DIRECTION_PHONE = "phone"
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}
