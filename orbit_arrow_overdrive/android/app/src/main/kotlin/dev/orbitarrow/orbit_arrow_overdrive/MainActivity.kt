package dev.orbitarrow.orbit_arrow_overdrive

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var audio: OrbitAudio? = null
    private var soundChannel: MethodChannel? = null
    private var audioUnavailable = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        soundChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "orbit_arrow/sound")
        soundChannel?.setMethodCallHandler { call, result ->
            val cue = call.arguments as? String
            if (call.method != "play" || cue == null) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (!audioUnavailable) {
                try {
                    val player = audio ?: OrbitAudio(this).also { audio = it }
                    player.play(cue)
                } catch (error: RuntimeException) {
                    audioUnavailable = true
                    Log.w("OrbitArrow", "Optional game audio unavailable", error)
                } catch (error: LinkageError) {
                    audioUnavailable = true
                    Log.w("OrbitArrow", "Optional game audio unsupported", error)
                }
            }
            result.success(null)
        }
    }

    override fun onPause() {
        audio?.pause()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        soundChannel?.setMethodCallHandler(null)
        soundChannel = null
        audio?.release()
        audio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
