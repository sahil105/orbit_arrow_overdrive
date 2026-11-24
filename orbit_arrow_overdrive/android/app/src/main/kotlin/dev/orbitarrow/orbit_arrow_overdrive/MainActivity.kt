package dev.orbitarrow.orbit_arrow_overdrive

import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var audio: OrbitAudio? = null
    private var soundChannel: MethodChannel? = null
    private var hapticsChannel: MethodChannel? = null
    private var audioUnavailable = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        soundChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "orbit_arrow/sound")
        soundChannel?.setMethodCallHandler { call, result ->
            if (call.method == "stop") {
                audio?.stop()
                result.success(null)
                return@setMethodCallHandler
            }
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

        hapticsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "orbit_arrow/haptics")
        hapticsChannel?.setMethodCallHandler { call, result ->
            if (call.method == "pulse") {
                vibrationPulse(call.arguments == true)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun vibrationPulse(heavy: Boolean) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            getSystemService(Vibrator::class.java)
        }
        if (vibrator?.hasVibrator() != true) return

        val duration = if (heavy) 45L else 18L
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val amplitude = if (vibrator.hasAmplitudeControl()) {
                if (heavy) 180 else 105
            } else {
                VibrationEffect.DEFAULT_AMPLITUDE
            }
            vibrator.vibrate(VibrationEffect.createOneShot(duration, amplitude))
        } else {
            vibrator.vibrate(duration)
        }
    }

    override fun onPause() {
        audio?.stop()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        soundChannel?.setMethodCallHandler(null)
        soundChannel = null
        hapticsChannel?.setMethodCallHandler(null)
        hapticsChannel = null
        audio?.release()
        audio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
