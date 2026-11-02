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
        text.typeText("filled gas for 40, milk and bread at the supermarket, need eggs")
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

    /// The language page comes first: choosing العربية turns the app to Arabic at once and moves on.
    func testWelcomeLanguageSwitch() {
        let app = launch("welcome")
        let english = app.buttons["welcomeEnglish"]
        XCTAssertTrue(english.waitForExistence(timeout: 8))
        XCTAssertTrue(english.isSelected, "the phone's language is picked out")
        tapWhenReady(app.buttons["welcomeArabic"])
        // The pager, in Arabic: its small switch now offers English back
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'welcomeLanguage' AND label CONTAINS 'English'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Welcome to SpendWise"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'SpendWise'")).firstMatch.exists)
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

    /// The welcome ends in the guide: language, three pages, currency, then Not now on the
    /// sign-in page, and Home asks for the first list.
    func testWelcomeLeadsToGuide() {
        let app = launch("welcome")
        tapWhenReady(app.buttons["welcomeEnglish"])
        for _ in 0..<3 { tapWhenReady(app.buttons["welcomeNext"]) }
        XCTAssertTrue(app.staticTexts["Your currency"].waitForExistence(timeout: 5))
        tapWhenReady(app.buttons["welcomeNext"])
        tapWhenReady(app.buttons["welcomeNotNow"])
        XCTAssertTrue(app.staticTexts["Make your first list"].waitForExistence(timeout: 5))
    }

    /// A fresh install in both languages: the language page, then the sign-in page with Apple's
    /// button above Google's; each goes through "Your data in the cloud"; Not now goes on.
    func testWelcomeSignInPageInBothLanguages() {
        for language in ["en", "ar"] {
            let app = launch("welcome", language: language)
            let mine = app.buttons[language == "ar" ? "welcomeArabic" : "welcomeEnglish"]
            XCTAssertTrue(mine.waitForExistence(timeout: 8), "\(language): no language page")
            XCTAssertTrue(mine.isSelected, "\(language): the phone's language isn't picked out")
            mine.tap()
            for _ in 0..<4 { tapWhenReady(app.buttons["welcomeNext"]) }
            let apple = app.descendants(matching: .any)["appleSignIn"].firstMatch
            let google = app.buttons["welcomeGoogle"]
            XCTAssertTrue(apple.waitForExistence(timeout: 5), "\(language): no Apple button")
            XCTAssertTrue(google.exists, "\(language): no Google button")
            XCTAssertLessThan(apple.frame.minY, google.frame.minY, "\(language): Apple's button must come first")
            XCTAssertGreaterThanOrEqual(apple.frame.width, google.frame.width * 0.8, "\(language): Apple's button as prominent")
            for button in [google, apple] {
                button.tap()
                tapWhenReady(app.buttons["signInCancel"])
                XCTAssertTrue(waitGone(app.buttons["signInCancel"]), "\(language): the notice stays")
            }
            tapWhenReady(app.buttons["welcomeNotNow"])
            XCTAssertTrue(app.buttons["newList"].waitForExistence(timeout: 5), "\(language): Not now didn't go on")
            app.terminate()
        }
    }

    /// Signed in from the welcome: "Signed in as …" and Make my first list.
    func testWelcomeSignedIn() {
        for language in ["en", "ar"] {
            let app = launch("welcome_signed_in", language: language)
            XCTAssertTrue(app.descendants(matching: .any)["welcomeSignedIn"].firstMatch.waitForExistence(timeout: 8), "\(language)")
            XCTAssertFalse(app.buttons["welcomeNotNow"].exists)
            tapWhenReady(app.buttons["welcomeNext"])
            XCTAssertTrue(app.buttons["newList"].waitForExistence(timeout: 5), "\(language)")
            app.terminate()
        }
    }

    /// Insights: a category opens to the lists behind it, and a list opens.
    func testInsightsCategoryOpensItsLists() {
        let app = launch("insights")
        XCTAssertTrue(app.staticTexts["Spending by month"].waitForExistence(timeout: 8))
        // The breakdown is below the fold, and the screen builds rows only as they scroll in
        let category = app.buttons.matching(identifier: "categoryRow").firstMatch
        for _ in 0..<8 where !(category.exists && category.isHittable) { app.swipeUp() }
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        // Bring the row up from the bottom edge so the lists it opens have room. A tap while the
        // scroll still glides only stops it, so let it settle first
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        category.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Hide lists'")).firstMatch.waitForExistence(timeout: 5))
        // The lists behind the biggest category (Car: the gas fill-ups) show under it, and one opens
        let list = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Gas fill-up'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        if !list.isHittable { app.swipeUp(); Thread.sleep(forTimeInterval: 1.5) }
        list.tap()
        XCTAssertTrue(app.buttons["listTitle"].waitForExistence(timeout: 5))
    }

    /// Sign in with Apple (guideline 4.8): in Settings → Sync across devices, above Google's and
    /// at least as wide, in both languages.
    func testAppleSignInSitsAboveGoogle() {
        for language in ["en", "ar"] {
            let app = launch("settings", language: language)
            let apple = app.descendants(matching: .any)["appleSignIn"].firstMatch
            let google = app.descendants(matching: .any)["signIn"].firstMatch
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
            for _ in 0..<6 where !(google.exists && google.isHittable) { app.swipeUp() }
            XCTAssertTrue(apple.waitForExistence(timeout: 3), "\(language): no Apple button")
            XCTAssertTrue(google.exists, "\(language): no Google sign-in")
            XCTAssertLessThan(apple.frame.minY, google.frame.minY, "\(language): Apple's button must come first")
            XCTAssertGreaterThanOrEqual(apple.frame.width, google.frame.width * 0.8, "\(language): Apple's button as prominent")
            app.terminate()
        }
    }

    // MARK: Another account's lists (FEATURES.md §6.3) and signing out (§6.1), English and Arabic

    private func listsShown(_ app: XCUIApplication, _ timeout: TimeInterval = 5) -> Bool {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'list_'")).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Add them: the phone's lists stay and go to the new account.
    func testOtherAccountAddThem() {
        for language in ["en", "ar"] {
            let app = launch("other_account", language: language)
            let add = app.buttons["otherAccountAdd"]
            tapWhenReady(add)
            XCTAssertTrue(waitGone(add), "\(language): the question stays")
            XCTAssertTrue(listsShown(app), "\(language): the lists went")
            app.terminate()
        }
    }

    /// Start with this account's lists: a confirmation, then the phone's lists are removed.
    func testOtherAccountStartFresh() {
        for language in ["en", "ar"] {
            let app = launch("other_account", language: language)
            tapWhenReady(app.buttons["otherAccountFresh"])
            XCTAssertTrue(app.buttons["otherAccountBackup"].waitForExistence(timeout: 5), "\(language): no Back up first")
            // Back returns to the choices; then remove for real
            tapWhenReady(app.buttons["otherAccountBack"])
            tapWhenReady(app.buttons["otherAccountFresh"])
            let remove = app.buttons["otherAccountRemove"]
            tapWhenReady(remove)
            XCTAssertTrue(waitGone(remove), "\(language): the question stays")
            XCTAssertFalse(listsShown(app, 2), "\(language): the phone's lists are still there")
            app.terminate()
        }
    }

    /// Cancel: signs out again; nothing changes on the phone.
    func testOtherAccountCancel() {
        for language in ["en", "ar"] {
            let app = launch("other_account", language: language)
            let cancel = app.buttons["otherAccountCancel"]
            tapWhenReady(cancel)
            XCTAssertTrue(waitGone(cancel), "\(language): the question stays")
            XCTAssertTrue(listsShown(app), "\(language): the lists went")
            app.terminate()
        }
    }

    /// Sign out: Keep lists on this phone is the default; Remove them from this phone empties it.
    func testSignOutKeepOrRemove() {
        for language in ["en", "ar"] {
            for remove in [false, true] {
                let app = launch("sign_out", language: language)
                XCTAssertTrue(app.buttons["signOutKeep"].waitForExistence(timeout: 8), "\(language): no choice")
                XCTAssertTrue(app.buttons["signOutKeep"].isSelected, "\(language): Keep isn't the default")
                if remove { app.buttons["signOutRemove"].tap() }
                tapWhenReady(app.buttons["signOutConfirm"])
                // Signed out: Settings offers signing in again
                let signIn = app.descendants(matching: .any)["signIn"].firstMatch
                for _ in 0..<4 where !signIn.exists { app.swipeUp() }
                XCTAssertTrue(signIn.waitForExistence(timeout: 5), "\(language): still signed in")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertEqual(listsShown(app, remove ? 2 : 5), !remove, "\(language) remove=\(remove)")
                app.terminate()
            }
        }
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
        tapWhenReady(app.buttons["listTitle"])
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Big shop")
        app.alerts.buttons["Rename"].tap()
        let renamed = app.buttons.matching(NSPredicate(format: "identifier == 'listTitle' AND label == 'Big shop'")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
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
