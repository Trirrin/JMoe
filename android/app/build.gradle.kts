plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.liuyue.jmoe"
    // 固定使用本机已安装的 SDK 平台（android-36），避免构建期自动下载其它平台包。
    compileSdk = 36
    buildToolsVersion = "36.1.0"

    // 启用 NDK 符号剥离（libflutter.so 未剥离时约 157MB，剥离后约 11MB）。
    // 若本机未安装该版本 NDK，构建脚本会自动回退到内置 strip 工具。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.liuyue.jmoe"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 使用 debug 签名。
            //
            // 这样 `flutter build apk --release` 出来的包可以直接侧载安装，
            // 不需要用户另行配置 keystore。参考 Kazumi 的做法。
            //
            // 注意：如果将来要上架应用市场或做覆盖升级，
            // 必须换成正式签名（keystore），否则不同机器的 debug 签名
            // 不一致会导致无法覆盖安装。
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    // FileProvider（分享 / 打开目录需要 content:// URI）
    implementation("androidx.core:core:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 若本机没有完整 NDK，则指向包含 llvm-strip 的精简 NDK 目录，
// 使 AGP 能完成 strip 步骤（本项目无原生代码，只需 strip 工具）。
//
// 注意：**不能硬编码开发机的绝对路径**，否则 CI（GitHub Actions 等）
// 上没有该路径会直接构建失败。这里改为「多个候选路径 + 存在才用」，
// 都找不到就跳过 —— 本工程没有原生代码，跳过 strip 也能正常出包。
val slimNdkCandidates = listOfNotNull(
    System.getenv("JMoe_SLIM_NDK"),
    System.getenv("ANDROID_NDK_HOME"),
    System.getenv("ANDROID_NDK_ROOT"),
    // 开发机约定路径（存在才用，不存在不影响 CI）
    "F:/_sdk/ndk",
).map { file(it) }

val installedNdk = System.getenv("ANDROID_NDK_HOME")
    ?: System.getenv("ANDROID_NDK_ROOT")

val slimNdk = slimNdkCandidates.firstOrNull {
    it.resolve("bin/llvm-strip.exe").exists() ||
        it.resolve("toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe").exists()
}
if (slimNdk != null && installedNdk == null) {
    android.ndkPath = slimNdk.path
}

// Flutter Gradle 插件在没有检测到已安装 NDK 时，会向 AGP 注入一个“空的” externalNativeBuild
// （仅为了强制 AGP 去校验/下载 NDK）。本工程没有任何原生代码，不需要 NDK，
// 因此在其之后把该配置清空，让 AGP 走纯 Java/Kotlin 构建路径。
androidComponents {
    finalizeDsl { ext ->
        ext.externalNativeBuild.cmake.path = null
    }
}
