#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate_app_icon.swift OUTPUT\n".utf8))
    exit(2)
}

let pixelSize = 1_024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: pixelSize,
    height: pixelSize,
    bitsPerComponent: 8,
    bytesPerRow: pixelSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Unable to create icon bitmap context")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
}

func rotated(_ point: CGPoint, degrees: CGFloat) -> CGPoint {
    let angle = degrees * .pi / 180
    return CGPoint(
        x: point.x * cos(angle) - point.y * sin(angle),
        y: point.x * sin(angle) + point.y * cos(angle)
    )
}

func axialPoint(q: Int, r: Int, radius: CGFloat) -> CGPoint {
    let base = CGPoint(
        x: radius * 1.5 * CGFloat(q),
        y: radius * sqrt(3) * (CGFloat(r) + CGFloat(q) / 2)
    )
    return rotated(base, degrees: 12)
}

func hexagon(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for index in 0..<6 {
        let angle = (CGFloat(index) * 60 + 12) * .pi / 180
        let point = CGPoint(
            x: center.x + radius * cos(angle),
            y: center.y + radius * sin(angle)
        )
        index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

context.setFillColor(color(0.055, 0.075, 0.073))
context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

let cluster = [
    (q: 1, r: 0),
    (q: 1, r: -1),
    (q: 0, r: -1),
    (q: -1, r: 0),
    (q: -1, r: 1),
    (q: 0, r: 1),
]
let rawCenters = cluster.map { axialPoint(q: $0.q, r: $0.r, radius: 1) }
let rawVertices = rawCenters.flatMap { center -> [CGPoint] in
    (0..<6).map { index in
        let angle = (CGFloat(index) * 60 + 12) * .pi / 180
        return CGPoint(x: center.x + cos(angle), y: center.y + sin(angle))
    }
}
let rawMinX = rawVertices.map(\.x).min()!
let rawMaxX = rawVertices.map(\.x).max()!
let rawMinY = rawVertices.map(\.y).min()!
let rawMaxY = rawVertices.map(\.y).max()!
// The dark 14 px divider is visually part of the background. A 110 px path
// inset plus its 7 px inner half leaves 117 px (11.4%) of visible edge space.
let targetInset: CGFloat = 110
let targetExtent = CGFloat(pixelSize) - targetInset * 2
let scale = min(
    targetExtent / (rawMaxX - rawMinX),
    targetExtent / (rawMaxY - rawMinY)
)

let ringColors: [CGColor] = [
    color(0.28, 0.65, 0.73),
    color(0.34, 0.45, 0.73),
    color(0.58, 0.31, 0.64),
    color(0.68, 0.30, 0.43),
    color(0.64, 0.54, 0.24),
    color(0.25, 0.58, 0.38),
]

for (index, coordinate) in cluster.enumerated() {
    let rawCenter = axialPoint(q: coordinate.q, r: coordinate.r, radius: 1)
    let keyCenter = CGPoint(
        x: 512 + rawCenter.x * scale,
        y: 512 + rawCenter.y * scale
    )
    let path = hexagon(center: keyCenter, radius: scale)
    context.addPath(path)
    context.setFillColor(ringColors[index])
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(color(0.055, 0.075, 0.073))
    context.setLineWidth(14)
    context.strokePath()
}

let originPath = hexagon(center: CGPoint(x: 512, y: 512), radius: scale)
context.addPath(originPath)
context.setFillColor(color(0.15, 0.47, 0.48))
context.fillPath()
context.addPath(originPath)
context.setStrokeColor(color(1.0, 0.61, 0.27))
context.setLineWidth(18)
context.strokePath()

guard let image = context.makeImage() else {
    fatalError("Unable to create icon image")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Unable to create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write AppIcon PNG")
}
