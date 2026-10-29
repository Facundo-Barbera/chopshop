import XCTest
@testable import ChopshopNative

/// Nombres de escritorio: hash determinista, sin repetir en una oficina, estables cuando entran o salen otros.
/// Los valores fijos salen de una implementación de referencia de FNV-1a 64 en Python con el mismo `pool`.
final class DeskNamesTests: XCTestCase {
    func testFNVMatchesReferenceVectors() {
        // vectores publicados de FNV-1a 64
        XCTAssertEqual(DeskNames.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(DeskNames.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(DeskNames.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testNameIsDeterministic() {
        XCTAssertEqual(DeskNames.name(for: "task-1"), DeskNames.name(for: "task-1"))
        // fnv("task-1") = 820307580712406534, % 64 = 6
        XCTAssertEqual(DeskNames.fnv1a64("task-1"), 820_307_580_712_406_534)
        XCTAssertEqual(DeskNames.name(for: "task-1"), "Valeria")
        XCTAssertEqual(DeskNames.name(for: "thread-abc"), "Amir")
        XCTAssertEqual(DeskNames.name(for: "desk-42"), "Max")
        XCTAssertTrue(DeskNames.pool.contains(DeskNames.name(for: "cualquier-cosa")))
    }

    func testPoolHasNoDuplicates() {
        XCTAssertEqual(DeskNames.pool.count, 64)
        XCTAssertEqual(Set(DeskNames.pool).count, DeskNames.pool.count)
    }

    func testAssignIsUnique() {
        let ids: [String] = (1...40).map { "thread-\($0)" }
        let names = DeskNames.assign(ids)
        XCTAssertEqual(names.count, 40)
        XCTAssertEqual(Set(names.values).count, 40)
        XCTAssertTrue(names.values.allSatisfy { DeskNames.pool.contains($0) })
    }

    func testAssignProbesOnCollision() {
        // t1 y t21 prefieren el mismo nombre (posición 22, «Inés»): gana t1 (va antes) y t21 toma el siguiente
        XCTAssertEqual(DeskNames.name(for: "t1"), "Inés")
        XCTAssertEqual(DeskNames.name(for: "t21"), "Inés")
        XCTAssertEqual(DeskNames.assign(["t21", "t1"]), ["t1": "Inés", "t21": "Joaquín"])
    }

    func testAssignIsStableWhenUnrelatedDeskLeaves() {
        // t1..t4 no chocan (posiciones 22, 35, 48, 21)
        let all = DeskNames.assign(["t1", "t2", "t3", "t4"])
        XCTAssertEqual(all, ["t1": "Inés", "t2": "Luca", "t3": "Nina", "t4": "Martín"])
        let without = DeskNames.assign(["t1", "t2", "t4"])
        for (id, name) in without { XCTAssertEqual(all[id], name, id) }
    }

    func testAssignOverflowGetsUniqueSuffixedNames() {
        let n: Int = DeskNames.pool.count + 6
        let ids: [String] = (0..<n).map { "o\($0)" }
        let names = DeskNames.assign(ids)
        XCTAssertEqual(names.count, n)
        XCTAssertEqual(Set(names.values).count, n)
        XCTAssertEqual(names.values.filter { DeskNames.pool.contains($0) }.count, DeskNames.pool.count)
        let extra = names.values.filter { !DeskNames.pool.contains($0) }
        XCTAssertEqual(extra.count, 6)
        XCTAssertTrue(extra.allSatisfy { $0.contains(" ") })
        XCTAssertEqual(DeskNames.assign(ids.reversed()), names)
    }

    func testAssignIgnoresOrderAndDuplicates() {
        let ids: [String] = (1...40).map { "thread-\($0)" }
        let names = DeskNames.assign(ids)
        XCTAssertEqual(DeskNames.assign(ids.reversed()), names)
        XCTAssertEqual(DeskNames.assign(ids + ids.prefix(5)), names)
    }
}
