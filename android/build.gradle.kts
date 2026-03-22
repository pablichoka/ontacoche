import org.gradle.api.tasks.Delete
import org.gradle.api.tasks.compile.JavaCompile

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

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

// Ensure Java compilation uses modern language level and avoids old -source/-target defaults.
subprojects {
    // Apply to all JavaCompile tasks (including those from plugins) to prevent
    // `javac` warnings about obsolete source/target values.
    tasks.withType<JavaCompile>().configureEach {
        // Avoid using `--release` on Android projects (AGP requires bootclasspath setup).
        sourceCompatibility = JavaVersion.VERSION_11.toString()
        targetCompatibility = JavaVersion.VERSION_11.toString()
        options.compilerArgs.addAll(listOf("-Xlint:-options", "-Xlint:-deprecation", "-nowarn"))
    }
}
