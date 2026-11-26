pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "LazySend"
include(":app")

// Only for the Rust link check: needs the library and bindings built first (scripts/rust_link_android.sh).
if (providers.gradleProperty("lazysend.rustLink").isPresent) include(":rustlink")
