// 面板快照的小工具，只给 Scripts/panel-snapshots.sh 用：
//   snaptool winid <pid>         该进程在屏的最大窗口 ID（面板）
//   snaptool png <out>           生成固定图案的测试 PNG（种子数据用）
//   snaptool diff <a> <b> [out]  逐像素比对；不同则打印差异范围、写出标红图并退出 1
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func loadRGBA(_ path: String) -> (width: Int, height: Int, pixels: [UInt8]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    pixels.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, pixels)
}

func writePNG(_ pixels: [UInt8], width: Int, height: Int, to path: String) {
    var copy = pixels
    copy.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "winid":
    guard args.count == 2, let pid = Int32(args[1]) else { fail("usage: snaptool winid <pid>") }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let windows = list.compactMap { info -> (id: Int, area: Double)? in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
              let bounds = info[kCGWindowBounds as String] as? [String: Double],
              let id = info[kCGWindowNumber as String] as? Int else { return nil }
        let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        return area > 200 * 100 ? (id, area) : nil
    }
    guard let panel = windows.max(by: { $0.area < $1.area }) else { exit(1) }
    print(panel.id)

case "png":
    guard args.count == 2 else { fail("usage: snaptool png <out>") }
    let w = 480, h = 300
    var pixels = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let cell = ((x / 40) + (y / 40)) % 2 == 0
            pixels[i] = UInt8(40 + x * 180 / w)
            pixels[i + 1] = cell ? 120 : 200
            pixels[i + 2] = UInt8(220 - y * 160 / h)
        }
    }
    writePNG(pixels, width: w, height: h, to: args[1])

case "diff":
    guard args.count >= 3 else { fail("usage: snaptool diff <a> <b> [out]") }
    let name = URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent
    let a = loadRGBA(args[1]), b = loadRGBA(args[2])
    guard a.width == b.width, a.height == b.height else {
        print("\(name): size \(a.width)x\(a.height) → \(b.width)x\(b.height)")
        exit(1)
    }
    var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var marked = b.pixels
    for y in 0..<a.height {
        for x in 0..<a.width {
            let i = (y * a.width + x) * 4
            let same = a.pixels[i] == b.pixels[i] && a.pixels[i + 1] == b.pixels[i + 1]
                && a.pixels[i + 2] == b.pixels[i + 2] && a.pixels[i + 3] == b.pixels[i + 3]
            if same {
                marked[i + 3] = marked[i + 3] / 4
            } else {
                count += 1
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                marked[i] = 255; marked[i + 1] = 0; marked[i + 2] = 0; marked[i + 3] = 255
            }
        }
    }
    if count == 0 {
        print("\(name): identical")
        exit(0)
    }
    print("\(name): \(count) px differ in x \(minX)…\(maxX), y \(minY)…\(maxY) (pixels, top-left origin)")
    if args.count >= 4 { writePNG(marked, width: a.width, height: a.height, to: args[3]) }
    exit(1)

default:
    fail("usage: snaptool winid|png|diff …")
}
