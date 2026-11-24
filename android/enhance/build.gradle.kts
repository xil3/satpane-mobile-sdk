plugins {
  id("com.android.library")
  id("org.jetbrains.kotlin.android")
  `maven-publish`
}

// Published to the static Maven repository at https://satpane.com/maven as com.satpane:enhance.
val sdkGroup = System.getenv("GROUP")?.let { g -> System.getenv("ARTIFACT")?.let { "$g.$it" } ?: g } ?: "com.satpane"
val sdkVersion = System.getenv("VERSION") ?: "0.1.2"
group = sdkGroup
version = sdkVersion

android {
  namespace = "com.satpane.enhance"
  compileSdk = 35
  defaultConfig {
    minSdk = 24
    consumerProguardFiles("consumer-rules.pro")
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
  publishing {
    singleVariant("release") { withSourcesJar() }
  }
}

dependencies {
  // ONNX Runtime (Microsoft, MIT): runs the model on the phone's CPU with XNNPACK.
  api("com.microsoft.onnxruntime:onnxruntime-android:1.30.0")
  testImplementation("junit:junit:4.13.2")
  testImplementation("org.json:json:20240303")
}

publishing {
  // A static Maven repository, served at https://satpane.com/maven (see the satpane repo's apps/web/public/maven).
  repositories {
    maven {
      name = "satpane"
      url = uri(layout.buildDirectory.dir("maven-repo"))
    }
  }
  publications {
    register<MavenPublication>("release") {
      groupId = sdkGroup
      artifactId = "enhance"
      version = sdkVersion
      afterEvaluate { from(components["release"]) }
      pom {
        name.set("Satpane Enhance")
        description.set("Sharper Satpane satellite imagery close up: AI super-resolution on the device.")
        url.set("https://satpane.com/docs")
        licenses { license { name.set("MIT"); url.set("https://opensource.org/licenses/MIT") } }
      }
    }
  }
}
