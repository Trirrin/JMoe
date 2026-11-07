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

// 部分插件（如 jni_flutter）把 compileSdk 写死为 35，
// 会强制要求本机安装 android-35 平台。这里统一提升到本机已安装的 android-36，
// 避免构建期再去下载其它平台组件。
// 注意：必须在 :app 评估之前注册，故放在 evaluationDependsOn 之前。
subprojects {
    afterEvaluate {
        val ext = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            val getter = ext.javaClass.methods.firstOrNull {
                it.name == "getCompileSdkVersion" && it.parameterCount == 0
            }
            val setter = ext.javaClass.methods.firstOrNull {
                it.name == "setCompileSdkVersion" && it.parameterCount == 1
            }
            if (getter != null && setter != null) {
                val current = getter.invoke(ext)?.toString()
                if (current != null && current != "36" && current != "android-36") {
                    setter.invoke(ext, "android-36")
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
