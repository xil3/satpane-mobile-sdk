package com.satpane.enhancenative

import com.satpane.enhance.SatpaneEnhancer
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record

class ConfigRecord : Record {
  @Field val key: String = ""
  @Field val api: String? = null
  @Field val layer: String? = null
  @Field val period: String? = null
  @Field val model: String? = null
}

/** React Native bridge over the Satpane Android SDK (one enhancer per app). */
class SatpaneEnhanceModule : Module() {
  private var enhancer: SatpaneEnhancer? = null
  private val listener = SatpaneEnhancer.Listener { s -> sendEvent("onState", s.toMap()) }

  override fun definition() = ModuleDefinition {
    Name("SatpaneEnhance")
    Events("onState", "onSourceTiles")

    Function("configure") { c: ConfigRecord ->
      val defaults = SatpaneEnhancer.Config(key = c.key)
      val cfg = defaults.copy(
        api = c.api ?: defaults.api,
        layer = c.layer ?: defaults.layer,
        period = c.period ?: defaults.period,
        model = c.model ?: defaults.model,
      )
      val e = enhancer
      if (e == null || e.config != cfg) {
        e?.removeListener(listener)
        e?.close()
        val context = appContext.reactContext ?: throw IllegalStateException("no React context")
        enhancer = SatpaneEnhancer(context, cfg).also {
          it.onSourceTiles = { n -> sendEvent("onSourceTiles", mapOf("count" to n)) }
          it.addListener(listener)
        }
      }
      enhancer!!.current.toMap()
    }

    Function("getState") { enhancer?.current?.toMap() }

    Function("setEnabled") { on: Boolean -> enhancer?.setEnabled(on) }

    Function("onCamera") { west: Double, south: Double, east: Double, north: Double, zoom: Double, moving: Boolean ->
      enhancer?.onCamera(west, south, east, north, zoom, moving)
    }

    Function("refresh") { enhancer?.refresh() }

    Function("clearCache") { enhancer?.clearCache() }

    OnDestroy {
      enhancer?.removeListener(listener)
      enhancer?.close()
      enhancer = null
    }
  }
}

private fun SatpaneEnhancer.State.toMap(): Map<String, Any?> = mapOf(
  "available" to available,
  "enabled" to enabled,
  "tileUrl" to tileUrl,
  "backend" to backend,
  "slow" to slow,
  "message" to message,
  "failure" to failure,
)
