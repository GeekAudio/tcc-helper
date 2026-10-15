// make-icon.swift —— 生成 App 图标（1024×1024 PNG）
// 设计：Big Sur 风格圆角方形底 + 白色盾牌 + 蓝色对勾
// 用法：make-icon <输出.png>

import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("无法创建绘图上下文\n".utf8))
    exit(1)
}

// CG 坐标原点在左下；这里翻转成「左上原点」，方便按视觉坐标写
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

// ---------- 1) 圆角方形底 + 渐变 ----------
let inset: CGFloat = 100            // Big Sur 图标留白
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 0.2237

let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.30, green: 0.53, blue: 0.98, alpha: 1),   // 上：亮蓝
    CGColor(red: 0.09, green: 0.24, blue: 0.72, alpha: 1),   // 下：深蓝
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: rect.midX, y: rect.minY),
                       end: CGPoint(x: rect.midX, y: rect.maxY),
                       options: [])
ctx.restoreGState()

// ---------- 2) 白色盾牌 ----------
let cx: CGFloat = S / 2
let shieldTop: CGFloat = 276
let shieldBot: CGFloat = 786
let halfW: CGFloat = 252
let shoulderY: CGFloat = 458

let shield = CGMutablePath()
shield.move(to: CGPoint(x: cx, y: shieldTop))
shield.addLine(to: CGPoint(x: cx + halfW, y: shoulderY - 118))
shield.addLine(to: CGPoint(x: cx + halfW, y: shoulderY))
shield.addCurve(to: CGPoint(x: cx, y: shieldBot),
                control1: CGPoint(x: cx + halfW, y: shieldBot - 120),
                control2: CGPoint(x: cx + halfW * 0.62, y: shieldBot))
shield.addCurve(to: CGPoint(x: cx - halfW, y: shoulderY),
                control1: CGPoint(x: cx - halfW * 0.62, y: shieldBot),
                control2: CGPoint(x: cx - halfW, y: shieldBot - 120))
shield.addLine(to: CGPoint(x: cx - halfW, y: shoulderY - 118))
shield.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 34,
              color: CGColor(red: 0, green: 0.08, blue: 0.3, alpha: 0.38))
ctx.addPath(shield)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// ---------- 3) 盾牌里的对勾 ----------
let check = CGMutablePath()
check.move(to: CGPoint(x: cx - 116, y: 524))
check.addLine(to: CGPoint(x: cx - 30, y: 610))
check.addLine(to: CGPoint(x: cx + 130, y: 436))

ctx.saveGState()
ctx.addPath(check)
ctx.setStrokeColor(CGColor(red: 0.10, green: 0.26, blue: 0.76, alpha: 1))
ctx.setLineWidth(56)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// ---------- 4) 输出 ----------
guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(outPath)  \(Int(S))×\(Int(S))")
