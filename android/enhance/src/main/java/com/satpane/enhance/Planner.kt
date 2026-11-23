package com.satpane.enhance

import kotlin.math.PI
import kotlin.math.asinh
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.tan

/**
 * What to enhance when (pure, no Android types, unit-tested). Work comes in zoom-14 areas ("units"): one
 * model run on a quarter of a zoom-13 tile makes the zoom-14 tile and its four zoom-15 tiles.
 */
object Planner {
  /** Zoom-14 areas enhanced for what's on screen, at most (nearest the centre first). */
  const val PER_VIEW = 9
  /** Stopped between this and 13.5: prepare the middle 2x2 areas for a likely zoom in. */
  const val PREFETCH_FROM = 12.5
  /** Stopped at zoom 13.5+: after the visible areas, this many around them for panning. */
  const val RING = 8

  /** A zoom-14 area. prio: 0 on screen, 1 where a zoom-in is heading, 2 likely next. */
  data class Unit(val x: Int, val y: Int, val prio: Int = 0)

  data class Tile(val z: Int, val x: Int, val y: Int)

  /** One tile to write from a unit's 1024 px result: a square (x, y, size) of it, saved at outSize. */
  data class Out(val x: Int, val y: Int, val size: Int, val z: Int, val tx: Int, val ty: Int, val outSize: Int = 512)

  /** Bounds are west, south, east, north in degrees. */
  data class Bounds(val west: Double, val south: Double, val east: Double, val north: Double)

  /** The five tiles one unit makes: zoom 14 (the whole 1024 px result, scaled) and zoom 15 (quarters). */
  fun unitOutputs(u: Unit): List<Out> {
    val outs = mutableListOf(Out(0, 0, 1024, 14, u.x, u.y))
    for (j in 0..1) for (i in 0..1) outs += Out(i * 512, j * 512, 512, 15, 2 * u.x + i, 2 * u.y + j)
    return outs
  }

  private fun centerTile(b: Bounds, z: Int): Tile {
    val lon = (b.west + b.east) / 2
    val lat = (b.south + b.north) / 2
    return visibleTiles(Bounds(lon, lat, lon, lat), z).first()
  }

  /** The zoom-14 area under the middle of the view. */
  fun centerUnit(b: Bounds, prio: Int = 0): Unit = centerTile(b, 14).let { Unit(it.x, it.y, prio) }

  /**
   * What to enhance after the camera stops, in order: at zoom 13.5+ the areas on screen (prio 0), then a
   * ring around them for panning (prio 2); between 12.5 and 13.5 the middle 2x2 areas, for a likely zoom
   * in (prio 2); further out, nothing.
   */
  fun planView(b: Bounds, zoom: Double): List<Unit> {
    if (zoom < PREFETCH_FROM) return emptyList()
    if (zoom < 13.5) {
      val c = centerUnit(b)
      val mid = centerTile(b, 15)
      val dx = if (mid.x % 2 != 0) 1 else -1
      val dy = if (mid.y % 2 != 0) 1 else -1
      return listOf(c, Unit(c.x + dx, c.y), Unit(c.x, c.y + dy), Unit(c.x + dx, c.y + dy)).map { it.copy(prio = 2) }
    }
    val onScreen = visibleTiles(b, 14).take(PER_VIEW).map { Unit(it.x, it.y, 0) }
    val seen = onScreen.map { it.x to it.y }.toSet()
    val x0 = onScreen.minOf { it.x } - 1
    val x1 = onScreen.maxOf { it.x } + 1
    val y0 = onScreen.minOf { it.y } - 1
    val y1 = onScreen.maxOf { it.y } + 1
    val cx = (x0 + x1) / 2.0
    val cy = (y0 + y1) / 2.0
    val ring = mutableListOf<Unit>()
    for (x in x0..x1) for (y in y0..y1) if ((x to y) !in seen) ring += Unit(x, y, 2)
    ring.sortBy { (it.x - cx).pow(2) + (it.y - cy).pow(2) }
    return onScreen + ring.take(RING)
  }

  /** Tiles at zoom z covering the bounds, nearest the centre first. */
  fun visibleTiles(b: Bounds, z: Int): List<Tile> {
    val n = 2.0.pow(z)
    fun fx(lon: Double) = (lon + 180) / 360 * n
    fun fy(lat: Double) = (1 - asinh(tan(lat * PI / 180)) / PI) / 2 * n
    val x0 = floor(fx(b.west)).toInt()
    val x1 = floor(fx(b.east)).toInt()
    val y0 = floor(fy(b.north)).toInt()
    val y1 = floor(fy(b.south)).toInt()
    val cx = (fx(b.west) + fx(b.east)) / 2 - 0.5
    val cy = (fy(b.north) + fy(b.south)) / 2 - 0.5
    val last = n.toInt() - 1
    val tiles = mutableListOf<Tile>()
    for (x in max(0, x0)..min(last, x1)) for (y in max(0, y0)..min(last, y1)) tiles += Tile(z, x, y)
    return tiles.sortedBy { (it.x - cx).pow(2) + (it.y - cy).pow(2) }
  }
}
