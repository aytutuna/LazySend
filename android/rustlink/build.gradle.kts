plugins {
    alias(libs.plugins.android.library)
}

// lazysend.rustLink names the folder with the generated Kotlin (kotlin/) and the cargo-ndk output (jniLibs/).
val rustLink = file(providers.gradleProperty("lazysend.rustLink").get())

android {
    namespace = "com.lazysend.rustlink"
    compileSdk = 37

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.kotlin?.addStaticSourceDirectory(rustLink.resolve("kotlin").path)
        variant.sources.jniLibs?.addStaticSourceDirectory(rustLink.resolve("jniLibs").path)
        variant.androidTest?.sources?.assets?.addStaticSourceDirectory(rootProject.file("../testdata/link").path)
    }
}

dependencies {
    implementation("${libs.jna.get().module}:${libs.versions.jna.get()}@aar")
    implementation(libs.coroutines.android)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.serialization.json)
}
