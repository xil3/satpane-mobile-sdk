import Foundation
#if canImport(SatpaneEnhancePlan)
@_exported import SatpaneEnhancePlan
#endif

/// Sharper Satpane satellite imagery close up (AI super-resolution, beta), made on the device.
///
/// Off until the user turns it on (`setEnabled`; the choice is saved). When on and the key's plan
/// includes it, the model (~1.3 MB) is downloaded once per version, and as the camera moves
/// (`onCamera`) the zoom-14 and zoom-15 tiles in view are enhanced from Satpane's zoom-13 tiles and
/// written as files. Draw them over your normal satellite layer with a raster source using
/// `State.tileURL` (a file:// template): tiles not made yet are simply missing, so the normal imagery
/// shows through.
///
/// Listeners are called on the main queue. Network, model and file work run on one background queue.
public final class SatpaneEnhancer {
  public struct Config {
    /// Your Satpane API key. Keys in apps can be copied out of them: give this one its own monthly limit in the dashboard.
    public var key: String
    public var api = "https://api.satpane.com"
    public var layer = "true-color"
    /// "latest" or a mosaic like "2026-09".
    public var period = "latest"
    /// The model to use: the Core ML version (runs on the Neural Engine / GPU).
    public var model = "enhance-x4-coreml"
    /// Report `State.slow` when tiles average more than this many ms.
    public var slowMs: Double = 3000
    /// Enhanced tiles kept on the device, at most (oldest removed first).
    public var maxCacheBytes: Int64 = 300 * 1024 * 1024
    public init(key: String) { self.key = key }
  }

  public struct State: Equatable {
    /// Offer the switch: the key's plan includes enhancement and a model is published.
    public var available = false
    /// The user's choice.
    public var enabled = false
    /// file:// tile template ({z}/{x}/{y}) for the enhanced layer, or nil when off or not ready. It
    /// changes (harmlessly) whenever new tiles are written, so maps notice and redraw.
    public var tileURL: String?
    /// Where the model runs ("coreml"), once loaded.
    public var backend: String?
    /// Enhancing is slow on this device: a good moment to suggest turning it off.
    public var slow = false
    /// Something to show under the switch (not in the plan, couldn't download), or nil.
    public var message: String?
  }

  public let config: Config
  /// Called (main queue) with how many zoom-13 tiles were downloaded to feed the model (they count as
  /// tile requests).
  public var onSourceTiles: ((Int) -> Void)?

  private let defaults = UserDefaults.standard
  private let modelDir: URL
  private let root: URL
  private let worker = DispatchQueue(label: "com.satpane.enhance", qos: .utility)
  private let lock = NSLock()
  private var listeners: [UUID: (State) -> Void] = [:]

  // Guarded by lock.
  private var state: State
  private var queue: [Planner.Unit] = []
  private var working = false
  private var lastView: (Planner.Bounds, Double)?
  private var lastZoom: (Double, Date)?

  // Worker queue only.
  private var runner: Runner?
  private var version: String?
  private var done = Set<String>()
  private var times: [Double] = []
  private var gen = 0
  private var bumpPending = false
  private var written = 0

  private static let prefEnabled = "satpane-enhance.enabled"
  private static let prefCheck = "satpane-enhance.check"
  private static let pad = 16
  private static let day: TimeInterval = 86_400
  private static let noRecheck: TimeInterval = 6 * 3600
  private static let offlineGraceDays = 14.0

  public init(config: Config) {
    self.config = config
    let fm = FileManager.default
    modelDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("satpane-enhance", isDirectory: true)
    root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("satpane-enhance", isDirectory: true)
    state = State(enabled: defaults.bool(forKey: Self.prefEnabled))
    worker.async { self.prepare() }
  }

  public var current: State { lock.locked { state } }

  /// Adds a listener (called right away with the current state). Keep the token to remove it.
  @discardableResult
  public func addListener(_ l: @escaping (State) -> Void) -> UUID {
    let id = UUID()
    lock.locked { listeners[id] = l }
    let s = current
    DispatchQueue.main.async { l(s) }
    return id
  }

  public func removeListener(_ id: UUID) { _ = lock.locked { listeners.removeValue(forKey: id) } }

