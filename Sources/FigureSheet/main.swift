// Renders a contact sheet of the figure in many poses, for tuning the drawing without headphones.
import CoreGraphics
import Foundation
import ImageIO
import NoddleCore
import UniformTypeIdentifiers

func writePNG(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// The app icon: the figure on a soft rounded tile.
func icon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.098
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    let paper = CGColor(red: 0.98, green: 0.98, blue: 0.975, alpha: 1)
    ctx.addPath(path)
    ctx.setFillColor(paper)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.clip()
    let style = FigureStyle(ink: CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1),
                            accent: CGColor(red: 0, green: 0.48, blue: 1, alpha: 1), paper: paper)
    let art = CGRect(x: tile.minX - tile.width * 0.14, y: tile.minY - tile.height * 0.42,
                     width: tile.width * 1.28, height: tile.height * 1.5)
    FigureRenderer.draw(in: ctx, rect: art, state: FigureState(pose: HeadPose(yaw: 8, pitch: -3, roll: 8), budGlow: 0.6), style: style)
    return ctx.makeImage()!
}

if let i = CommandLine.arguments.firstIndex(of: "--icon") {
    let dir = CommandLine.arguments[i + 1]
    for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                         ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        writePNG(icon(size: size), to: "\(dir)/icon_\(name).png")
    }
    exit(0)
}

let dark = CommandLine.arguments.contains("--dark")
let out = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "figure.png"
let poses: [(String, HeadPose)] = [
    ("neutral", .zero), ("left", HeadPose(yaw: 32)), ("right", HeadPose(yaw: -32)), ("far right", HeadPose(yaw: -60)),
    ("up", HeadPose(pitch: 22)), ("down", HeadPose(pitch: -22)), ("tilt L", HeadPose(roll: -20)), ("tilt R", HeadPose(roll: 20)),
]
let cell = 460, cols = 4, rows = 2
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: cell * cols, height: cell * rows, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let paper = dark ? CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) : CGColor(red: 0.975, green: 0.975, blue: 0.97, alpha: 1)
let ink = dark ? CGColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1) : CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
ctx.setFillColor(paper)
ctx.fill(CGRect(x: 0, y: 0, width: cell * cols, height: cell * rows))
let style = FigureStyle(ink: ink, accent: CGColor(red: 0.0, green: 0.48, blue: 1, alpha: 1), paper: paper)
for (i, entry) in poses.enumerated() {
    let rect = CGRect(x: (i % cols) * cell, y: (rows - 1 - i / cols) * cell, width: cell, height: cell).insetBy(dx: 16, dy: 16)
    let echoes = i == 1 ? [HeadPose(yaw: 8), HeadPose(yaw: 16), HeadPose(yaw: 24)] : []
    FigureRenderer.draw(in: ctx, rect: rect, state: FigureState(pose: entry.1, echoes: echoes, pulse: i == 4 ? 0.4 : nil, budGlow: 1), style: style)
}
writePNG(ctx.makeImage()!, to: out)
