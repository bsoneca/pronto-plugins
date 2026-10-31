// AGP's built-in Kotlin compiles with the KGP on this classpath; quickjs-kt
// 1.0.14 carries Kotlin 2.4 metadata, which AGP 9.4.1's own 2.2 cannot read.
buildscript {
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.10")
    }
}

plugins {
    id("com.android.application") version "9.4.1" apply false
}