  /// Turns enhancement on or off (saved for next time). Off stops all work; tiles already made are kept
  /// for a quick restart (see `clearCache`).
  public func setEnabled(_ on: Bool) {
    defaults.set(on, forKey: Self.prefEnabled)
    if !on { lock.locked { queue.removeAll() } }
    update { s in s.enabled = on; s.slow = false; s.message = nil; if !on { s.tileURL = nil } }
    worker.async {
      self.times.removeAll()
      self.prepare()
    }
  }

  /// Asks Satpane again whether the key may use the model (normally every few days on its own).
  public func refresh() {
    defaults.removeObject(forKey: Self.prefCheck)
    worker.async { self.prepare() }
  }

  /// The camera: bounds in degrees and the map's zoom. Call while it moves (moving = true; zooming in past
  /// 12.5 starts on the middle of the view, where a pinch usually ends up) and when it stops.
  public func onCamera(west: Double, south: Double, east: Double, north: Double, zoom: Double, moving: Bool = false) {
    let b = Planner.Bounds(west: west, south: south, east: east, north: north)
    let now = Date()
    lock.locked {
      if moving {
        if let prev = lastZoom, zoom > prev.0 + 0.02, zoom >= Planner.prefetchFrom {
          let t = Planner.centerUnit(b, prio: 1)
          if !queue.contains(where: { $0.x == t.x && $0.y == t.y }) { queue.insert(t, at: 0) }
        }
        if lastZoom == nil || now.timeIntervalSince(lastZoom!.1) > 0.25 || zoom < lastZoom!.0 { lastZoom = (zoom, now) }
      } else {
        lastZoom = nil
        lastView = (b, zoom)
        planLocked()
      }
    }
    kick()
  }

  /// Deletes enhanced tiles and the downloaded source tiles (the model is kept).
  public func clearCache() {
    worker.async {
      try? FileManager.default.removeItem(at: self.root)
      self.done.removeAll()
      self.bump()
    }
  }

  // MARK: - worker side

  private func prepare() {
    let check: Check
    do {
      check = try modelCheck()
    } catch {
      update { s in s.message = s.enabled ? "Sharper satellite couldn't start (check your signal)." : nil }
      return
    }
    guard check.ok, let url = check.url, let v = check.version else {
      runner = nil
      version = nil
      if check.denied {
        try? FileManager.default.removeItem(at: modelDir)
        try? FileManager.default.removeItem(at: root)
      }
      update { s in s.available = false; s.tileURL = nil; s.backend = nil; s.message = s.enabled ? check.message : nil }
      return
    }
    update { $0.available = true }
    guard current.enabled else { return }
    do {
      if runner == nil || version != v {
        runner = try Runner(compiled: try modelFile(url: url, version: v))
        version = v
        done.removeAll()
      }
      let backend = runner?.backend
      let tile = tileURL()
      update { s in s.backend = backend; s.message = nil; s.tileURL = tile }
      lock.locked { planLocked() }
      work()
    } catch {
      update { $0.message = "Sharper satellite couldn't start (check your signal)." }
    }
  }

  private func planLocked() {
    guard let view = lastView else { return }
    let (b, zoom) = view
    let predicted = queue.filter { $0.prio == 1 }
    let taken = Set(predicted.map { [$0.x, $0.y] })
    queue = predicted + Planner.planView(b, zoom: zoom).filter { !taken.contains([$0.x, $0.y]) }
  }

  private func kick() {
    let start: Bool = lock.locked {
      if working || queue.isEmpty || !state.enabled || !state.available { return false }
      working = true
      return true
    }
    if start {
      worker.async {
        self.work()
        self.lock.locked { self.working = false }
      }
    }
  }

