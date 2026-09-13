#!/usr/bin/env swift
// Generates icon.png (1024x1024) — a spreadsheet grid glyph.
// Usage: swift scripts/generate-icon.swift [output.png]

import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Background: rounded rect, deep green gradient.
let inset: CGFloat = 80
let bgRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 180, yRadius: 180)
bgPath.addClip()

let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.09, green: 0.55, blue: 0.35, alpha: 1),
    ending: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.25, alpha: 1))!
gradient.draw(in: bgRect, angle: -90)

// White sheet card.
let cardRect = CGRect(x: 220, y: 200, width: 584, height: 624)
NSColor.white.setFill()
NSBezierPath(roundedRect: cardRect, xRadius: 36, yRadius: 36).fill()

// Grid lines on the card.
NSColor(srgbRed: 0.75, green: 0.85, blue: 0.80, alpha: 1).setStroke()
let columns = 3
let rows = 4
let cellW = cardRect.width / CGFloat(columns)
let cellH = (cardRect.height - 110) / CGFloat(rows)
for c in 1..<columns {
    let p = NSBezierPath()
    p.lineWidth = 10
    let x = cardRect.minX + CGFloat(c) * cellW
    p.move(to: CGPoint(x: x, y: cardRect.minY))
    p.line(to: CGPoint(x: x, y: cardRect.maxY - 110))
    p.stroke()
}
for r in 0...rows {
    let p = NSBezierPath()
    p.lineWidth = 10
    let y = cardRect.minY + CGFloat(r) * cellH
    p.move(to: CGPoint(x: cardRect.minX, y: y))
    p.line(to: CGPoint(x: cardRect.maxX, y: y))
    p.stroke()
}

// Header band.
NSColor(srgbRed: 0.13, green: 0.62, blue: 0.41, alpha: 1).setFill()
let headerPath = NSBezierPath()
headerPath.appendRoundedRect(
    CGRect(x: cardRect.minX, y: cardRect.maxY - 110, width: cardRect.width, height: 110),
    xRadius: 36, yRadius: 36)
headerPath.fill()
NSColor(srgbRed: 0.13, green: 0.62, blue: 0.41, alpha: 1).setFill()
CGRect(x: cardRect.minX, y: cardRect.maxY - 110, width: cardRect.width, height: 50).fill()

// Accent cells.
NSColor(srgbRed: 0.85, green: 0.95, blue: 0.90, alpha: 1).setFill()
CGRect(x: cardRect.minX + 2 * cellW, y: cardRect.minY + 0 * cellH,
       width: cellW, height: cellH).insetBy(dx: 8, dy: 8).fill()
CGRect(x: cardRect.minX + cellW, y: cardRect.minY + 2 * cellH,
       width: cellW, height: cellH).insetBy(dx: 8, dy: 8).fill()

ctx.flush()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render PNG")
}
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
