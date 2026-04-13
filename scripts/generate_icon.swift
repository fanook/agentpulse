#!/usr/bin/env swift
// Generates an AppIcon.icns for AgentPulse using AppKit — no external deps.
// Usage: swift scripts/generate_icon.swift <out_dir>
// Produces <out_dir>/AppIcon.icns

import AppKit
import CoreText

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: generate_icon.swift <out_dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconutil wants a .iconset folder with specific filenames.
let workDir = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(atPath: workDir)
try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)

struct Variant { let size: Int; let scale: Int; let name: String }
let variants: [Variant] = [
    .init(size: 16,  scale: 1, name: "icon_16x16.png"),
    .init(size: 16,  scale: 2, name: "icon_16x16@2x.png"),
    .init(size: 32,  scale: 1, name: "icon_32x32.png"),
    .init(size: 32,  scale: 2, name: "icon_32x32@2x.png"),
    .init(size: 128, scale: 1, name: "icon_128x128.png"),
    .init(size: 128, scale: 2, name: "icon_128x128@2x.png"),
    .init(size: 256, scale: 1, name: "icon_256x256.png"),
    .init(size: 256, scale: 2, name: "icon_256x256@2x.png"),
    .init(size: 512, scale: 1, name: "icon_512x512.png"),
    .init(size: 512, scale: 2, name: "icon_512x512@2x.png"),
]

/// AgentPulse wordmark icon: a solid dark rounded square with a bold "AP"
/// monogram centered on it. Reads cleanly at every size including the
/// notification thumbnail, no fussy details to mush together.
func render(pixelSize: Int) -> Data {
    let S = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return Data() }

    // ---- Background: deep graphite, rounded square.
    let inset = S * 0.08
    let rect = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
    let corner = S * 0.235
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(path); ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let bgTop = CGColor(colorSpace: cs, components: [0.12, 0.13, 0.16, 1.0])!
    let bgBot = CGColor(colorSpace: cs, components: [0.18, 0.18, 0.22, 1.0])!
    let grad = CGGradient(colorsSpace: cs, colors: [bgTop, bgBot] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: S),
                           end: CGPoint(x: S, y: 0),
                           options: [])
    ctx.resetClip()

    // ---- Wordmark: bold "AP" centered, white, SF Pro Rounded.
    let text = "AP" as NSString
    let pointSize = S * 0.46
    let font = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
        .withRoundedDesignIfAvailable()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 1.0, alpha: 1.0),
        .paragraphStyle: paragraph,
        .kern: -pointSize * 0.04
    ]

    let textSize = text.size(withAttributes: attrs)
    let drawRect = CGRect(
        x: (S - textSize.width) / 2,
        y: (S - textSize.height) / 2 - S * 0.01,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: drawRect, withAttributes: attrs)

    return rep.representation(using: .png, properties: [:]) ?? Data()
}

private extension NSFont {
    func withRoundedDesignIfAvailable() -> NSFont {
        if let descriptor = fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: 0) ?? self
        }
        return self
    }
}

for v in variants {
    let px = v.size * v.scale
    let data = render(pixelSize: px)
    let path = (workDir as NSString).appendingPathComponent(v.name)
    try data.write(to: URL(fileURLWithPath: path))
    print("  \(v.name) (\(px)x\(px))")
}

// iconutil pack
let icnsPath = (outDir as NSString).appendingPathComponent("AppIcon.icns")
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", "-o", icnsPath, workDir]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

// Clean up .iconset folder.
try? fm.removeItem(atPath: workDir)
print("wrote \(icnsPath)")
