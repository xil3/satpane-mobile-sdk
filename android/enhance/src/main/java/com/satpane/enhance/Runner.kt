package com.satpane.enhance

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min

internal const val TILE = 512
internal const val SCALE = 4

/** Runs the x4 model (ONNX Runtime; XNNPACK on the CPU when [xnnpack] and available) on one region of a
 *  zoom-13 tile. */
internal class Runner(modelFile: File, xnnpack: Boolean) : Closeable {
  private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
  private val session: OrtSession
  val backend: String

  init {
    val opts = OrtSession.SessionOptions()
    opts.setIntraOpNumThreads(max(1, min(4, Runtime.getRuntime().availableProcessors() - 1)))
    backend = if (!xnnpack) "cpu" else try {
      opts.addXnnpack(mapOf("intra_op_num_threads" to "4"))
      "xnnpack"
    } catch (e: Throwable) {
      "cpu"
    }
    session = env.createSession(modelFile.absolutePath, opts)
  }

  /**
   * Enhances the square (rx, ry, rs) of the centre tile (tiles[4]; tiles are the zoom-13 tile and its 8
   * neighbours row by row, null where there's no imagery) with a border of [pad] neighbour pixels against
   * seams, and writes each of [outs] (a square of the rs*4 px result, at its outSize) to its file.
   */
  fun enhance(tiles: List<File?>, rx: Int, ry: Int, rs: Int, pad: Int, outs: List<Pair<Planner.Out, File>>) {
    val px = tiles.map { f -> f?.let(::decode) }
    val center = px.getOrNull(4) ?: throw IllegalStateException("no source tile")

    // Input: the region plus a border, from the neighbours where they have imagery, else mirrored.
    val w = rs + 2 * pad
    val plane = w * w
    val input = FloatArray(3 * plane)
    for (r in 0 until w) {
      for (c in 0 until w) {
        val p = pixelAt(px, center, rx - pad + c, ry - pad + r)
        val i = r * w + c
        input[i] = ((p shr 16) and 0xff) / 255f
        input[plane + i] = ((p shr 8) and 0xff) / 255f
        input[2 * plane + i] = (p and 0xff) / 255f
      }
    }
    val out: FloatArray = OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, 3, w.toLong(), w.toLong())).use { tensor ->
      session.run(mapOf(session.inputNames.first() to tensor)).use { result ->
        val buf = (result.get(0) as OnnxTensor).floatBuffer
        FloatArray(buf.remaining()).also { buf.get(it) }
      }
    }

    // Crop the border off; transparency comes from the source (nearest pixel).
    val ow = w * SCALE
    val oplane = ow * ow
    val size = rs * SCALE
    val off = pad * SCALE
    val pixels = IntArray(size * size)
    var transparent = false
    for (r in 0 until size) {
      val sy = ry + r / SCALE
      for (c in 0 until size) {
        val sx = rx + c / SCALE
        if ((center[sy * TILE + sx] ushr 24) == 0) {
          transparent = true
          continue
        }
        val k = (r + off) * ow + (c + off)
        pixels[r * size + c] = (0xff shl 24) or (clamp(out[k]) shl 16) or (clamp(out[oplane + k]) shl 8) or clamp(out[2 * oplane + k])
      }
    }
    val full = Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
    try {
      for ((t, file) in outs) {
        var bmp = if (t.x == 0 && t.y == 0 && t.size == size) full else Bitmap.createBitmap(full, t.x, t.y, t.size, t.size)
        if (t.size != t.outSize) {
          val scaled = Bitmap.createScaledBitmap(bmp, t.outSize, t.outSize, true)
          if (bmp !== full) bmp.recycle()
          bmp = scaled
        }
        file.parentFile?.mkdirs()
        // Write to a temporary name, then rename: the map never reads a half-written tile.
        val tmp = File(file.parentFile, file.name + ".part")
        FileOutputStream(tmp).use { s ->
          if (transparent) bmp.compress(Bitmap.CompressFormat.PNG, 100, s) else bmp.compress(Bitmap.CompressFormat.JPEG, 90, s)
        }
        if (bmp !== full) bmp.recycle()
        if (!tmp.renameTo(file)) {
          tmp.copyTo(file, overwrite = true)
          tmp.delete()
        }
      }
    } finally {
      full.recycle()
    }
  }

  override fun close() = session.close()

  private fun decode(f: File): IntArray? {
    val bmp = BitmapFactory.decodeFile(f.absolutePath) ?: return null
    try {
      if (bmp.width != TILE || bmp.height != TILE) return null
      return IntArray(TILE * TILE).also { bmp.getPixels(it, 0, TILE, 0, 0, TILE, TILE) }
    } finally {
      bmp.recycle()
    }
  }
}

/** The pixel at (x, y) in the centre tile's coordinates: a neighbour's outside 0..511, else mirrored. */
internal fun pixelAt(tiles: List<IntArray?>, center: IntArray, x: Int, y: Int): Int {
  var dx = 0; var dy = 0; var sx = x; var sy = y
  if (sx < 0) { dx = -1; sx += TILE } else if (sx >= TILE) { dx = 1; sx -= TILE }
  if (sy < 0) { dy = -1; sy += TILE } else if (sy >= TILE) { dy = 1; sy -= TILE }
  tiles.getOrNull((dy + 1) * 3 + (dx + 1))?.let { t ->
    val p = t[sy * TILE + sx]
    if ((p ushr 24) != 0) return p
  }
  return center[mirror(y) * TILE + mirror(x)]
}

internal fun mirror(v: Int): Int = when {
  v < 0 -> min(TILE - 1, -v)
  v >= TILE -> max(0, 2 * TILE - v - 1)
  else -> v
}

private fun clamp(v: Float): Int = (v * 255f + 0.5f).toInt().coerceIn(0, 255)
