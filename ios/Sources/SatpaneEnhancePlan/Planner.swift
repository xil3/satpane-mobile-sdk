import Foundation

/// What to enhance when (pure, unit-tested). Work comes in zoom-14 areas ("units"): one model run on a
/// quarter of a zoom-13 tile makes the zoom-14 tile and its four zoom-15 tiles.
public enum Planner {
  /// Zoom-14 areas enhanced for what's on screen, at most (nearest the centre first).
  public static let perView = 9
  /// Stopped between this and 13.5: prepare the middle 2x2 areas for a likely zoom in.
  public static let prefetchFrom = 12.5
  /// Stopped at zoom 13.5+: after the visible areas, this many around them for panning.
  public static let ring = 8

  /// A zoom-14 area. prio: 0 on screen, 1 where a zoom-in is heading, 2 likely next.
  public struct Unit: Hashable {
    public let x: Int
    public let y: Int
    public var prio: Int
    public init(x: Int, y: Int, prio: Int = 0) { self.x = x; self.y = y; self.prio = prio }
  }

  public struct Tile: Hashable {
    public let z: Int
    public let x: Int
    public let y: Int
  }

  /// One tile to write from a unit's 1024 px result: a square (x, y, size) of it, saved at outSize.
  public struct Out: Hashable {
    public let x: Int
    public let y: Int
    public let size: Int
    public let z: Int
    public let tx: Int
    public let ty: Int
    public let outSize: Int
  }

  /// West, south, east, north in degrees.
  public struct Bounds: Hashable {
    public let west: Double
    public let south: Double
    public let east: Double
    public let north: Double
    public init(west: Double, south: Double, east: Double, north: Double) {
      self.west = west; self.south = south; self.east = east; self.north = north
    }
  }

  /// The five tiles one unit makes: zoom 14 (the whole 1024 px result, scaled) and zoom 15 (quarters).
  public static func unitOutputs(_ u: Unit) -> [Out] {
    var outs = [Out(x: 0, y: 0, size: 1024, z: 14, tx: u.x, ty: u.y, outSize: 512)]
    for j in 0..<2 {
      for i in 0..<2 {
        outs.append(Out(x: i * 512, y: j * 512, size: 512, z: 15, tx: 2 * u.x + i, ty: 2 * u.y + j, outSize: 512))
      }
    }
    return outs
  }

  static func centerTile(_ b: Bounds, _ z: Int) -> Tile {
    let lon = (b.west + b.east) / 2, lat = (b.south + b.north) / 2
    return visibleTiles(Bounds(west: lon, south: lat, east: lon, north: lat), z)[0]
  }

  /// The zoom-14 area under the middle of the view.
  public static func centerUnit(_ b: Bounds, prio: Int = 0) -> Unit {
    let t = centerTile(b, 14)
    return Unit(x: t.x, y: t.y, prio: prio)
  }

  /// What to enhance after the camera stops, in order: at zoom 13.5+ the areas on screen (prio 0), then a
  /// ring around them for panning (prio 2); between 12.5 and 13.5 the middle 2x2 areas, for a likely zoom
  /// in (prio 2); further out, nothing.
  public static func planView(_ b: Bounds, zoom: Double) -> [Unit] {
    if zoom < prefetchFrom { return [] }
    if zoom < 13.5 {
      let c = centerUnit(b)
      let mid = centerTile(b, 15)
      let dx = mid.x % 2 != 0 ? 1 : -1, dy = mid.y % 2 != 0 ? 1 : -1
      return [c, Unit(x: c.x + dx, y: c.y), Unit(x: c.x, y: c.y + dy), Unit(x: c.x + dx, y: c.y + dy)]
        .map { Unit(x: $0.x, y: $0.y, prio: 2) }
    }
    let onScreen = visibleTiles(b, 14).prefix(perView).map { Unit(x: $0.x, y: $0.y, prio: 0) }
    let seen = Set(onScreen.map { [$0.x, $0.y] })
    let x0 = onScreen.map(\.x).min()! - 1, x1 = onScreen.map(\.x).max()! + 1
    let y0 = onScreen.map(\.y).min()! - 1, y1 = onScreen.map(\.y).max()! + 1
    let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
    var around: [Unit] = []
    for x in x0...x1 { for y in y0...y1 where !seen.contains([x, y]) { around.append(Unit(x: x, y: y, prio: 2)) } }
    around.sort { pow(Double($0.x) - cx, 2) + pow(Double($0.y) - cy, 2) < pow(Double($1.x) - cx, 2) + pow(Double($1.y) - cy, 2) }
    return Array(onScreen) + around.prefix(ring)
  }

  /// Tiles at zoom z covering the bounds, nearest the centre first.
  public static func visibleTiles(_ b: Bounds, _ z: Int) -> [Tile] {
    let n = pow(2.0, Double(z))
    func fx(_ lon: Double) -> Double { (lon + 180) / 360 * n }
    func fy(_ lat: Double) -> Double { (1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * n }
    let x0 = Int(floor(fx(b.west))), x1 = Int(floor(fx(b.east)))
    let y0 = Int(floor(fy(b.north))), y1 = Int(floor(fy(b.south)))
    let cx = (fx(b.west) + fx(b.east)) / 2 - 0.5, cy = (fy(b.north) + fy(b.south)) / 2 - 0.5
    let last = Int(n) - 1
    var tiles: [Tile] = []
    if max(0, x0) <= min(last, x1) && max(0, y0) <= min(last, y1) {
      for x in max(0, x0)...min(last, x1) { for y in max(0, y0)...min(last, y1) { tiles.append(Tile(z: z, x: x, y: y)) } }
    }
    func d(_ t: Tile) -> Double { pow(Double(t.x) - cx, 2) + pow(Double(t.y) - cy, 2) }
    // Stable, like the JS/Kotlin versions (ties keep column order).
    return tiles.enumerated().sorted { d($0.element) != d($1.element) ? d($0.element) < d($1.element) : $0.offset < $1.offset }.map(\.element)
  }
}
