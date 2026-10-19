package org.minstrelplayer.minstrel

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URL
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Album art for Android Auto, which shows browse artwork only from
 * content:// URIs: content://org.minstrelplayer.minstrel.art/art?u=<image URL>.
 *
 * Images are fetched from the media servers (on the home network, or through
 * the app's loopback proxy for a paired home), scaled down to at most
 * [MAX_SIDE] pixels and cached. Android Auto decodes every image in a list
 * itself; full-size covers (often 2000 pixels and more) cost it tens of
 * megabytes each. Only those
 * addresses are fetched, and only images, so other apps can't use this to
 * reach anything else.
 */
class AlbumArtProvider : ContentProvider() {
    override fun onCreate() = true

    override fun getType(uri: Uri) = "image/*"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read only")
        val source = uri.getQueryParameter("u") ?: throw FileNotFoundException("no image URL")
        val url = URL(source)
        if (url.protocol != "http" || !isHome(url.host)) throw FileNotFoundException("not a media server")
        val dir = File(context!!.cacheDir, "car-art").apply { mkdirs() }
        val file = File(dir, sha1(source) + "-$MAX_SIDE")
        if (!file.exists()) fetch(url, file, dir)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun fetch(url: URL, file: File, dir: File) {
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 5000
        conn.readTimeout = 10000
        conn.instanceFollowRedirects = false
        try {
            if (conn.responseCode != 200 || conn.contentType?.startsWith("image/") != true) {
                throw FileNotFoundException("no image at $url")
            }
            val tmp = File.createTempFile("art", null, dir)
            conn.inputStream.use { input ->
                tmp.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_BYTES) {
                            tmp.delete()
                            throw FileNotFoundException("image too large")
                        }
                        out.write(buf, 0, n)
                    }
                }
            }
            try {
                if (!shrink(tmp)) throw FileNotFoundException("not an image")
                tmp.renameTo(file)
            } finally {
                tmp.delete()
            }
            trim(dir)
        } finally {
            conn.disconnect()
        }
    }

    /** Scales the image in [f] down to [MAX_SIDE] pixels, as JPEG, in place. */
    private fun shrink(f: File): Boolean {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.path, bounds)
        val side = max(bounds.outWidth, bounds.outHeight)
        if (side <= 0) return false
        // Decode at the smallest power-of-two reduction still at least MAX_SIDE.
        var sample = 1
        while (side / (sample * 2) >= MAX_SIDE) sample *= 2
        val decoded = BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return false
        val scale = MAX_SIDE.toFloat() / max(decoded.width, decoded.height)
        val bitmap = if (scale < 1f) {
            Bitmap.createScaledBitmap(decoded, (decoded.width * scale).roundToInt(), (decoded.height * scale).roundToInt(), true)
                .also { decoded.recycle() }
        } else {
            decoded
        }
        val out = File(f.path + ".jpg")
        out.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        bitmap.recycle()
        return out.renameTo(f)
    }

    /** Loopback (the app's proxy for paired homes) or a private IPv4 address. */
    private fun isHome(host: String): Boolean {
        if (!host.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))) return false
        val addr = InetAddress.getByName(host) as? Inet4Address ?: return false
        return addr.isLoopbackAddress || addr.isSiteLocalAddress || addr.isLinkLocalAddress
    }

    /** Keeps the cache to the most recent images. */
    private fun trim(dir: File) {
        // Full-size images cached by earlier versions.
        dir.listFiles { f -> !f.name.endsWith("-$MAX_SIDE") && !f.name.startsWith("art") }?.forEach { it.delete() }
        val files = dir.listFiles() ?: return
        if (files.size <= MAX_FILES) return
        files.sortedBy { it.lastModified() }.take(files.size - MAX_FILES).forEach { it.delete() }
    }

    private fun sha1(s: String) =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    override fun query(uri: Uri, p: Array<String>?, s: String?, a: Array<String>?, o: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<String>?) = 0

    companion object {
        private const val MAX_BYTES = 4 * 1024 * 1024
        private const val MAX_FILES = 300
        private const val MAX_SIDE = 512
    }
}
