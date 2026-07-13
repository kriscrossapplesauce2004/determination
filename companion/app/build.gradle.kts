plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.determination.companion"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.determination.companion"
        minSdk = 26
        targetSdk = 35
        versionCode = 9
        versionName = "0.5.4"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    // XML theme parent (Theme.Material3.*) for the pre-Compose window + QS tile.
    implementation("com.google.android.material:material:1.12.0")

    // Compose / Material 3 Expressive. Pinned to 1.4.0-alpha18: the Expressive
    // APIs (MaterialExpressiveTheme, LoadingIndicator, wavy indicators…) are
    // public only in the alpha channel — 1.4.0 stable made them internal, and
    // the 1.5.0 alphas need compileSdk 37 / AGP 9.1 (beyond Gradle 8.7).
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    // window-size-class must match: the androidx atomic-group constraint would
    // otherwise force the whole material3 group back to the stable version.
    implementation("androidx.compose.material3:material3:1.4.0-alpha18")
    implementation("androidx.compose.material3:material3-window-size-class:1.4.0-alpha18")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")

    // Real backdrop blur (RenderEffect on 12+, scrim fallback below).
    // 1.6.x is the last line on Compose 1.8/compileSdk 35 — 1.7+ pulls
    // androidx deps that demand SDK 36 / AGP 8.9.
    implementation("dev.chrisbanes.haze:haze:1.6.10")
    implementation("dev.chrisbanes.haze:haze-materials:1.6.10")
}
