import CoreGraphics
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The iPad redraws the whole screen as it scrolls (GridView), so drawing a
/// screenful must stay well inside a frame. Times the shared renderer on a
/// dense 13-inch iPad screen of text, numbers and formulas.
@MainActor
@Suite("Grid rendering speed")
struct RenderTimingTests {
    @Test func aDenseScreenDrawsInsideAFrame() throws {
        let doc = SpreadsheetDocument()
        let sheet = doc.activeSheet
        for row in 0..<200 {
            for col in 0..<20 {
                let a = CellAddress(row: row, column: col)
                switch col % 3 {
                case 0: doc.commitInput("Item \(row)-\(col)", at: a)
                case 1: doc.commitInput(String(row * col), at: a)
                default: doc.commitInput("=B\(row + 1)*2", at: a)
                }
            }
        }
        doc.selection.select(range: CellRange(a1: "B3:D9")!)
        _ = sheet
        let controller = GridController()
        controller.document = doc
        let size = CGSize(width: 1032, height: 1376)
        let visible = CGRect(origin: CGPoint(x: 300, y: 400), size: size)
        let ctx = try #require(CGContext(data: nil, width: Int(size.width) * 2, height: Int(size.height) * 2,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Flipped and scaled like a Retina view.
        ctx.translateBy(x: 0, y: size.height * 2)
        ctx.scaleBy(x: 2, y: -2)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        #if os(macOS)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = nil }
        #else
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        #endif
        let renderer = GridRenderer(document: doc, geometry: GridGeometry(layout: controller.layout, visible: visible),
                                    pivotBands: [])
        renderer.draw(in: ctx, dirtyRect: visible) // warm caches (fonts, layout)
        let clock = ContinuousClock()
        let runs = 10
        let elapsed = clock.measure {
            for _ in 0..<runs { renderer.draw(in: ctx, dirtyRect: visible) }
        }
        let perFrame = elapsed / runs
        print("Grid render: \(perFrame) per 1032x1376 screen")
        // Generous: CI machines are slow and shared. Real devices: see docs/IPAD.md.
        #expect(perFrame < .milliseconds(100))
    }
}
