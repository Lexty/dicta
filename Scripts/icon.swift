// Cut the squircle out of a generated icon image and lay it out on macOS's own icon grid.
//
// The source is an image of an icon rather than an icon: a rounded square sitting on a flat light
// background, which is what an image generator produces and what macOS cannot use. Two things have
// to happen to it, and both are measurements rather than guesses:
//
//   * the background has to become transparent, or the icon shows as a light square in every list
//     macOS puts it in — and it has to be cut on the squircle's OWN outline, since a hand-drawn
//     rounded rectangle would not match the continuous curvature the generator drew;
//   * the artwork has to be inset to Apple's grid — 824 points of content on a 1024 canvas — or the
//     icon renders visibly larger than every neighbour in Finder and in System Settings.
//
// The outline is read off the pixels: the body is near-black (~29) and the background near-white
// (~230), so a luma threshold halfway between them finds, for each row, the first and last pixel of
// the body. The shape is convex, so those two columns bound the row completely, and the resulting
// mask IS the drawn outline rather than an approximation of it. Everything outside is set to a
// fully transparent zero — transparent BLACK, not transparent white, because the buffer is
// premultiplied and a stray colour there would bleed back in when the image is scaled down.
//
// The mask is deliberately hard-edged, and the anti-aliasing comes from the downscale: the body is
// 1143 px across and the largest thing written out is 824, so every edge pixel is an average of
// several source pixels. Cutting a soft edge first and then scaling would blend the background's
// own light halo back into the result.
//
// Usage: icon <source.png> <output-dir>   writes AppIcon.iconset/*.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Apple's grid: on a 1024 canvas a rounded-square icon occupies 824, centred.
let contentRatio = 824.0 / 1024.0

/// Halfway between the body (~29) and the background (~230). The transition is four pixels wide and
/// carries a light halo at 244, so the threshold has to sit below it or the halo reads as body.
let bodyThreshold = 140

/// (point size, pixel size) for every representation `iconutil` expects.
let representations: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("usage: icon <source.png> <output-dir>") }
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDir = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("could not read \(sourceURL.path)")
}

let width = image.width, height = image.height
guard width == height else { fail("the source must be square, got \(width)x\(height)") }

// Redraw into a buffer of known layout: the source's own colour space and bit depth are whatever
// the generator chose, and the mask below indexes bytes directly.
let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4, space: colourSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create the working context")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func luma(_ x: Int, _ y: Int) -> Int {
    let i = (y * width + x) * 4
    return (299 * Int(pixels[i]) + 587 * Int(pixels[i + 1]) + 114 * Int(pixels[i + 2])) / 1000
}

// One span per row: the first and last body pixel. A row with no body pixel at all is outside the
// shape entirely, which is what the corners are.
var spans = [(Int, Int)?](repeating: nil, count: height)
var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    var first = -1, last = -1
    for x in 0..<width where luma(x, y) < bodyThreshold {
        if first < 0 { first = x }
        last = x
    }
    guard first >= 0 else { continue }
    spans[y] = (first, last)
    minX = min(minX, first); maxX = max(maxX, last)
    minY = min(minY, y); maxY = max(maxY, y)
}
guard maxX >= minX, maxY >= minY else { fail("found no icon body in the source") }

// A shape that reaches the edge of the source means the icon was exported without its background,
// and this whole cut is then wrong rather than unnecessary — say so instead of writing a bad icon.
guard minX > 0, minY > 0, maxX < width - 1, maxY < height - 1 else {
    fail("the body touches the source edge — this expects an icon drawn on a background")
}

for y in 0..<height {
    for x in 0..<width {
        let inside = spans[y].map { x >= $0.0 && x <= $0.1 } ?? false
        let i = (y * width + x) * 4
        if inside {
            pixels[i + 3] = 255
        } else {
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        }
    }
}

let bodyWidth = maxX - minX + 1, bodyHeight = maxY - minY + 1
print("icon: body \(bodyWidth)x\(bodyHeight) at (\(minX),\(minY)) in a \(width)x\(height) source")

let data = Data(pixels)
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
guard let provider = CGDataProvider(data: data as CFData),
      let masked = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: colourSpace, bitmapInfo: bitmapInfo,
                           provider: provider, decode: nil, shouldInterpolate: true,
                           intent: .defaultIntent),
      // Y is flipped between the buffer's rows and Core Graphics' coordinates; the crop is
      // symmetric here in both axes, but do not rely on that if the source ever stops being one.
      let body = masked.cropping(to: CGRect(x: minX, y: height - maxY - 1,
                                            width: bodyWidth, height: bodyHeight)) else {
    fail("could not build the masked image")
}

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (name, size) in representations {
    let content = (Double(size) * contentRatio).rounded()
    let inset = (Double(size) - content) / 2
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: colourSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create a \(size)x\(size) context")
    }
    ctx.interpolationQuality = .high
    ctx.draw(body, in: CGRect(x: inset, y: inset, width: content, height: content))
    guard let out = ctx.makeImage() else { fail("could not render \(name)") }
    let url = outputDir.appendingPathComponent("\(name).png")
    let png = UTType.png.identifier as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, png, 1, nil) else {
        fail("could not write \(url.path)")
    }
    CGImageDestinationAddImage(dest, out, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not finalize \(url.path)") }
}

print("icon: wrote \(representations.count) representations to \(outputDir.path)")
