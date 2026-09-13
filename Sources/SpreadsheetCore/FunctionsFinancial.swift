import Foundation

/// Time-value-of-money and cashflow functions. Sign convention: money paid
/// out is negative, money received is positive; `type` 0 = payments at period
/// end (default), 1 = at period start.
enum FinancialFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = annuities + cashflows

    private static let annuities: [BuiltinFunction] = [
        .eager("PMT", min: 3, max: 5) { args, _ in
            let rate = try numArg(args[0])
            let nper = try numArg(args[1])
            let pv = try numArg(args[2])
            let fv = try optionalNum(args, 3, default: 0)
            let type = try optionalNum(args, 4, default: 0)
            guard nper != 0 else { throw CellError.num }
            return .number(pmt(rate: rate, nper: nper, pv: pv, fv: fv, type: type))
        },
        .eager("IPMT", min: 4, max: 6) { args, _ in
            let rate = try numArg(args[0])
            let period = try intArg(args[1])
            let nper = try numArg(args[2])
            let pv = try numArg(args[3])
            let fv = try optionalNum(args, 4, default: 0)
            let type = try optionalNum(args, 5, default: 0)
            guard period >= 1, Double(period) <= nper else { throw CellError.num }
            let (interest, _) = try splitPayment(rate: rate, period: period, nper: nper,
                                                 pv: pv, fv: fv, type: type)
            return .number(interest)
        },
        .eager("PPMT", min: 4, max: 6) { args, _ in
            let rate = try numArg(args[0])
            let period = try intArg(args[1])
            let nper = try numArg(args[2])
            let pv = try numArg(args[3])
            let fv = try optionalNum(args, 4, default: 0)
            let type = try optionalNum(args, 5, default: 0)
            guard period >= 1, Double(period) <= nper else { throw CellError.num }
            let (_, principal) = try splitPayment(rate: rate, period: period, nper: nper,
                                                  pv: pv, fv: fv, type: type)
            return .number(principal)
        },
        .eager("FV", min: 3, max: 5) { args, _ in
            let rate = try numArg(args[0])
            let nper = try numArg(args[1])
            let payment = try numArg(args[2])
            let pv = try optionalNum(args, 3, default: 0)
            let type = try optionalNum(args, 4, default: 0)
            if rate == 0 {
                return .number(-(pv + payment * nper))
            }
            let growth = pow(1 + rate, nper)
            let value = -(pv * growth + payment * (1 + rate * type) * (growth - 1) / rate)
            return .number(value)
        },
        .eager("PV", min: 3, max: 5) { args, _ in
            let rate = try numArg(args[0])
            let nper = try numArg(args[1])
            let payment = try numArg(args[2])
            let fv = try optionalNum(args, 3, default: 0)
            let type = try optionalNum(args, 4, default: 0)
            if rate == 0 {
                return .number(-(fv + payment * nper))
            }
            let growth = pow(1 + rate, nper)
            let value = -(fv + payment * (1 + rate * type) * (growth - 1) / rate) / growth
            return .number(value)
        },
        .eager("NPER", min: 3, max: 5) { args, _ in
            let rate = try numArg(args[0])
            let payment = try numArg(args[1])
            let pv = try numArg(args[2])
            let fv = try optionalNum(args, 3, default: 0)
            let type = try optionalNum(args, 4, default: 0)
            if rate == 0 {
                guard payment != 0 else { throw CellError.num }
                return .number(-(pv + fv) / payment)
            }
            let adjusted = payment * (1 + rate * type)
            let numerator = adjusted - fv * rate
            let denominator = pv * rate + adjusted
            guard numerator / denominator > 0 else { throw CellError.num }
            return .number(log(numerator / denominator) / log(1 + rate))
        },
        .eager("RATE", min: 3, max: 6) { args, _ in
            let nper = try numArg(args[0])
            let payment = try numArg(args[1])
            let pv = try numArg(args[2])
            let fv = try optionalNum(args, 3, default: 0)
            let type = try optionalNum(args, 4, default: 0)
            let guess = try optionalNum(args, 5, default: 0.1)
            guard nper > 0 else { throw CellError.num }
            func f(_ r: Double) -> Double {
                if abs(r) < 1e-12 { return pv + payment * nper + fv }
                let growth = pow(1 + r, nper)
                return pv * growth + payment * (1 + r * type) * (growth - 1) / r + fv
            }
            guard let rate = solve(f: f, guess: guess, minX: -0.999999) else {
                throw CellError.num
            }
            return .number(rate)
        },
    ]

    private static let cashflows: [BuiltinFunction] = [
        .eager("NPV", min: 2, max: nil) { args, _ in
            let rate = try numArg(args[0])
            guard rate != -1 else { throw CellError.div0 }
            let flows = try Coerce.collectNumbers(Array(args.dropFirst()))
            var total = 0.0
            for (i, cf) in flows.enumerated() {
                total += cf / pow(1 + rate, Double(i + 1))
            }
            return .number(total)
        },
        .eager("IRR", min: 1, max: 2) { args, _ in
            let flows = try Coerce.collectNumbers([args[0]])
            let guess = try optionalNum(args, 1, default: 0.1)
            guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else {
                throw CellError.num
            }
            func f(_ r: Double) -> Double {
                var total = 0.0
                for (i, cf) in flows.enumerated() {
                    total += cf / pow(1 + r, Double(i))
                }
                return total
            }
            guard let irr = solve(f: f, guess: guess, minX: -0.999999) else {
                throw CellError.num
            }
            return .number(irr)
        },
        .eager("XIRR", min: 2, max: 3) { args, _ in
            let flows = try Coerce.collectNumbers([args[0]])
            let dates = try Coerce.collectNumbers([args[1]])
            let guess = try optionalNum(args, 2, default: 0.1)
            guard flows.count == dates.count, !flows.isEmpty else { throw CellError.num }
            guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else {
                throw CellError.num
            }
            let d0 = dates[0]
            func f(_ r: Double) -> Double {
                var total = 0.0
                for (cf, d) in zip(flows, dates) {
                    total += cf / pow(1 + r, (d - d0) / 365)
                }
                return total
            }
            guard let irr = solve(f: f, guess: guess, minX: -0.999999) else {
                throw CellError.num
            }
            return .number(irr)
        },
    ]

    // MARK: Helpers

    static func pmt(rate: Double, nper: Double, pv: Double, fv: Double, type: Double) -> Double {
        if rate == 0 {
            return -(pv + fv) / nper
        }
        let growth = pow(1 + rate, nper)
        return -(pv * growth + fv) * rate / ((growth - 1) * (1 + rate * type))
    }

    /// Interest and principal portions of the payment in `period`, by rolling
    /// the balance forward. Payments-at-start (type 1) have zero interest in
    /// period 1.
    static func splitPayment(rate: Double, period: Int, nper: Double, pv: Double,
                             fv: Double, type: Double) throws -> (interest: Double, principal: Double) {
        let payment = pmt(rate: rate, nper: nper, pv: pv, fv: fv, type: type)
        var balance = pv
        var interest = 0.0
        var principal = 0.0
        for p in 1...period {
            if type == 1 && p == 1 {
                interest = 0
            } else {
                interest = -balance * rate
            }
            principal = payment - interest
            balance += principal
            if type == 1 && p == 1 {
                // beginning-of-period payment reduces balance before interest accrues
            }
        }
        return (interest, principal)
    }

    /// Newton–Raphson with numeric derivative, falling back to bracket +
    /// bisection. Returns nil on non-convergence.
    static func solve(f: (Double) -> Double, guess: Double, minX: Double) -> Double? {
        var x = max(guess, minX + 1e-9)
        // Newton
        for _ in 0..<60 {
            let fx = f(x)
            if abs(fx) < 1e-9 { return x }
            let h = max(1e-7, abs(x) * 1e-7)
            let dfx = (f(x + h) - f(x - h)) / (2 * h)
            guard dfx != 0, dfx.isFinite else { break }
            var next = x - fx / dfx
            if next <= minX { next = (x + minX) / 2 }
            if abs(next - x) < 1e-12 { return next }
            x = next
        }
        // Bracketing scan then bisection
        var prevX = minX + 1e-6
        var prevF = f(prevX)
        var step = 0.01
        var scanX = prevX
        for _ in 0..<10_000 {
            scanX += step
            if scanX > 1e6 { break }
            let fx = f(scanX)
            if fx.isFinite, prevF.isFinite, fx.sign != prevF.sign {
                // bisect [prevX, scanX]
                var lo = prevX, hi = scanX
                var flo = prevF
                for _ in 0..<200 {
                    let mid = (lo + hi) / 2
                    let fmid = f(mid)
                    if abs(fmid) < 1e-9 || (hi - lo) / 2 < 1e-12 { return mid }
                    if fmid.sign == flo.sign {
                        lo = mid
                        flo = fmid
                    } else {
                        hi = mid
                    }
                }
                return (lo + hi) / 2
            }
            prevX = scanX
            prevF = fx
            step *= 1.05
        }
        return nil
    }
}
