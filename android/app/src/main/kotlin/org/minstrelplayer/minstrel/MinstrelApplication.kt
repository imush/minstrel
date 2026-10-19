package org.minstrelplayer.minstrel

import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
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
        // Channels first, then Dart: main() asks for the lock straight away.
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(AudioServicePlugin.getFlutterEngineId(), engine)
    }
}
