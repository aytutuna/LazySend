plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

abstract class CornerModelAssets : DefaultTask() {
    @get:InputFiles
    abstract val model: ConfigurableFileCollection

    @get:InputFiles
    abstract val notices: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val file = model.singleFile
        if (!file.exists()) throw GradleException("The corner model is missing: run scripts/fetch_docaligner.sh")
        val out = outputDir.get().asFile
        file.copyTo(out.resolve(file.name), overwrite = true)
        notices.forEach { it.copyTo(out.resolve("licenses/${it.name}"), overwrite = true) }
    }
}

android {
    namespace = "com.lazysend.lazysend"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.lazysend.lazysend"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += setOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all { test ->
                test.systemProperty("robolectric.logging.enabled", "false")
                (findProperty("lazysend.shotsDir") as String?)?.let { test.systemProperty("lazysend.shotsDir", it) }
                test.maxHeapSize = "3g"
                // Robolectric reaches into JDK internals that newer JDKs close by default.
                test.jvmArgs(
                    "--add-opens=java.base/java.io=ALL-UNNAMED",
                    "--add-opens=java.base/java.lang=ALL-UNNAMED",
                    "--add-opens=java.base/java.util=ALL-UNNAMED",
                    "--add-opens=java.base/java.nio=ALL-UNNAMED",
                    "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",
                    "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
                    "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
                    "--enable-native-access=ALL-UNNAMED",
                )
            }
        }
    }

    // The page photos of the scan model's tests are read straight from the Swift tests' folder.
    sourceSets.getByName("androidTest").assets.directories.add("../../Tests/LazySendScanModelTests/Fixtures/Pages")

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/LICENSE*")
    }
}

// The model is fetched, not checked in, and its licence texts ride along in the assets; a build without it would ship a scanner that finds nothing.
androidComponents {
    onVariants { variant ->
        val task = tasks.register<CornerModelAssets>("add${variant.name.replaceFirstChar { it.uppercase() }}CornerModel") {
            model.from(rootProject.file("../Sources/LazySendScanModel/Models/fastvit_t8_h_e_bifpn_256_fp32.onnx"))
            notices.from(
                rootProject.fileTree("../Sources/LazySendScanModel/Models") { include("*LICENSE.txt", "*THIRD-PARTY-NOTICES.txt") },
            )
        }
        variant.sources.assets?.addGeneratedSourceDirectory(task, CornerModelAssets::outputDir)
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.core.ktx)
    implementation(libs.work.runtime)

    implementation(libs.camerax.core)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)
    implementation(libs.zxing.core)
    implementation(libs.onnxruntime.android)

    implementation(libs.okhttp)
    implementation(libs.okhttp.coroutines)
    implementation(libs.serialization.json)
    implementation(libs.coroutines.android)

    testImplementation(libs.junit)
    testImplementation(libs.onnxruntime.desktop)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.okhttp.tls)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}
