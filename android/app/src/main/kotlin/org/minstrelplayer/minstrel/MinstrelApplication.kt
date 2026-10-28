package org.minstrelplayer.minstrel

import android.app.Application
import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Starts the one Flutter engine that the app screen and the playback
 * service share. Android Auto can start the service with no screen at all,
 * so the app's own channels are set up here rather than in MainActivity.
 */
class MinstrelApplication : Application() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        // SSDP discovery needs multicast, which Android filters out by
        // default to save battery.
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.minstrelplayer/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        if (multicastLock == null) {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("minstrel-ssdp").apply {
                                setReferenceCounted(false)
                                acquire()
                            }
                        }
                        result.success(null)
                    }
                    "release" -> {
                        multicastLock?.release()
                        multicastLock = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        volumeChannels(engine.dartExecutor.binaryMessenger)
        // Channels first, then Dart: main() asks for the lock straight away.
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(AudioServicePlugin.getFlutterEngineId(), engine)
    }

    /** The media volume, 0 to 1, for the slider on Now Playing (lib/playback/system_volume.dart). */
    private fun volumeChannels(messenger: BinaryMessenger) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val stream = AudioManager.STREAM_MUSIC
        fun current() = audio.getStreamVolume(stream).toDouble() / audio.getStreamMaxVolume(stream)
        MethodChannel(messenger, "org.minstrelplayer/volume").setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> result.success(if (audio.isVolumeFixed) null else current())
                "set" -> {
                    val v = (call.arguments as Number).toDouble()
                    val steps = Math.round(v * audio.getStreamMaxVolume(stream)).toInt()
                    audio.setStreamVolume(stream, steps, 0)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // The volume settings change with the buttons, from any app.
        EventChannel(messenger, "org.minstrelplayer/volume/changes").setStreamHandler(object : EventChannel.StreamHandler {
            private var observer: ContentObserver? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                    override fun onChange(selfChange: Boolean) = events.success(current())
                }.also { contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, it) }
            }

            override fun onCancel(arguments: Any?) {
                observer?.let { contentResolver.unregisterContentObserver(it) }
                observer = null
            }
        })
    }
}
