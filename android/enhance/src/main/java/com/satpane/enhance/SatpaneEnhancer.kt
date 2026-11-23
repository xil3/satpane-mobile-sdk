package com.satpane.enhance

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Executors

/**
 * Sharper Satpane satellite imagery close up (AI super-resolution, beta), made on the device.
 *
 * Off until the user turns it on ([setEnabled]; the choice is saved). When on and the key's plan
 * includes it, the model (~1.3 MB) is downloaded once per version, and as the camera moves
 * ([onCamera]) the zoom-14 and zoom-15 tiles in view are enhanced from Satpane's zoom-13 tiles and
 * written as files. Draw them over your normal satellite layer with a raster source using
 * [State.tileUrl] (a file:// template): tiles not made yet are simply missing, so the normal
 * imagery shows through.
 *
 * Listener callbacks arrive on the main thread. Everything else (network, model, files) runs on one
 * background thread.
 */
class SatpaneEnhancer(context: Context, val config: Config) : Closeable {

  data class Config(
    /** Your Satpane API key (restrict it to your app in the Satpane dashboard). */
    val key: String,
    val api: String = "https://api.satpane.com",
    val layer: String = "true-color",
    /** "latest" or a mosaic like "2026-09". */
    val period: String = "latest",
    /** The model to use: the 8-bit one runs best on phone CPUs. */
    val model: String = "enhance-x4-int8",
    /** Report [State.slow] when tiles average more than this many ms. */
    val slowMs: Long = 3000,
    /** Enhanced tiles kept on the device, at most (oldest removed first). */
    val maxCacheBytes: Long = 300L * 1024 * 1024,
  )

  data class State(
    /** Offer the switch: the key's plan includes enhancement and a model is published. */
    val available: Boolean = false,
    /** The user's choice. */
    val enabled: Boolean = false,
    /** file:// tile template ({z}/{x}/{y}) for the enhanced layer, or null when off or not ready.
     *  It changes (harmlessly) whenever new tiles are written, so maps notice and redraw. */
    val tileUrl: String? = null,
    /** Where the model runs ("xnnpack" or "cpu"), once loaded. */
    val backend: String? = null,
    /** Enhancing is slow on this device: a good moment to suggest turning it off. */
    val slow: Boolean = false,
    /** Something to show under the switch (not in the plan, couldn't download), or null. */
    val message: String? = null,
  )

  fun interface Listener {
    fun onState(state: State)
  }

  /** Called with how many zoom-13 tiles were downloaded to feed the model (they count as tile requests). */
  var onSourceTiles: ((count: Int) -> Unit)? = null

