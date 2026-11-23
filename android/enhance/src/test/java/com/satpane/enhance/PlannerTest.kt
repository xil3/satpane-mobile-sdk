package com.satpane.enhance

import com.satpane.enhance.Planner.Bounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlannerTest {
  // A view over Kanata (Ottawa): about 2 x 2 km at zoom 14.5.
  private val kanata = Bounds(-75.93, 45.3, -75.9, 45.32)

  @Test fun fiveTilesPerUnit() {
    val outs = Planner.unitOutputs(Planner.Unit(10, 20))
    assertEquals(listOf(Triple(14, 10, 20), Triple(15, 20, 40), Triple(15, 21, 40), Triple(15, 20, 41), Triple(15, 21, 41)), outs.map { Triple(it.z, it.tx, it.ty) })
    assertEquals(listOf(0, 0, 1024, 512), outs[0].let { listOf(it.x, it.y, it.size, it.outSize) })
    assertEquals(listOf(listOf(0, 0, 512), listOf(512, 0, 512), listOf(0, 512, 512), listOf(512, 512, 512)), outs.drop(1).map { listOf(it.x, it.y, it.size) })
  }

  @Test fun nothingFarOutAndMiddle2x2Near13() {
    assertTrue(Planner.planView(kanata, 11.0).isEmpty())
    val near = Planner.planView(kanata, 13.0)
    assertEquals(4, near.size)
    assertTrue(near.all { it.prio == 2 })
    val c = Planner.centerUnit(kanata)
    assertEquals(c.x to c.y, near[0].x to near[0].y)
    val xs = near.map { it.x }.toSet()
    val ys = near.map { it.y }.toSet()
    assertEquals(2, xs.size)
    assertEquals(2, ys.size)
    assertTrue(c.x in xs && c.y in ys)
  }

  @Test fun onScreenFirstThenRing() {
    val plan = Planner.planView(kanata, 14.5)
    val first = plan.filter { it.prio == 0 }
    val later = plan.filter { it.prio == 2 }
    assertTrue(first.isNotEmpty() && first.size <= Planner.PER_VIEW)
    val c = Planner.centerUnit(kanata)
    assertEquals(c.x to c.y, first[0].x to first[0].y)
    assertEquals(first.size, plan.indexOf(later[0]))
    assertTrue(later.size <= Planner.RING)
    val onScreen = first.map { it.x to it.y }.toSet()
    for (u in later) assertFalse((u.x to u.y) in onScreen)
    val visible = Planner.visibleTiles(kanata, 14).map { it.x to it.y }.toSet()
    for (u in first) assertTrue((u.x to u.y) in visible)
  }
}
