package dev.orbitarrow.orbit_arrow_overdrive

import android.app.Activity
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool

/** Created on the first gameplay sound, never during Android launch. */
class OrbitAudio(activity: Activity) {
    private val pool = SoundPool.Builder().setMaxStreams(3).setAudioAttributes(
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    ).build()
    private val ready = mutableSetOf<Int>()
    private var pending: Int? = null
    private val samples: Map<String, Int>

    init {
        activity.volumeControlStream = AudioManager.STREAM_MUSIC
        pool.setOnLoadCompleteListener { _, sample, status ->
            if (status == 0) {
                ready.add(sample)
                if (pending == sample) playSample(sample)
            }
            if (pending == sample) pending = null
        }
        samples = try {
            mapOf(
                "launch" to pool.load(activity, R.raw.orbit_launch, 1),
                "hit" to pool.load(activity, R.raw.orbit_hit, 1),
                "miss" to pool.load(activity, R.raw.orbit_miss, 1),
                "win" to pool.load(activity, R.raw.orbit_win, 1),
            )
        } catch (error: RuntimeException) {
            pool.release()
            throw error
        }
    }

    fun play(cue: String) {
        val sample = samples[cue] ?: return
        if (sample in ready) {
            pending = null
            playSample(sample)
        } else if (sample != 0) {
            pending = sample
        }
    }

    private fun playSample(sample: Int) {
        pool.play(sample, .65f, .65f, 1, 0, 1f)
    }

    fun pause() {
        pending = null
        pool.autoPause()
    }

    fun release() {
        pending = null
        pool.setOnLoadCompleteListener(null)
        pool.release()
    }
}
