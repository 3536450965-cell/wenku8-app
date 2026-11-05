package org.mewx.wenku8_flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin

// The public snapshot ships the engine wiring for four capabilities whose
// sources are not part of the snapshot (LAN sync, live narration enhancement,
// custom speech configuration). They are registered so the engine matches the
// upstream build, but they expose no channels: nothing in this build calls
// them, and a missing channel is reported the same way as an absent plugin.

/** Placeholder for the live narration enhancement engine. */
class ListeningEnhancementPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}

/** Placeholder for the LAN reading configuration exchange. */
class LanReadingConfigPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}

/** Placeholder for LAN peer discovery. */
class LanDiscoveryPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}

/** Placeholder for the custom speech provider settings bridge. */
class CustomSpeechConfigPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}