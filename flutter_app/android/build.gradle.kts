allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDirectory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDirectory)

subprojects {
    project.layout.buildDirectory.value(newBuildDirectory.dir(project.name))
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
