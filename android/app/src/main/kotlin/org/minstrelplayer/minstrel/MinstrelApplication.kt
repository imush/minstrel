package org.minstrelplayer.minstrel

import android.app.Application
import android.content.ContentValues
import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import android.provider.Settings
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

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
        storageChannel(engine.dartExecutor.binaryMessenger)
        // Channels first, then Dart: main() asks for the lock straight away.
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(AudioServicePlugin.getFlutterEngineId(), engine)
    }

    /**
     * Room on the volume the offline cache lives on
     * (lib/cache/device_storage.dart). filesDir is where path_provider puts
     * the application support directory, so it is the volume that matters.
     */
    private fun storageChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, "org.minstrelplayer/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "space" -> {
                    val stat = StatFs(filesDir.absolutePath)
                    result.success(mapOf("free" to stat.availableBytes, "total" to stat.totalBytes))
                }
                // Backup is excluded by res/xml/backup_rules.xml here, with
                // nothing to do at runtime; iOS has to mark the directory.
                "excludeFromBackup" -> result.success(null)
                "saveCopy" -> saveToDownloads(
                    call.argument<String>("path"),
                    call.argument<String>("name"),
                    call.argument<String>("mimeType"),
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Puts a file the app has already fetched into the device's own
     * Downloads, where people look for what they have downloaded
     * (lib/download/save_copy.dart).
     *
     * Through MediaStore, which needs no permission from Android 10 and
     * writes to the shared collection rather than somewhere only this app
     * can reach. Older versions would need broad storage permission for the
     * same thing, which is not worth asking of everybody, so they are told
     * it is unsupported and nothing is written.
     *
     * On a worker thread throughout: these are films, and copying one on
     * the main thread freezes the app until it finishes.
     */
    private fun saveToDownloads(
        path: String?,
        name: String?,
        mime: String?,
        result: MethodChannel.Result,
    ) {
        if (path == null || name == null) {
            result.error("arguments", "path and name are both required", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(mapOf("status" to "unsupported"))
            return
        }
        val main = Handler(Looper.getMainLooper())
        Thread {
            try {
                val resolver = contentResolver
                val pending = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    if (mime != null) put(MediaStore.Downloads.MIME_TYPE, mime)
                    // Hidden from other apps until it is whole, so a half
                    // copy is never offered to anybody.
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, pending)
                    ?: throw IOException("Downloads would not accept the file")
                try {
                    resolver.openOutputStream(uri).use { out ->
                        if (out == null) throw IOException("could not write to $uri")
                        File(path).inputStream().use { it.copyTo(out) }
                    }
                    resolver.update(
                        uri,
                        ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                        null,
                        null,
                    )
                } catch (e: Exception) {
                    // Leave nothing half-written behind.
                    resolver.delete(uri, null, null)
                    throw e
                }
                // What it ended up called: Downloads renames a clash rather
                // than overwriting, so this may not be the name asked for.
                val saved = resolver.query(
                    uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null
                )?.use { if (it.moveToFirst()) it.getString(0) else null } ?: name
                main.post { result.success(mapOf("status" to "saved", "where" to saved)) }
            } catch (e: Exception) {
                main.post { result.error("save", e.message ?: e.toString(), null) }
            }
        }.start()
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
