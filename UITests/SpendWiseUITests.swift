import XCTest

/// Taps through the real app on the simulator (CI's `xcodebuild test`), with demo data and the
/// demo AI (no server). Each test starts the app afresh.
final class SpendWiseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String, language: String = "en", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ar" ? "ar_LB" : "en_US",
                               "-SpendWiseDemo", "YES", "-SpendWiseScreen", screen] + extra
        app.launch()
        return app
    }

    private func tapWhenReady(_ element: XCUIElement, _ timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) not found", file: file, line: line)
        element.tap()
    }

    /// The whole shopping loop: a new list, items added, ticked, finished, found under Completed.
    func testNewListAddItemsTickAndFinish() {
        let app = launch("home_empty")
        tapWhenReady(app.buttons["newList"])
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Weekend shop")
        tapWhenReady(app.buttons["confirmList"])
        // The new list opens; add two items from the sheet that stays open
        tapWhenReady(app.buttons["addItem"])
        let item = app.textFields["itemName"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        item.typeText("Milk\n")
        XCTAssertTrue(app.staticTexts["Added Milk"].waitForExistence(timeout: 5))
        item.typeText("Bread\n")
        XCTAssertTrue(app.staticTexts["Added Bread"].waitForExistence(timeout: 5))
        tapWhenReady(app.buttons["Close"])
        XCTAssertTrue(app.staticTexts["To buy · 2"].waitForExistence(timeout: 5))
        // Tick both: the list offers to finish
        app.buttons["Milk"].tap()
        app.buttons["Bread"].tap()
        XCTAssertTrue(app.staticTexts["In cart · 2"].waitForExistence(timeout: 5))
        tapWhenReady(app.buttons["finish"])
        XCTAssertTrue(app.staticTexts["Bought · 2"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["Completed · 1"].tap()
        XCTAssertTrue(app.buttons["list_Weekend shop"].waitForExistence(timeout: 5))
    }

    /// Deleting an item offers Undo, which puts it back.
    func testDeleteThenUndo() {
        let app = launch("list")
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).element(boundBy: 0)
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        let label = remove.label
        let itemName = String(label.dropFirst("Remove ".count))
        remove.tap()
        XCTAssertTrue(app.staticTexts["Removed \(itemName)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[label].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5))
    }

    /// Quick add: typed, the AI's review (demo answers), saved as lists.
    func testQuickAddTypedReviewAndSave() {
        let app = launch("home")
        tapWhenReady(app.staticTexts["What did you spend on?"])
        let text = app.descendants(matching: .any)["quickAddText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("filled gas for 40, milk and bread at Spinneys, need eggs")
        tapWhenReady(app.buttons["quickAddSend"])
        XCTAssertTrue(app.staticTexts["Check and save"].waitForExistence(timeout: 10))
        tapWhenReady(app.buttons["saveQuickAdd"])
        XCTAssertTrue(app.staticTexts["Saved 3 lists"].waitForExistence(timeout: 8))
    }

    /// The currency chosen in Settings shows on Home.
    func testCurrencyShowsOnHome() {
        let app = launch("settings")
        tapWhenReady(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Currency'")).firstMatch)
        tapWhenReady(app.buttons["€"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let card = app.buttons["monthCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("€"), card.label)
    }

    /// The welcome's language switch turns the app to Arabic at once.
    func testWelcomeLanguageSwitch() {
        let app = launch("welcome")
        XCTAssertTrue(app.staticTexts["Welcome to SpendWise"].waitForExistence(timeout: 8))
        tapWhenReady(app.buttons["welcomeLanguage"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'SpendWise'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Welcome to SpendWise"].exists)
        XCTAssertTrue(app.buttons["welcomeLanguage"].label.contains("English"))
    }

    /// Arabic from the phone's language: Home reads right to left with Western digits.
    func testArabicHome() {
        let app = launch("home", language: "ar")
        let card = app.buttons["monthCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(card.label.contains("المصروف في"), card.label)
        XCTAssertTrue(app.buttons["newList"].label.contains("قائمة جديدة"))
        // Amounts keep Western digits
        XCTAssertNotNil(card.label.range(of: "\\$[0-9]", options: .regularExpression), card.label)
        XCTAssertNil(card.label.range(of: "[٠-٩]", options: .regularExpression), card.label)
    }

    /// The welcome ends in the guide: Home asks for the first list.
    func testWelcomeLeadsToGuide() {
        let app = launch("welcome")
        for _ in 0..<3 { tapWhenReady(app.buttons["welcomeNext"]) }
        XCTAssertTrue(app.staticTexts["Your currency"].waitForExistence(timeout: 5))
        tapWhenReady(app.buttons["welcomeNext"])
        XCTAssertTrue(app.staticTexts["Make your first list"].waitForExistence(timeout: 5))
    }

    /// Insights: a category opens to the lists behind it, and a list opens.
    func testInsightsCategoryOpensItsLists() {
        let app = launch("insights")
        let groceries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Groceries'")).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 8))
        groceries.tap()
        let lists = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' lists'")).firstMatch
        XCTAssertTrue(lists.waitForExistence(timeout: 5))
    }

    /// Free: receipts open the Upgrade page instead of the camera.
    func testFreeReceiptOpensUpgrade() {
        let app = launch("home_free")
        tapWhenReady(app.buttons["Scan receipt (Premium)"])
        XCTAssertTrue(app.buttons["getPremium"].waitForExistence(timeout: 5))
        app.buttons["getPremium"].tap()
        XCTAssertTrue(app.staticTexts["Premium isn't on sale yet. It's coming soon!"].waitForExistence(timeout: 5))
    }

    /// Renaming a list from its title.
    func testRenameList() {
        let app = launch("list")
        let title = app.navigationBars.buttons["Weekly groceries"]
        tapWhenReady(title)
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Big shop")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Big shop"].waitForExistence(timeout: 5))
    }

    /// Sums in price boxes: the result replaces the sum.
    func testPriceBoxDoesSums() {
        let app = launch("list_add")
        let item = app.textFields["itemName"]
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        item.tap()
        item.typeText("Gas")
        let price = app.textFields.element(boundBy: 3)
        price.tap()
        price.typeText("89500")
        app.buttons["÷"].tap()
        price.typeText("3")
        XCTAssertTrue(app.staticTexts["= 29833.33"].waitForExistence(timeout: 5))
    }
}
