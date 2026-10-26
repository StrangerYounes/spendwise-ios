import Foundation
import XCTest
@testable import SpendWiseCore

/// Local time, like Kotlin's Calendar.getInstance().apply { clear(); set(...) }.
func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Millis {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return Calendar.current.date(from: c)!.millis
}

/// A database set up like a fresh install (Groceries seeded), in memory.
func freshDatabase() throws -> AppDatabase { try AppDatabase(path: ":memory:") }

func fixture(_ name: String) throws -> String {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}

func XCTAssertClose(_ a: Double?, _ b: Double, _ accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("nil, expected \(b) \(message)", file: file, line: line) }
    XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
}
