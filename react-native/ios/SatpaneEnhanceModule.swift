import ExpoModulesCore

struct ConfigRecord: Record {
  @Field var key: String = ""
  @Field var api: String?
  @Field var layer: String?
  @Field var period: String?
  @Field var model: String?
}

/// React Native bridge over the Satpane iOS SDK (one enhancer per app).
public class SatpaneEnhanceModule: Module {
  private var enhancer: SatpaneEnhancer?
  private var listener: UUID?
  private var configKey = ""

  public func definition() -> ModuleDefinition {
    Name("SatpaneEnhance")
    Events("onState", "onSourceTiles")

    Function("configure") { (c: ConfigRecord) -> [String: Any?] in
      var cfg = SatpaneEnhancer.Config(key: c.key)
      if let v = c.api { cfg.api = v }
      if let v = c.layer { cfg.layer = v }
      if let v = c.period { cfg.period = v }
      if let v = c.model { cfg.model = v }
      let k = [cfg.key, cfg.api, cfg.layer, cfg.period, cfg.model].joined(separator: "|")
      if self.enhancer == nil || k != self.configKey {
        if let id = self.listener { self.enhancer?.removeListener(id) }
        let e = SatpaneEnhancer(config: cfg)
        e.onSourceTiles = { [weak self] n in self?.sendEvent("onSourceTiles", ["count": n]) }
        self.listener = e.addListener { [weak self] s in self?.sendEvent("onState", s.toDict()) }
        self.enhancer = e
        self.configKey = k
      }
      return self.enhancer!.current.toDict()
    }

    Function("getState") { () -> [String: Any?]? in self.enhancer?.current.toDict() }

    Function("setEnabled") { (on: Bool) in self.enhancer?.setEnabled(on) }

    Function("onCamera") { (west: Double, south: Double, east: Double, north: Double, zoom: Double, moving: Bool) in
      self.enhancer?.onCamera(west: west, south: south, east: east, north: north, zoom: zoom, moving: moving)
    }

    Function("refresh") { self.enhancer?.refresh() }

    Function("clearCache") { self.enhancer?.clearCache() }
  }
}

private extension SatpaneEnhancer.State {
  func toDict() -> [String: Any?] {
    ["available": available, "enabled": enabled, "tileUrl": tileURL, "backend": backend, "slow": slow, "message": message]
  }
}
