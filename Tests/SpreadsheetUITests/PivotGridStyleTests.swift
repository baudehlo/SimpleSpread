import CoreGraphics
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

@Suite("Cell text indent")
struct CellTextIndentTests {
    @Test func widthScalesWithLevelAndFont() {
        #expect(CellTextIndent.width(level: 0, fontSize: 12) == 0)
        #expect(CellTextIndent.width(level: 1, fontSize: 12) == CellTextIndent.pointsPerLevel)
        #expect(CellTextIndent.width(level: 2, fontSize: 24) == 4 * CellTextIndent.pointsPerLevel)
    }

    @Test func leftMovesRightRightMovesLeftCenterIgnores() {
        let rect = CGRect(x: 10, y: 0, width: 100, height: 20)
        #expect(CellTextIndent.apply(20, to: rect, rightAligned: false, centered: false)
            == CGRect(x: 30, y: 0, width: 80, height: 20))
        #expect(CellTextIndent.apply(20, to: rect, rightAligned: true, centered: false)
            == CGRect(x: 10, y: 0, width: 80, height: 20))
        #expect(CellTextIndent.apply(20, to: rect, rightAligned: false, centered: true) == rect)
        // Never more than the cell is wide.
        #expect(CellTextIndent.apply(500, to: rect, rightAligned: false, centered: false).width == 0)
    }
}

@Suite("Pivot bands")
struct PivotBandsTests {
    /// A cross-tab at A3:D7: caption row, column-label row, two body rows,
    /// grand total.
    let roles: [CellAddress: PivotCellRole] = {
        var r: [CellAddress: PivotCellRole] = [:]
        func put(_ a1: String, _ role: PivotCellRole) { r[CellAddress(a1: a1)!] = role }
        put("A3", .header); put("B3", .header)
        put("A4", .header); put("B4", .columnLabel); put("C4", .columnLabel); put("D4", .grandTotalLabel)
        put("A5", .rowLabel); put("B5", .value); put("D5", .grandTotalValue)
        put("A6", .rowLabel); put("B6", .value); put("D6", .grandTotalValue)
        put("A7", .grandTotalLabel); put("B7", .grandTotalValue); put("D7", .grandTotalValue)
        return r
    }()

    @Test func headerRowsAndGrandTotals() {
        let role: (CellAddress) -> PivotCellRole? = { roles[$0] }
        let bands = PivotBands(location: CellRange(a1: "A3:D7")!, role: role)
        #expect(bands.headerRows == 2...3)
        #expect(bands.isGrandTotalRow(6, role: role))
        #expect(!bands.isGrandTotalRow(5, role: role))
        #expect(bands.isShaded(CellAddress(a1: "C3")!, role: role)) // empty, but in the header band
        #expect(bands.isShaded(CellAddress(a1: "C7")!, role: role))
        #expect(!bands.isShaded(CellAddress(a1: "D5")!, role: role)) // grand-total column: bold only
        #expect(!bands.isShaded(CellAddress(a1: "E3")!, role: role)) // outside the body
    }

    @Test func noHeaderRowsWhenTheBodyStartsAtTheTop() {
        let bands = PivotBands(location: CellRange(a1: "A5:D6")!, role: { roles[$0] })
        #expect(bands.headerRows == nil)
    }

    @Test func boldRoles() {
        #expect(PivotBands.isBold(.header))
        #expect(PivotBands.isBold(.grandTotalValue))
        #expect(PivotBands.isBold(.subtotalLabel))
        #expect(PivotBands.isBold(.filterLabel))
        #expect(!PivotBands.isBold(.rowLabel))
        #expect(!PivotBands.isBold(.value))
        #expect(!PivotBands.isBold(.filterValue))
    }
}

@Suite("Cell text colour")
struct CellTextColourTests {
    @Test func automaticTextContrastsWithTheFill() {
        #expect(RGBAColor(red: 0xFF, green: 0xF4, blue: 0xCC).isLight)   // pale yellow
        #expect(RGBAColor(red: 0xFF, green: 0xFF, blue: 0xFF).isLight)
        #expect(!RGBAColor(red: 0x1F, green: 0x4E, blue: 0x79).isLight)  // dark blue
        #expect(!RGBAColor(red: 0, green: 0, blue: 0).isLight)
        #expect(!RGBAColor(red: 0xC0, green: 0x00, blue: 0x00).isLight) // dark red: white text
    }
}

@Suite("Spoken labels")
struct SpokenLabelTests {
    @Test func tipsShortenToTheirName() {
        #expect(spokenLabel("Bold (⌘B)") == "Bold")
        #expect(spokenLabel("AutoSum: total the numbers above (click the arrow…)") == "AutoSum")
        #expect(spokenLabel("Text color") == "Text color")
    }
}

@MainActor
@Suite("Appearance setting")
struct AppearanceSettingTests {
    @Test func theChoiceIsRememberedAndDefaultsToTheSystem() {
        let defaults = UserDefaults(suiteName: "simplespread-appearance-\(UUID().uuidString)")!
        #expect(AppearanceSetting(defaults: defaults).choice == .system)
        AppearanceSetting(defaults: defaults).choice = .light
        #expect(AppearanceSetting(defaults: defaults).choice == .light)
        defaults.set("sepia", forKey: AppearanceSetting.defaultsKey)
        #expect(AppearanceSetting(defaults: defaults).choice == .system)
    }
}