  private val app = context.applicationContext
  private val prefs: SharedPreferences = app.getSharedPreferences("satpane-enhance", Context.MODE_PRIVATE)
  private val modelDir = File(app.filesDir, "satpane-enhance")
  private val root = File(app.cacheDir, "satpane-enhance")
  private val main = Handler(Looper.getMainLooper())
  private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "satpane-enhance").apply { priority = Thread.NORM_PRIORITY - 1 } }
  private val listeners = mutableListOf<Listener>()
  private val lock = Any()

  // Guarded by lock.
  private var state = State(enabled = prefs.getBoolean(PREF_ENABLED, false))
  private var queue = mutableListOf<Planner.Unit>()
  private var working = false
  private var lastView: Pair<Planner.Bounds, Double>? = null
  private var lastZoom: Pair<Double, Long>? = null

  // Worker thread only.
  private var runner: Runner? = null
  private var version: String? = null
  private val done = HashSet<String>()
  private val times = ArrayDeque<Long>()
  private var gen = 0
  private var bumpPending = false
  private var written = 0
  private var closed = false

  init {
    worker.execute { prepare() }
  }

  val current: State get() = synchronized(lock) { state }

  fun addListener(l: Listener) {
    synchronized(lock) { listeners += l }
    val s = current
    main.post { l.onState(s) }
  }

  fun removeListener(l: Listener) = synchronized(lock) { listeners -= l }

  /** Turns enhancement on or off (saved for next time). Off stops all work; tiles already made are kept
   *  for a quick restart (see [clearCache]). */
  fun setEnabled(on: Boolean) {
    prefs.edit().putBoolean(PREF_ENABLED, on).apply()
    synchronized(lock) { if (!on) queue.clear() }
    update { it.copy(enabled = on, slow = false, message = null, tileUrl = if (on) it.tileUrl else null) }
    worker.execute {
      times.clear()
      prepare()
    }
  }

  /** Asks Satpane again whether the key may use the model (normally every few days on its own). */
  fun refresh() {
    prefs.edit().remove(PREF_CHECK).apply()
    worker.execute { prepare() }
  }

  /**
   * The camera: bounds in degrees and the map's zoom. Call while it moves (moving = true; zooming in past
   * 12.5 starts on the middle of the view, where a pinch usually ends up) and when it stops.
   */
  fun onCamera(west: Double, south: Double, east: Double, north: Double, zoom: Double, moving: Boolean = false) {
    val b = Planner.Bounds(west, south, east, north)
    val now = System.currentTimeMillis()
    synchronized(lock) {
      if (moving) {
        val prev = lastZoom
        if (prev != null && zoom > prev.first + 0.02 && zoom >= Planner.PREFETCH_FROM) {
          val t = Planner.centerUnit(b, prio = 1)
          if (queue.none { it.x == t.x && it.y == t.y }) queue.add(0, t)
        }
        if (prev == null || now - prev.second > 250 || zoom < prev.first) lastZoom = zoom to now
      } else {
        lastZoom = null
        lastView = b to zoom
        planLocked()
      }
    }
    kick()
  }

  /** Deletes enhanced tiles and the downloaded source tiles (the model is kept). */
  fun clearCache() {
    worker.execute {
      root.deleteRecursively()
      done.clear()
      bump()
    }
  }

  override fun close() {
    worker.execute {
      closed = true
      runner?.close()
      runner = null
    }
    worker.shutdown()
  }

  // ---- worker side ----

  /** Checks the plan, downloads and loads the model when on. */
  private fun prepare() {
    if (closed) return
    val check = try {
      modelCheck()
    } catch (e: Exception) {
      update { it.copy(message = if (it.enabled) "Sharper satellite couldn't start (check your signal)." else null) }
      return
    }
    if (!check.ok) {
      // No longer in the plan (or no model): stop and remove what it made.
      runner?.close()
      runner = null
      version = null
      if (check.denied) {
        modelDir.deleteRecursively()
        root.deleteRecursively()
      }
      update { it.copy(available = false, tileUrl = null, backend = null, message = if (it.enabled) check.message else null) }
      return
    }
    update { it.copy(available = true) }
    if (!current.enabled) return
    try {
      if (runner == null || version != check.version) {
        val file = modelFile(check.url!!, check.version!!)
        runner?.close()
        runner = Runner(file)
        version = check.version
        done.clear()
      }
      update { it.copy(backend = runner?.backend, message = null, tileUrl = tileUrl()) }
      synchronized(lock) { planLocked() }
      work()
    } catch (e: Exception) {
      update { it.copy(message = "Sharper satellite couldn't start (check your signal).") }
    }
  }

  private fun planLocked() {
    val (b, zoom) = lastView ?: return
    val predicted = queue.filter { it.prio == 1 }
    val taken = predicted.map { it.x to it.y }.toSet()
    queue = (predicted + Planner.planView(b, zoom).filter { (it.x to it.y) !in taken }).toMutableList()
  }

  private fun kick() {
    val start = synchronized(lock) {
      if (working || queue.isEmpty() || !state.enabled || !state.available) false else { working = true; true }
    }
    if (start) worker.execute { try { work() } finally { synchronized(lock) { working = false } } }
  }

  private fun work() {
    while (!closed) {
      val r = runner ?: return
      val v = version ?: return
      val u = synchronized(lock) {
        if (!state.enabled) null else queue.sortedBy { it.prio }.firstOrNull()?.also { queue.remove(it) }
      } ?: return
      val key = "$v/${u.x}/${u.y}"
      if (key in done) continue
      val outs = Planner.unitOutputs(u).map { it to tileFile(v, it.z, it.tx, it.ty) }
      if (outs.all { it.second.exists() }) {
        done += key
        continue
      }
      try {
        val tiles = sourceTiles(u.x shr 1, u.y shr 1)
        if (tiles[4] == null) {
          done += key // no imagery here
          continue
        }
        val t0 = System.nanoTime()
        r.enhance(tiles, (u.x % 2) * 256, (u.y % 2) * 256, 256, PAD, outs)
        done += key
        written++
        noteTime((System.nanoTime() - t0) / 1_000_000 / outs.size)
        if (written % 40 == 0) trimCache()
        bump()
      } catch (e: IOException) {
        return // no signal: the next camera change tries again
      } catch (e: Exception) {
        done += key // an odd tile: skip it
      }
    }
  }

  private fun noteTime(ms: Long) {
    times.addLast(ms)
    if (times.size > 6) times.removeFirst()
    if (times.size >= 3 && times.average() > config.slowMs && !current.slow) update { it.copy(slow = true) }
  }

  /** New tiles: tell the map (at most twice a second) with a fresh tileUrl. */
  private fun bump() {
    if (bumpPending) return
    bumpPending = true
    main.postDelayed({
      worker.execute {
        bumpPending = false
        gen++
        if (version != null) update { it.copy(tileUrl = if (it.enabled && it.available) tileUrl() else null) }
      }
    }, 500)
  }

  /** "/." (same folder) alternates with nothing, so the URL changes but the files don't move. */
  private fun tileUrl(): String = "file://${File(root, "out/m$version").absolutePath}${if (gen % 2 == 1) "/." else ""}/{z}/{x}/{y}.tile"

  private fun tileFile(v: String, z: Int, x: Int, y: Int) = File(root, "out/m$v/$z/$x/$y.tile")

  /** The zoom-13 tile (x, y) and its 8 neighbours as files (null where there's no imagery). */
  private fun sourceTiles(x: Int, y: Int): List<File?> {
    val out = ArrayList<File?>(9)
    var fetched = 0
    try {
      for (dy in -1..1) for (dx in -1..1) {
        val tx = x + dx
        val ty = y + dy
        val file = File(root, "src/${config.layer}/${config.period}/13/$tx/$ty.webp")
        val none = File(file.path + ".none")
        when {
          file.exists() -> out += file
          none.exists() -> out += null
          else -> {
            fetched++
            val url = "${config.api}/v1/tiles/${enc(config.layer)}/${enc(config.period)}/13/$tx/$ty.webp?key=${enc(config.key)}&enhance=1"
            when (download(url, file)) {
              200 -> out += file
              204, 404 -> { none.parentFile?.mkdirs(); none.writeText(""); out += null }
              else -> throw IOException("tile HTTP error")
            }
          }
        }
      }
    } finally {
      if (fetched > 0) onSourceTiles?.let { cb -> main.post { cb(fetched) } }
    }
    return out
  }

  /** Keeps the enhanced tiles under maxCacheBytes, oldest first. */
  private fun trimCache() {
    val files = File(root, "out").walkTopDown().filter { it.isFile }.toList()
    var total = files.sumOf { it.length() }
    if (total <= config.maxCacheBytes) return
    for (f in files.sortedBy { it.lastModified() }) {
      if (total <= config.maxCacheBytes * 8 / 10) break
      total -= f.length()
      f.delete()
    }
    done.clear()
  }

  private class Check(val ok: Boolean, val denied: Boolean = false, val version: String? = null, val url: String? = null, val recheckDays: Double = 3.0, val message: String? = null, val at: Long = System.currentTimeMillis())

  /** Whether the key may use the model: asked at most every few days; a recent yes counts while offline. */
  private fun modelCheck(): Check {
    val stored = prefs.getString(PREF_CHECK, null)?.let { s ->
      runCatching {
        val j = JSONObject(s)
        if (j.optString("key") != config.key.takeLast(8) || j.optString("model") != config.model) null
        else Check(j.getBoolean("ok"), j.optBoolean("denied"), j.optString("version").ifEmpty { null }, j.optString("url").ifEmpty { null }, j.optDouble("recheckDays", 3.0), j.optString("message").ifEmpty { null }, j.getLong("at"))
      }.getOrNull()
    }
    val age = stored?.let { System.currentTimeMillis() - it.at } ?: Long.MAX_VALUE
    if (stored != null && stored.ok && age < stored.recheckDays * DAY_MS) return stored
    if (stored != null && !stored.ok && age < NO_RECHECK_MS) return stored
    val fresh = try {
      val conn = URL("${config.api}/v1/models/${enc(config.model)}.json?key=${enc(config.key)}").openConnection() as HttpURLConnection
      conn.connectTimeout = 15_000
      conn.readTimeout = 15_000
      try {
        val code = conn.responseCode
        when {
          code == 200 -> {
            val j = JSONObject(conn.inputStream.bufferedReader().readText())
            Check(true, version = j.get("version").toString(), url = j.getString("url"), recheckDays = j.optDouble("recheckDays", 3.0))
          }
          code == 401 || code == 403 || code == 404 -> {
            val msg = runCatching { JSONObject(conn.errorStream.bufferedReader().readText()).optString("error") }.getOrNull()
            Check(false, denied = code != 404, message = msg?.ifEmpty { null } ?: "Sharper satellite isn't available for this app.")
          }
          else -> throw IOException("HTTP $code")
        }
      } finally {
        conn.disconnect()
      }
    } catch (e: IOException) {
      if (stored != null && stored.ok && age < OFFLINE_GRACE_DAYS * DAY_MS) return stored
      throw e
    }
    prefs.edit().putString(PREF_CHECK, JSONObject().apply {
      put("ok", fresh.ok); put("denied", fresh.denied); put("version", fresh.version ?: ""); put("url", fresh.url ?: "")
      put("recheckDays", fresh.recheckDays); put("message", fresh.message ?: ""); put("at", fresh.at)
      put("key", config.key.takeLast(8)); put("model", config.model)
    }.toString()).apply()
    return fresh
  }

  /** The model file for a version, downloaded once (older versions and their tiles are removed). */
  private fun modelFile(url: String, v: String): File {
    val name = "${config.model}-v$v.onnx"
    val file = File(modelDir, name)
    if (!file.exists()) {
      modelDir.mkdirs()
      if (download("$url?key=${enc(config.key)}", file) != 200) throw IOException("model download failed")
    }
    modelDir.listFiles()?.filter { it.name != name }?.forEach { it.delete() }
    File(root, "out").listFiles()?.filter { it.name != "m$v" }?.forEach { it.deleteRecursively() }
    return file
  }

  /** GET into file (via a .part file); returns the HTTP status. */
  private fun download(url: String, file: File): Int {
    val conn = URL(url).openConnection() as HttpURLConnection
    conn.connectTimeout = 15_000
    conn.readTimeout = 30_000
    try {
      val code = conn.responseCode
      if (code == 200) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".part")
        conn.inputStream.use { input -> tmp.outputStream().use { input.copyTo(it) } }
        if (!tmp.renameTo(file)) throw IOException("couldn't save ${file.name}")
      }
      return code
    } finally {
      conn.disconnect()
    }
  }

  private fun update(f: (State) -> State) {
    val (s, ls) = synchronized(lock) {
      val next = f(state)
      if (next == state) return
      state = next
      next to listeners.toList()
    }
    main.post { ls.forEach { it.onState(s) } }
  }

  private companion object {
    const val PAD = 16
    const val PREF_ENABLED = "enabled"
    const val PREF_CHECK = "check"
    const val DAY_MS = 86_400_000L
    const val NO_RECHECK_MS = 6 * 3_600_000L
    const val OFFLINE_GRACE_DAYS = 14
    fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
  }
}
