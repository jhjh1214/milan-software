allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Plugins are built against the same compileSdk as the app.
//
// Not tidiness. flutter_secure_storage 11 hardcodes `compileSdk = 37`, and
// Google no longer ships a platform called `android-37` -- only `android-37.0`
// and `android-37.1`, since SDKs gained minor versions. Gradle looks the target
// up by the exact hash string, finds nothing, and the release build fails with
// "Failed to find target with hash string 'android-37'".
//
// Aligning to the app's own compileSdk is the smallest fix that keeps the build
// reproducible on any machine. If a plugin ever genuinely needs an API the app's
// level does not have, this fails at compile time -- loudly, and in the right
// place -- rather than shipping something subtly wrong.
subprojects {
    fun alignCompileSdk() {
        val android = extensions.findByName("android")
        if (android !is com.android.build.gradle.BaseExtension) return
        val appSdk =
            project(":app").extensions
                .getByType(com.android.build.gradle.BaseExtension::class.java)
                .compileSdkVersion ?: return
        if (android.compileSdkVersion != appSdk) {
            android.compileSdkVersion(appSdk)
        }
    }

    // Some plugin projects are already evaluated by the time this block runs,
    // and `afterEvaluate` on one of those throws rather than running late.
    if (state.executed) alignCompileSdk() else afterEvaluate { alignCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
