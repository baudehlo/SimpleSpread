import Foundation
@testable import SpreadsheetCore

/// Deterministic clock: today = 2026-09-13 (serial 46278), random = 0.5.
let testClock = EvalClock.fixed(
    today: ExcelDate.serial(year: 2026, month: 9, day: 13),
    now: ExcelDate.serial(year: 2026, month: 9, day: 13, hour: 10, minute: 30, second: 0),
    random: 0.5
)

/// A workbook harness: seed cells (raw input strings, formulas with '='),
/// then evaluate a formula placed in cell AZ99 of Sheet1.
struct Harness {
    let workbook: Workbook
    let engine: CalculationEngine
    var sheetID: Int { workbook.sheets[0].id }

    init(cells: [String: String] = [:]) {
        workbook = Workbook.newDocument()
        engine = CalculationEngine(workbook: workbook, clock: testClock)
        set(cells: cells)
    }

    func set(cells: [String: String], sheetIndex: Int = 0) {
        let sheet = workbook.sheets[sheetIndex]
        var entries: [(AbsoluteAddress, CellValue, String?)] = []
        for (a1, input) in cells {
            guard let address = CellAddress(a1: a1) else { continue }
            let parsed = ValueParser.parse(input)
            entries.append((AbsoluteAddress(sheetID: sheet.id, address: address),
                            parsed.value, parsed.formulaText))
        }
        engine.setCells(entries)
    }

    func set(_ a1: String, _ input: String, sheetIndex: Int = 0) {
        set(cells: [a1: input], sheetIndex: sheetIndex)
    }

    func value(_ a1: String, sheetIndex: Int = 0) -> CellValue {
        workbook.sheets[sheetIndex].value(at: CellAddress(a1: a1)!)
    }

    /// Evaluate a formula (without '=') in AZ99 and return the result.
    func eval(_ formula: String) -> CellValue {
        let addr = AbsoluteAddress(sheetID: sheetID, address: CellAddress(a1: "AZ99")!)
        engine.setCellFormula(formula, at: addr)
        return value("AZ99")
    }
}

/// One-shot: evaluate a formula against seeded cells.
func evalFormula(_ formula: String, cells: [String: String] = [:]) -> CellValue {
    Harness(cells: cells).eval(formula)
}

/// Convenience: evaluate and extract a number (or nil).
func evalNumber(_ formula: String, cells: [String: String] = [:]) -> Double? {
    evalFormula(formula, cells: cells).numberValue
}

func evalString(_ formula: String, cells: [String: String] = [:]) -> String? {
    evalFormula(formula, cells: cells).stringValue
}

func evalBool(_ formula: String, cells: [String: String] = [:]) -> Bool? {
    evalFormula(formula, cells: cells).boolValue
}

func evalError(_ formula: String, cells: [String: String] = [:]) -> CellError? {
    evalFormula(formula, cells: cells).errorValue
}

/// Approximate equality for numeric results.
func approx(_ a: Double?, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    if b == 0 { return abs(a) < tolerance }
    return abs(a - b) <= tolerance * max(1, abs(b))
}
