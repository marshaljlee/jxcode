// Root build file. Plugins are declared here with `apply false` and applied
// per-module, so the version is authored exactly once.
plugins {
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    // Generates .serializer() for the @Serializable wire models; without it
    // every encodeToString(Foo.serializer(), …) fails to resolve.
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.21" apply false
}
