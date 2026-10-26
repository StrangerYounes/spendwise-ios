import XCTest
@testable import SpendWiseCore

/// Android ParseAmountTest and ParseDecimalTest, ported, plus formatting and JSON checks.
final class ParseAmountTests: XCTestCase {
    func assertAmount(_ expected: Double, _ input: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let v = parseAmount(input) else { return XCTFail("nil for \(input)", file: file, line: line) }
        XCTAssertEqual(v, expected, accuracy: 1e-9, input, file: file, line: line)
    }

    func testPlainNumbersReadAsBefore() {
        assertAmount(3.5, "3,50")
        assertAmount(12, "١٢")
        XCTAssertFalse(isSum("-3"))
        assertAmount(-3, "-3")
    }

    func testSumsAreWorkedOut() {
        XCTAssertTrue(isSum("89500/3"))
        assertAmount(89500.0 / 3, "89500/3")
        assertAmount(89500.0 / 3, "89500 ÷ 3")
        assertAmount(3.25, "2×1.5+0.25")
        assertAmount(3.5, "(3+4)÷2")
        assertAmount(1, "3−2")
        assertAmount(7, "1+2*3")
        assertAmount(4.5, "1,5×3") // a comma is a decimal point in prices
        assertAmount(-1, "2*-0.5")
    }

    func testUnfinishedOrImpossibleSumsAreNil() {
        XCTAssertNil(parseAmount("4.2/"))
        XCTAssertNil(parseAmount("4/0"))
        XCTAssertNil(parseAmount("(3+4"))
        XCTAssertNil(parseAmount("3+4)"))
        XCTAssertNil(parseAmount("3++"))
        XCTAssertNil(parseAmount("2×"))
    }

    func testArabicDigitsInSums() {
        assertAmount(4, "٢×٢")
    }
}

final class ParseDecimalTests: XCTestCase {
    func testWesternDigitsWithAPointOrAComma() {
        XCTAssertEqual(parseDecimal("3.50"), 3.5)
        XCTAssertEqual(parseDecimal(" 3,50 "), 3.5)
    }

    func testDigitsFromAnArabicOrPersianKeyboard() {
        XCTAssertEqual(parseDecimal("٣٫٥٠"), 3.5)
        XCTAssertEqual(parseDecimal("3٫50"), 3.5)
        XCTAssertEqual(parseDecimal("١٢"), 12)
        XCTAssertEqual(parseDecimal("۱۲"), 12)
        XCTAssertEqual(parseDecimal("١٬٥٠٠"), 1500)
    }

    func testNotANumber() {
        XCTAssertNil(parseDecimal("abc"))
        XCTAssertNil(parseDecimal(""))
    }

    func testRatesTakeCommasAsThousands() {
        // A decimal comma would make 89,500 into 89.5 and every converted price 1,000 times too big
        XCTAssertEqual(parseRate("89,500"), 89500)
        XCTAssertEqual(parseRate("٨٩٬٥٠٠"), 89500)
        XCTAssertEqual(parseRate("1,500.5"), 1500.5)
        XCTAssertEqual(formatRate(89500), "89,500")
        XCTAssertEqual(formatRate(1.5), "1.5")
    }
}

final class FormattingTests: XCTestCase {
    func testMoneyAsJavaFormatsIt() {
        XCTAssertEqual(formatMoney("$", 1234.5), "$1,234.50")
        XCTAssertEqual(formatMoney("$", 0), "$0.00")
        XCTAssertEqual(formatMoney("$", -12.345), "$-12.35")
        XCTAssertEqual(formatMoney("L.L. ", 1_250_000, decimals: 0), "L.L. 1,250,000")
        // Java rounds the exact value half up: 0.125 is exact, so it goes up; 2.675 is 2.67499…
        XCTAssertEqual(formatMoney("$", 0.125), "$0.13")
        XCTAssertEqual(formatMoney("$", 2.675), "$2.67")
        XCTAssertEqual(formatMoney("$", 999.995), "$1,000.00")
    }

    func testUnitPricesKeepAThirdDecimal() {
        XCTAssertEqual(formatUnitPrice("$", 1.149), "$1.149")
        XCTAssertEqual(formatUnitPrice("$", 1.15), "$1.15")
    }

    func testQuantitiesAndPriceInputs() {
        XCTAssertEqual(formatQuantity(1), "1")
        XCTAssertEqual(formatQuantity(1.5), "1.5")
        XCTAssertEqual(formatQuantity(0.25), "0.25")
        XCTAssertEqual(formatQuantity(2.325), "2.33")
        XCTAssertEqual(formatPriceInput(nil), "")
        XCTAssertEqual(formatPriceInput(3), "3")
        XCTAssertEqual(formatPriceInput(3.5), "3.5")
        XCTAssertEqual(formatPriceInput(89500.0 / 3), "29833.33")
    }

    func testJavaRound() {
        XCTAssertEqual(javaRound(2.5), 3)
        XCTAssertEqual(javaRound(-2.5), -2)
        XCTAssertEqual(javaRound(1.4999), 1)
    }
}

final class JsonTests: XCTestCase {
    func testDoublesAreWrittenAsKotlinWritesThem() {
        XCTAssertEqual(JSON.format(40), "40.0")
        XCTAssertEqual(JSON.format(0.0088), "0.0088")
        XCTAssertEqual(JSON.format(89500), "89500.0")
        XCTAssertEqual(JSON.format(1e7), "1.0E7")
        XCTAssertEqual(JSON.format(0.0001), "1.0E-4")
        XCTAssertEqual(JSON.format(1.5e-5), "1.5E-5")
        XCTAssertEqual(JSON.format(-3.25), "-3.25")
        XCTAssertEqual(JSON.format(123456789.5), "1.234567895E8")
    }

    func testRoundTripKeepsOrderAndText() throws {
        let text = #"{"b":1,"a":[true,null,"x \"q\" \\ é 🚗"],"c":{"d":2.5}}"#
        let v = try JSON.parse(text)
        XCTAssertEqual(v.text, text)
        XCTAssertEqual(v["a"]?.array?[2].content, "x \"q\" \\ é 🚗")
    }

    func testUnicodeEscapesAndSurrogates() throws {
        XCTAssertEqual(try JSON.parse(#""A🚗""#).content, "A🚗")
        XCTAssertThrowsError(try JSON.parse("{"))
        XCTAssertThrowsError(try JSON.parse(#"{"a":1} x"#))
    }

    func testControlCharactersAreEscaped() {
        XCTAssertEqual(JSON.string("a\u{0012}b\n").text, #""a\u0012b\n""#)
    }

    func testPrettyPrintMatchesKotlinx() {
        let v = JSON.object([("a", .integer(1)), ("b", .array([.string("x")])), ("c", .array([]))])
        XCTAssertEqual(v.prettyText, "{\n    \"a\": 1,\n    \"b\": [\n        \"x\"\n    ],\n    \"c\": []\n}")
    }
}
