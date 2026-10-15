// redact.swift —— 给 PNG 的指定矩形区域打马赛克（发布前脱敏用）
// 用法：redact <in.png> <out.png> <x> <y> <w> <h> <block>
//   x/y 以「左上角为原点」计（和你在预览里看到的坐标一致）

import AppKit
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count >= 8,
      let x = Int(a[3]), let y = Int(a[4]),
      let w = Int(a[5]), let h = Int(a[6]), let blk = Int(a[7]) else {
    FileHandle.standardError.write(Data("用法: redact <in.png> <out.png> <x> <y> <w> <h> <block>\n".utf8))
    exit(2)
}
let inPath = a[1], outPath = a[2]
let block = max(2, blk)

guard let src = NSImage(contentsOfFile: inPath),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("读不到图片\n".utf8)); exit(1)
}
let W = cg.width, H = cg.height
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// 整图照画（CG 默认左下原点，直接 draw 得到视觉正确的方向）
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

// 裁出要打码的区域（CGImage.cropping 用左上原点，和传入坐标一致）
let clip = CGRect(x: x, y: y, width: w, height: h)
guard let region = cg.cropping(to: clip) else {
    FileHandle.standardError.write(Data("裁剪失败（坐标越界？图片 \(W)×\(H)）\n".utf8)); exit(1)
}

// 缩小 → 再放大（最近邻）= 马赛克
let sw = max(1, w / block), sh = max(1, h / block)
guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
small.interpolationQuality = .high
small.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
guard let smallImg = small.makeImage() else { exit(1) }

// 贴回去：把「左上原点」的 y 换算成 CG 的左下原点
ctx.saveGState()
ctx.interpolationQuality = .none
ctx.draw(smallImg, in: CGRect(x: x, y: H - y - h, width: w, height: h))
ctx.restoreGState()

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("已打码 \(w)×\(h) @(\(x),\(y))，块大小 \(block) → \(outPath)")
