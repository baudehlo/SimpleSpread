import CoreGraphics
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Charts from a file draw over the cells, where they're anchored.
@MainActor
@Suite struct ChartDrawingTests {
    /// The charts Excel wrote (SpreadsheetFilesTests' fixture).
    static func excelDocument() throws -> SpreadsheetDocument {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SpreadsheetFilesTests/Fixtures/ExcelOracle/charts-by-excel.xlsx")
        return SpreadsheetDocument(workbook: try XLSXReader.read(data: Data(contentsOf: url)))
    }

    /// Draw the grid at 2x over `visible`; nil charts leaves them out.
    static func draw(_ doc: SpreadsheetDocument, visible: CGRect, charts: Bool) throws -> CGImage {
        let controller = GridController()
        controller.document = doc
        controller.chartLayer.rendersSynchronously = true
        let size = visible.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width) * 2, height: Int(size.height) * 2,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
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
        var renderer = try #require(controller.renderer())
        if !charts { renderer.chartLayer = nil }
        renderer.draw(in: ctx, dirtyRect: visible)
        return try #require(ctx.makeImage())
    }

    @Test func chartsDrawWhereTheyAreAnchored() throws {
        let doc = try Self.excelDocument()
        let controller = GridController()
        controller.document = doc
        let charts = doc.activeCharts
        #expect(charts.count == 16)
        // The first: one-cell anchored at F2, 5040000 x 2700000 EMU.
        let frame = SheetChartLayer.frame(of: charts[0], in: GridGeometry(layout: controller.layout, visible: .zero))
        let f2 = GridGeometry(layout: controller.layout, visible: .zero).cellRect(CellAddress(a1: "F2")!)
        #expect(frame.origin == f2.origin)
        #expect(frame.size == CGSize(width: 5040000.0 / 9525, height: 2700000.0 / 9525))

        let visible = CGRect(x: 0, y: 0, width: 1100, height: 700)
        let with = try Self.draw(doc, visible: visible, charts: true)
        let without = try Self.draw(doc, visible: visible, charts: false)
        if let out = ProcessInfo.processInfo.environment["SIMPLESPREAD_CHART_PNG"] {
            #if os(macOS)
            try NSBitmapImageRep(cgImage: with).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: out))
            #endif
        }
        // Inside the chart the picture differs from bare cells; over A1:D7 it doesn't.
        func differs(in rect: CGRect) -> Bool {
            let crop = rect.applying(CGAffineTransform(scaleX: 2, y: 2))
            guard let a = with.cropping(to: crop), let b = without.cropping(to: crop) else { return false }
            return Self.bytes(a) != Self.bytes(b)
        }
        #expect(differs(in: frame.insetBy(dx: 20, dy: 20)))
        let data = GridGeometry(layout: controller.layout, visible: .zero).rangeRect(CellRange(a1: "A1:D7")!)
        #expect(!differs(in: data))
    }

    static func bytes(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4)
        return Array(buffer)
    }
}
