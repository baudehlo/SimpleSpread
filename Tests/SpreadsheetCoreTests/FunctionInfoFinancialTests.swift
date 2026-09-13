import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Info functions")
struct InfoFunctionTests {
    @Test func isBlank() {
        #expect(evalBool("ISBLANK(A1)") == true)
        #expect(evalBool("ISBLANK(A1)", cells: ["A1": "x"]) == false)
        #expect(evalBool("ISBLANK(\"\")") == false) // empty string is not blank
    }

    @Test func typePredicates() {
        #expect(evalBool("ISNUMBER(1.5)") == true)
        #expect(evalBool("ISNUMBER(\"1.5\")") == false) // no coercion
        #expect(evalBool("ISNUMBER(DATE(2026,1,1))") == true)
        #expect(evalBool("ISTEXT(\"x\")") == true)
        #expect(evalBool("ISTEXT(1)") == false)
        #expect(evalBool("ISNONTEXT(1)") == true)
        #expect(evalBool("ISLOGICAL(TRUE)") == true)
        #expect(evalBool("ISLOGICAL(1)") == false)
    }

    @Test func errorPredicates() {
        #expect(evalBool("ISERROR(1/0)") == true)
        #expect(evalBool("ISERROR(1)") == false)
        #expect(evalBool("ISERR(1/0)") == true)
        #expect(evalBool("ISERR(NA())") == false)
        #expect(evalBool("ISNA(NA())") == true)
        #expect(evalBool("ISNA(1/0)") == false)
        // Errors in referenced cells are inspected, not propagated.
        #expect(evalBool("ISERROR(A1)", cells: ["A1": "=1/0"]) == true)
    }

    @Test func evenOddPredicates() {
        #expect(evalBool("ISEVEN(4)") == true)
        #expect(evalBool("ISEVEN(3)") == false)
        #expect(evalBool("ISODD(3)") == true)
        #expect(evalBool("ISEVEN(2.7)") == true) // truncates
    }

    @Test func nAndNa() {
        #expect(evalNumber("N(5)") == 5)
        #expect(evalNumber("N(TRUE)") == 1)
        #expect(evalNumber("N(\"abc\")") == 0)
        #expect(evalError("NA()") == .na)
    }

    @Test func typeAndErrorType() {
        #expect(evalNumber("TYPE(1)") == 1)
        #expect(evalNumber("TYPE(\"x\")") == 2)
        #expect(evalNumber("TYPE(TRUE)") == 4)
        #expect(evalNumber("TYPE(1/0)") == 16)
        #expect(evalNumber("ERROR.TYPE(1/0)") == 2)
        #expect(evalNumber("ERROR.TYPE(NA())") == 7)
        #expect(evalError("ERROR.TYPE(1)") == .na)
    }
}

@Suite("Financial functions")
struct FinancialFunctionTests {
    @Test func pmt() {
        // $200k loan, 6% annual over 30 years monthly: classic result.
        let payment = evalNumber("PMT(0.06/12,360,200000)")
        #expect(approx(payment, -1199.101050305504, tolerance: 1e-6))
        // Zero rate.
        #expect(approx(evalNumber("PMT(0,10,1000)"), -100))
    }

    @Test func fvAndPv() {
        #expect(approx(evalNumber("FV(0.05,10,-100)"), 1257.789253554883, tolerance: 1e-9))
        #expect(approx(evalNumber("FV(0,10,-100)"), 1000))
        #expect(approx(evalNumber("PV(0.05,10,-100)"), 772.1734929184818, tolerance: 1e-9))
        // PV and FV are inverses through the annuity.
        let fv = evalNumber("FV(0.04,8,-250,-1000)")!
        let pv = evalNumber("PV(0.04,8,-250,\(fv))")!
        #expect(approx(pv, -1000, tolerance: 1e-6))
    }

    @Test func nper() {
        // How long to pay off 1000 at 100/period, 1%: ~10.6 periods.
        let n = evalNumber("NPER(0.01,-100,1000)")
        #expect(n != nil && n! > 10 && n! < 11)
        #expect(approx(evalNumber("NPER(0,-100,1000)"), 10))
    }

    @Test func rateSolvesInverse() {
        // RATE should recover the rate used by PMT.
        let payment = evalNumber("PMT(0.005,360,200000)")!
        let rate = evalNumber("RATE(360,\(payment),200000)")
        #expect(approx(rate, 0.005, tolerance: 1e-6))
    }

    @Test func ipmtPpmt() {
        // First period interest on 6%/12 loan = balance * rate.
        let ipmt1 = evalNumber("IPMT(0.005,1,360,200000)")
        #expect(approx(ipmt1, -1000, tolerance: 1e-6))
        // IPMT + PPMT = PMT for any period.
        let pmt = evalNumber("PMT(0.005,360,200000)")!
        let i5 = evalNumber("IPMT(0.005,5,360,200000)")!
        let p5 = evalNumber("PPMT(0.005,5,360,200000)")!
        #expect(approx(i5 + p5, pmt, tolerance: 1e-6))
        #expect(evalError("IPMT(0.005,0,360,200000)") == .num)
    }

    @Test func npv() {
        let npv = evalNumber("NPV(0.1,100,100,100)")
        #expect(approx(npv, 100 / 1.1 + 100 / 1.21 + 100 / 1.331, tolerance: 1e-9))
        let cells = ["A1": "100", "A2": "200"]
        #expect(approx(evalNumber("NPV(0.05,A1:A2)", cells: cells)!,
                       100 / 1.05 + 200 / 1.1025, tolerance: 1e-9))
    }

    @Test func irr() {
        let cells = ["A1": "-1000", "A2": "300", "A3": "400", "A4": "500"]
        let irr = evalNumber("IRR(A1:A4)", cells: cells)
        #expect(irr != nil)
        // NPV at the IRR must be ~0.
        let r = irr!
        let npv = -1000 + 300 / (1 + r) + 400 / pow(1 + r, 2) + 500 / pow(1 + r, 3)
        #expect(abs(npv) < 1e-6)
        // All-positive flows -> #NUM!.
        #expect(evalError("IRR(A1:A3)", cells: ["A1": "1", "A2": "2", "A3": "3"]) == .num)
    }

    @Test func xirr() {
        let cells = [
            "A1": "-1000", "A2": "1100",
            "B1": "=DATE(2025,1,1)", "B2": "=DATE(2026,1,1)",
        ]
        let xirr = evalNumber("XIRR(A1:A2,B1:B2)", cells: cells)
        #expect(approx(xirr, 0.1, tolerance: 1e-4))
    }
}
