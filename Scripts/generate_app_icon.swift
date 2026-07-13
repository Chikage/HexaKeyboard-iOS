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

func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
}

func rotated(_ point: CGPoint, degrees: CGFloat) -> CGPoint {
    let angle = degrees * .pi / 180
    return CGPoint(
        x: point.x * cos(angle) - point.y * sin(angle),
        y: point.x * sin(angle) + point.y * cos(angle)
    )
}

func center(q: Int, r: Int, radius: CGFloat) -> CGPoint {
    let base = CGPoint(
        x: radius * 1.5 * CGFloat(q),
        y: radius * sqrt(3) * (CGFloat(r) + CGFloat(q) / 2)
    )
    let point = rotated(base, degrees: 12)
    return CGPoint(x: point.x + 512, y: point.y + 512)
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

let keyRadius: CGFloat = 82
for q in -5...5 {
    for r in -5...5 {
        let keyCenter = center(q: q, r: r, radius: keyRadius)
        guard keyCenter.x > -keyRadius,
              keyCenter.x < CGFloat(pixelSize) + keyRadius,
              keyCenter.y > -keyRadius,
              keyCenter.y < CGFloat(pixelSize) + keyRadius
        else { continue }

        let pitchClass = positiveModulo(q * 9 + r * 4, 26)
        let fill = NSColor(
            calibratedHue: CGFloat(pitchClass) / 26,
            saturation: 0.64,
            brightness: 0.62,
            alpha: 1
        ).usingColorSpace(.deviceRGB)!.cgColor
        let path = hexagon(center: keyCenter, radius: keyRadius - 3)

        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(color(0.055, 0.075, 0.073))
        context.setLineWidth(10)
        context.strokePath()
    }
}

let originPath = hexagon(center: CGPoint(x: 512, y: 512), radius: keyRadius - 3)
context.addPath(originPath)
context.setStrokeColor(color(1.0, 0.61, 0.27))
context.setLineWidth(16)
context.strokePath()

context.setFillColor(color(0.25, 0.78, 0.80))
context.fillEllipse(in: CGRect(x: 500, y: 500, width: 24, height: 24))

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
