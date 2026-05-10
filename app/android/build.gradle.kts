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

// AGP 8 makes android.namespace mandatory. Some older Flutter plugins
// (notably isar_flutter_libs) still declare `package` in AndroidManifest.xml
// and have no namespace in their build.gradle, which breaks :assembleDebug.
// We patch the missing namespace in afterEvaluate via reflection so we don't
// have to fork the plugin or pin AGP < 8. Must register BEFORE the
// `evaluationDependsOn(":app")` block below or subprojects are already
// evaluated by the time afterEvaluate runs.
subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
        val getNamespace = runCatching { androidExt.javaClass.getMethod("getNamespace") }.getOrNull()
        val setNamespace = runCatching {
            androidExt.javaClass.getMethod("setNamespace", String::class.java)
        }.getOrNull()
        if (getNamespace == null || setNamespace == null) return@afterEvaluate
        val current = getNamespace.invoke(androidExt) as String?
        if (current.isNullOrBlank()) {
            val group = project.group.toString()
            val ns = if (group.isNotBlank() && group != "unspecified") {
                group
            } else {
                "dev.flutter.plugin.${project.name.replace('-', '_').replace('.', '_')}"
            }
            setNamespace.invoke(androidExt, ns)
        }
    }
}

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
