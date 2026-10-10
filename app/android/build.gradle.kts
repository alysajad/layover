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
// Mapbox 3.0.0 checks the AGP major but misses Flutter's builtInKotlin=false
// compatibility mode. Apply KGP for this plugin only until Mapbox fixes that check.
subprojects {
    if (name == "mapbox_maps_flutter_mobile" &&
        providers.gradleProperty("android.builtInKotlin").orNull == "false") {
        plugins.withId("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
