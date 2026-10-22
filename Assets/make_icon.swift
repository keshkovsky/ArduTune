// Готує AppIcon.icns із icon_source.webp: прибирає білий фон і тінь, ставить іконку на полотно 1024 за макетом macOS
// (корпус 824 px, відступи 100 px) і додає м'яку тінь. Запуск: swiftc -O make_icon.swift -o /tmp/make_icon && /tmp/make_icon
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("icon_source.webp") as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("Не вдалося прочитати icon_source.webp") }
let W = img.width, H = img.height
let cs = CGColorSpaceCreateDeviceRGB()
var px = [UInt8](repeating: 0, count: W * H * 4)
let bctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

func lum(_ i: Int) -> Double { (0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2])) / 255 }
// Фон = світлі пікселі, досяжні з країв (тінь теж світліша за корпус).
var bg = [Bool](repeating: false, count: W * H)
var stack: [Int] = []
for x in 0..<W { stack.append(x); stack.append((H - 1) * W + x) }
for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
while let i = stack.popLast() {
    if bg[i] || lum(i) < 0.45 { continue }
    bg[i] = true
    let x = i % W, y = i / W
    if x > 0 { stack.append(i - 1) }; if x < W - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - W) }; if y < H - 1 { stack.append(i + W) }
}
// Охоплююча рамка корпусу
var minX = W, maxX = 0, minY = H, maxY = 0
for y in 0..<H { for x in 0..<W where !bg[y * W + x] { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
// Ерозія маски на 2 px (прибирає світлу облямівку), альфа для корпусу
var alpha = [UInt8](repeating: 0, count: W * H)
for y in 0..<H { for x in 0..<W where !bg[y * W + x] { alpha[y * W + x] = 255 } }
for _ in 0..<2 {
    var next = alpha
    for y in 1..<H - 1 { for x in 1..<W - 1 where alpha[y * W + x] == 255 {
        if alpha[y * W + x - 1] == 0 || alpha[y * W + x + 1] == 0 || alpha[(y - 1) * W + x] == 0 || alpha[(y + 1) * W + x] == 0 { next[y * W + x] = 0 }
    } }
    alpha = next
}
for i in 0..<W * H { let a = Int(alpha[i]); px[i * 4] = UInt8(Int(px[i * 4]) * a / 255); px[i * 4 + 1] = UInt8(Int(px[i * 4 + 1]) * a / 255); px[i * 4 + 2] = UInt8(Int(px[i * 4 + 2]) * a / 255); px[i * 4 + 3] = alpha[i] }
let cut = bctx.makeImage()!
let crop = cut.cropping(to: CGRect(x: minX + 2, y: minY + 2, width: maxX - minX - 3, height: maxY - minY - 3))!

func render(_ size: Int) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    let ar = CGFloat(crop.width) / CGFloat(crop.height)
    let bw = (ar >= 1 ? 824 : 824 * ar) * s, bh = (ar >= 1 ? 824 / ar : 824) * s
    let body = CGRect(x: (CGFloat(size) - bw) / 2, y: (CGFloat(size) - bh) / 2, width: bw, height: bh)
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: CGColor(gray: 0, alpha: 0.38))
    c.draw(crop, in: body)
    return c.makeImage()!
}
func save(_ im: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, im, nil); CGImageDestinationFinalize(d)
}
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (n, sz) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    save(render(sz), iconset.appendingPathComponent("icon_\(n).png"))
}
save(render(1024), dir.appendingPathComponent("AppIcon.png"))
print("OK \(W)x\(H) body \(maxX - minX)x\(maxY - minY)")