  private func work() {
    while true {
      guard let r = runner, let v = version else { return }
      let next: Planner.Unit? = lock.locked {
        guard state.enabled, let i = queue.indices.min(by: { queue[$0].prio < queue[$1].prio }) else { return nil }
        return queue.remove(at: i)
      }
      guard let u = next else { return }
      let key = "\(v)/\(u.x)/\(u.y)"
      if done.contains(key) { continue }
      let outs = Planner.unitOutputs(u).map { ($0, tileFile(v, $0.z, $0.tx, $0.ty)) }
      if outs.allSatisfy({ FileManager.default.fileExists(atPath: $0.1.path) }) { done.insert(key); continue }
      do {
        let tiles = try sourceTiles(u.x >> 1, u.y >> 1)
        if tiles[4] == nil { done.insert(key); continue } // no imagery here
        let t0 = CFAbsoluteTimeGetCurrent()
        try r.enhance(tiles: tiles, rx: (u.x % 2) * 256, ry: (u.y % 2) * 256, rs: 256, pad: Self.pad, outs: outs)
        done.insert(key)
        written += 1
        noteTime((CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(outs.count))
        if written % 40 == 0 { trimCache() }
        bump()
      } catch is URLError {
        return // no signal: the next camera change tries again
      } catch EnhanceError.http(_) {
        return
      } catch {
        done.insert(key) // an odd tile: skip it
      }
    }
  }

  private func noteTime(_ ms: Double) {
    times.append(ms)
    if times.count > 6 { times.removeFirst() }
    if times.count >= 3 && times.reduce(0, +) / Double(times.count) > config.slowMs && !current.slow { update { $0.slow = true } }
  }

  /// New tiles: tell the map (at most twice a second) with a fresh tileURL.
  private func bump() {
    if bumpPending { return }
    bumpPending = true
    worker.asyncAfter(deadline: .now() + 0.5) {
      self.bumpPending = false
      self.gen += 1
      guard self.version != nil else { return }
      let tile = self.tileURL()
      self.update { s in s.tileURL = s.enabled && s.available ? tile : nil }
    }
  }

  /// "/." (same folder) alternates with nothing, so the URL changes but the files don't move.
  private func tileURL() -> String {
    "file://\(root.appendingPathComponent("out/m\(version ?? "0")").path)\(gen % 2 == 1 ? "/." : "")/{z}/{x}/{y}.tile"
  }

  private func tileFile(_ v: String, _ z: Int, _ x: Int, _ y: Int) -> URL {
    root.appendingPathComponent("out/m\(v)/\(z)/\(x)/\(y).tile")
  }

  /// The zoom-13 tile (x, y) and its 8 neighbours as files (nil where there's no imagery).
  private func sourceTiles(_ x: Int, _ y: Int) throws -> [URL?] {
    var out: [URL?] = []
    var fetched = 0
    defer {
      if fetched > 0, let cb = onSourceTiles { let n = fetched; DispatchQueue.main.async { cb(n) } }
    }
    let fm = FileManager.default
    for dy in -1...1 {
      for dx in -1...1 {
        let tx = x + dx, ty = y + dy
        let file = root.appendingPathComponent("src/\(config.layer)/\(config.period)/13/\(tx)/\(ty).webp")
        let none = file.appendingPathExtension("none")
        if fm.fileExists(atPath: file.path) { out.append(file); continue }
        if fm.fileExists(atPath: none.path) { out.append(nil); continue }
        fetched += 1
        let url = "\(config.api)/v1/tiles/\(enc(config.layer))/\(enc(config.period))/13/\(tx)/\(ty).webp?key=\(enc(config.key))&enhance=1"
        switch try download(url, to: file) {
        case 200: out.append(file)
        case 204, 404:
          try fm.createDirectory(at: none.deletingLastPathComponent(), withIntermediateDirectories: true)
          fm.createFile(atPath: none.path, contents: Data())
          out.append(nil)
        case let code: throw EnhanceError.http(code)
        }
      }
    }
    return out
  }

  /// Keeps the enhanced tiles under maxCacheBytes, oldest first.
  private func trimCache() {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
    guard let e = fm.enumerator(at: root.appendingPathComponent("out"), includingPropertiesForKeys: keys) else { return }
    var files: [(URL, Int64, Date)] = []
    for case let u as URL in e {
      guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
      files.append((u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
    }
    var total = files.reduce(Int64(0)) { $0 + $1.1 }
    guard total > config.maxCacheBytes else { return }
    for f in files.sorted(by: { $0.2 < $1.2 }) {
      if total <= config.maxCacheBytes * 8 / 10 { break }
      total -= f.1
      try? fm.removeItem(at: f.0)
    }
    done.removeAll()
  }

  private struct Check: Codable {
    var ok: Bool
    var denied = false
    var version: String?
    var url: String?
    var recheckDays = 3.0
    var message: String?
    var at = Date()
    var key = ""
    var model = ""
  }

  /// Whether the key may use the model: asked at most every few days; a recent yes counts while offline.
  private func modelCheck() throws -> Check {
    let keyTail = String(config.key.suffix(8))
    var stored: Check?
    if let d = defaults.data(forKey: Self.prefCheck), let c = try? JSONDecoder().decode(Check.self, from: d), c.key == keyTail, c.model == config.model {
      stored = c
    }
    let age = stored.map { Date().timeIntervalSince($0.at) } ?? .infinity
    if let s = stored, s.ok, age < s.recheckDays * Self.day { return s }
    if let s = stored, !s.ok, age < Self.noRecheck { return s }
    var fresh: Check
    do {
      let (data, code) = try get("\(config.api)/v1/models/\(enc(config.model)).json?key=\(enc(config.key))")
      let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      switch code {
      case 200:
        guard let url = j["url"] as? String, let v = j["version"] else { throw EnhanceError.model }
        fresh = Check(ok: true, version: "\(v)", url: url, recheckDays: (j["recheckDays"] as? Double) ?? 3)
      case 401, 403, 404:
        fresh = Check(ok: false, denied: code != 404, message: (j["error"] as? String) ?? "Sharper satellite isn't available for this app.")
      default:
        throw EnhanceError.http(code)
      }
    } catch {
      if let s = stored, s.ok, age < Self.offlineGraceDays * Self.day { return s }
      throw error
    }
    fresh.key = keyTail
    fresh.model = config.model
    if let d = try? JSONEncoder().encode(fresh) { defaults.set(d, forKey: Self.prefCheck) }
    return fresh
  }

  /// The compiled model for a version: downloaded and compiled once (older versions and their tiles are
  /// removed).
  private func modelFile(url: String, version v: String) throws -> URL {
    let fm = FileManager.default
    let name = "\(config.model)-v\(v).mlmodelc"
    let compiled = modelDir.appendingPathComponent(name)
    if !fm.fileExists(atPath: compiled.appendingPathComponent("coremldata.bin").path) {
      let raw = fm.temporaryDirectory.appendingPathComponent("\(config.model)-v\(v).mlmodel")
      let code = try download("\(url)?key=\(enc(config.key))", to: raw)
      if code != 200 { throw EnhanceError.http(code) }
      defer { try? fm.removeItem(at: raw) }
      try Runner.compile(raw, to: compiled)
    }
    for f in (try? fm.contentsOfDirectory(atPath: modelDir.path)) ?? [] where f != name {
      try? fm.removeItem(at: modelDir.appendingPathComponent(f))
    }
    let out = root.appendingPathComponent("out")
    for d in (try? fm.contentsOfDirectory(atPath: out.path)) ?? [] where d != "m\(v)" {
      try? fm.removeItem(at: out.appendingPathComponent(d))
    }
    return compiled
  }

  // MARK: - HTTP (blocking; worker queue only)

  private func get(_ url: String) throws -> (Data, Int) {
    guard let u = URL(string: url) else { throw EnhanceError.model }
    var req = URLRequest(url: u, timeoutInterval: 15)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    return try blocking(req)
  }

  /// GET into file (atomically); returns the HTTP status.
  private func download(_ url: String, to file: URL) throws -> Int {
    guard let u = URL(string: url) else { throw EnhanceError.model }
    let (data, code) = try blocking(URLRequest(url: u, timeoutInterval: 30))
    if code == 200 {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file, options: .atomic)
    }
    return code
  }

  private func blocking(_ req: URLRequest) throws -> (Data, Int) {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<(Data, Int), Error> = .failure(URLError(.unknown))
    URLSession.shared.dataTask(with: req) { data, resp, err in
      if let err { result = .failure(err) } else { result = .success((data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0)) }
      sem.signal()
    }.resume()
    sem.wait()
    return try result.get()
  }

  private func update(_ f: (inout State) -> Void) {
    let changed: (State, [(State) -> Void])? = lock.locked {
      var next = state
      f(&next)
      if next == state { return nil }
      state = next
      return (next, Array(listeners.values))
    }
    guard let c = changed else { return }
    let (s, ls) = c
    DispatchQueue.main.async { ls.forEach { $0(s) } }
  }
}

private func enc(_ s: String) -> String {
  s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
}

extension NSLock {
  /// Works on any iOS (NSLock.withLock needs 16).
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
