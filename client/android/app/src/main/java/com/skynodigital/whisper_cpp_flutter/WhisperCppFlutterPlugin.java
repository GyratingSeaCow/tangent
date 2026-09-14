package com.skynodigital.whisper_cpp_flutter;

import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * Registration shim for whisper_cpp_flutter_plus 0.4.1.
 *
 * The package declares an Android plugin class but its Gradle module does not
 * apply the Kotlin plugin, so the declared Kotlin registrar is absent from the
 * AAR. Tangent uses the package's FFI model/runtime APIs and its own audio
 * decoder; no plugin MethodChannel functionality is required.
 */
public final class WhisperCppFlutterPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {}

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {}
}
