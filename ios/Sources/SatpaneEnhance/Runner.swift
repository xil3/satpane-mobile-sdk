import CoreGraphics
import CoreML
import Foundation
import ImageIO
#if canImport(SatpaneEnhancePlan)
import SatpaneEnhancePlan // the Swift package's planner target; one module elsewhere
#endif
import UniformTypeIdentifiers

let tileSize = 512
let scale = 4
/// The model's fixed input: a 256 px region plus a 16 px border on each side.
let modelInput = 288

/// Runs the x4 model with Core ML (built into iOS: Neural Engine, GPU or CPU, whichever it picks).
final class Runner {
  private let model: MLModel
  private let inName: String
  private let outName: String
  let backend = "coreml"

  /// `compiled` is a compiled model (.mlmodelc), see `Runner.compile`.
  init(compiled: URL) throws {
    let config = MLModelConfiguration()
    config.computeUnits = .all
    model = try MLModel(contentsOf: compiled, configuration: config)
    guard let i = model.modelDescription.inputDescriptionsByName.keys.first,
          let o = model.modelDescription.outputDescriptionsByName.keys.first else { throw EnhanceError.model }
    inName = i
    outName = o
  }

  /// Compiles a downloaded .mlmodel into `dest` (.mlmodelc, a folder), replacing what's there.
  static func compile(_ mlmodel: URL, to dest: URL) throws {
    let tmp = try MLModel.compileModel(at: mlmodel)
    let fm = FileManager.default
    try? fm.removeItem(at: dest)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: tmp, to: dest)
  }

  /// Enhances the square (rx, ry, rs) of the centre tile (tiles[4]; tiles are the zoom-13 tile and its 8
  /// neighbours row by row, nil where there's no imagery) with a border of `pad` neighbour pixels against
  /// seams, and writes each of `outs` (a square of the rs*4 px result, at its outSize) to its file.
  func enhance(tiles: [URL?], rx: Int, ry: Int, rs: Int, pad: Int, outs: [(Planner.Out, URL)]) throws {
    let px: [[UInt8]?] = tiles.map { $0.flatMap(decode) }
    guard px.count == 9, let center = px[4] else { throw EnhanceError.noSource }
    let w = rs + 2 * pad
    guard w == modelInput else { throw EnhanceError.model }

    // Input: the region plus a border, from the neighbours where they have imagery, else mirrored.
    let input = try MLMultiArray(shape: [1, 3, NSNumber(value: w), NSNumber(value: w)], dataType: .float32)
    let plane = w * w
    input.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
      for r in 0..<w {
        for c in 0..<w {
          let p = pixelAt(px, center, rx - pad + c, ry - pad + r)
          let i = r * w + c
          buf[i] = Float(p.0) / 255
          buf[plane + i] = Float(p.1) / 255
          buf[2 * plane + i] = Float(p.2) / 255
        }
      }
    }
    let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: input)]))
    guard let outArray = result.featureValue(for: outName)?.multiArrayValue else { throw EnhanceError.model }
    let ow = w * scale
    let s1 = outArray.strides[1].intValue, s2 = outArray.strides[2].intValue, s3 = outArray.strides[3].intValue
    let out: [Float] = {
      var a = [Float](repeating: 0, count: 3 * ow * ow)
      func fill<T: MLShapedArrayScalar>(_ type: T.Type, _ conv: (T) -> Float) {
        outArray.withUnsafeBufferPointer(ofType: type) { b in
          for ch in 0..<3 { for y in 0..<ow { for x in 0..<ow { a[(ch * ow + y) * ow + x] = conv(b[ch * s1 + y * s2 + x * s3]) } } }
        }
      }
      if outArray.dataType == .float16 { fill(Float16.self) { Float($0) } } else { fill(Float.self) { $0 } }
      return a
    }()

    // Crop the border off; transparency comes from the source (nearest pixel).
    let oplane = ow * ow, size = rs * scale, off = pad * scale
    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    var transparent = false
    for r in 0..<size {
      let sy = ry + r / scale
      for c in 0..<size {
        let sx = rx + c / scale
        if center[(sy * tileSize + sx) * 4 + 3] == 0 { transparent = true; continue }
        let k = (r + off) * ow + (c + off), d = (r * size + c) * 4
        rgba[d] = clamp(out[k]); rgba[d + 1] = clamp(out[oplane + k]); rgba[d + 2] = clamp(out[2 * oplane + k]); rgba[d + 3] = 255
      }
    }
    guard let full = makeImage(&rgba, size) else { throw EnhanceError.image }
    for (t, url) in outs {
      guard let part = full.cropping(to: CGRect(x: t.x, y: t.y, width: t.size, height: t.size)),
            let image = scaled(part, t.outSize) else { throw EnhanceError.image }
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try write(image, to: url, png: transparent)
    }
  }
}

enum EnhanceError: Error {
  case noSource, model, image, http(Int)
}

private func decode(_ url: URL) -> [UInt8]? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
        img.width == tileSize, img.height == tileSize else { return nil }
  var rgba = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
  let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
    guard let ctx = CGContext(data: buf.baseAddress, width: tileSize, height: tileSize, bitsPerComponent: 8, bytesPerRow: tileSize * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
    return true
  }
  return ok ? rgba : nil
}

/// The pixel at (x, y) in the centre tile's coordinates: a neighbour's outside 0..511, else mirrored.
func pixelAt(_ tiles: [[UInt8]?], _ center: [UInt8], _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
  var dx = 0, dy = 0, sx = x, sy = y
  if sx < 0 { dx = -1; sx += tileSize } else if sx >= tileSize { dx = 1; sx -= tileSize }
  if sy < 0 { dy = -1; sy += tileSize } else if sy >= tileSize { dy = 1; sy -= tileSize }
  if let t = tiles[(dy + 1) * 3 + (dx + 1)] {
    let i = (sy * tileSize + sx) * 4
    if t[i + 3] != 0 { return (t[i], t[i + 1], t[i + 2]) }
  }
  let i = (mirror(y) * tileSize + mirror(x)) * 4
  return (center[i], center[i + 1], center[i + 2])
}

func mirror(_ v: Int) -> Int {
  if v < 0 { return min(tileSize - 1, -v) }
  if v >= tileSize { return max(0, 2 * tileSize - v - 1) }
  return v
}

private func clamp(_ v: Float) -> UInt8 { UInt8(max(0, min(255, Int(v * 255 + 0.5)))) }

private func makeImage(_ rgba: inout [UInt8], _ size: Int) -> CGImage? {
  rgba.withUnsafeMutableBytes { buf in
    CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
  }
}

private func scaled(_ image: CGImage, _ outSize: Int) -> CGImage? {
  if image.width == outSize && image.height == outSize { return image }
  guard let ctx = CGContext(data: nil, width: outSize, height: outSize, bitsPerComponent: 8, bytesPerRow: outSize * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  ctx.interpolationQuality = .high
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
  return ctx.makeImage()
}

/// JPEG (PNG where the source has no imagery), written to a temporary file and moved into place, so a
/// map never reads a half-written tile.
private func write(_ image: CGImage, to url: URL, png: Bool) throws {
  let data = NSMutableData()
  let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
  guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw EnhanceError.image }
  CGImageDestinationAddImage(dest, image, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { throw EnhanceError.image }
  try (data as Data).write(to: url, options: .atomic)
}
