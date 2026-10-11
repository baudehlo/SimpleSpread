import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Pivot caches: lazy data")
struct PivotCacheLazyDataTests {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var loads = 0
        func hit() { lock.lock(); loads += 1; lock.unlock() }
    }

    struct Payload: PreservedPartPayload {}

    static func data(_ name: String) -> PivotCacheData {
        PivotCacheData(fields: [PivotCacheField(name: name)], records: [])
    }

    @Test func loadsOnceOnFirstUse() {
        let counter = Counter()
        var cache = PivotCache(cacheID: 1, sourceRanges: [], payload: Payload())
        cache.loadDataLazily { counter.hit(); return Self.data("Region") }
        #expect(counter.loads == 0)
        let copy = cache
        #expect(cache.data?.fields.first?.name == "Region")
        #expect(copy.data?.fields.first?.name == "Region")
        #expect(counter.loads == 1)
    }

    @Test func assigningReplacesWithoutLoading() {
        let counter = Counter()
        var cache = PivotCache(cacheID: 1, sourceRanges: [], payload: Payload())
        cache.loadDataLazily { counter.hit(); return Self.data("Region") }
        let original = cache
        cache.data = Self.data("Rep")
        #expect(cache.data?.fields.first?.name == "Rep")
        #expect(counter.loads == 0)
        // The untouched copy still loads its own data.
        #expect(original.data?.fields.first?.name == "Region")
    }
}
