// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest

/// SwiftUI behaviours that UI tests rely on, each checked the way it works on
/// an iPhone. They run unchanged in a simulator and with `simless test ui`.
final class BehaviorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ lab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SimlessDemoLab", lab]
        app.launch()
        return app
    }

    /// A Button inside a view with its own `onTapGesture` gets the tap, not the outer view.
    @MainActor
    func testTheInnerButtonWinsOverTheOuterTapGesture() throws {
        let app = launch("gestures")
        let counts = app.staticTexts["lab.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        app.buttons["lab.inner"].tap()
        XCTAssertEqual(counts.label, "inner 1 · outer 0")
    }

    /// The same for a plain-style Button that VoiceOver reads as one element.
    @MainActor
    func testAnInnerPlainButtonWinsOverTheOuterTapGesture() throws {
        let app = launch("gestures")
        let counts = app.staticTexts["lab.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        app.buttons["lab.chip"].tap()
        XCTAssertEqual(counts.label, "inner 1 · outer 0")
    }

    /// The same inside a ScrollView, where touches reach the content through the scroll view.
    @MainActor
    func testAnInnerPlainButtonWinsInsideAScrollView() throws {
        let app = launch("gestures-scroll")
        let counts = app.staticTexts["lab.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        app.buttons["lab.chip"].tap()
        XCTAssertEqual(counts.label, "inner 1 · outer 0")
        app.buttons["lab.inner"].tap()
        XCTAssertEqual(counts.label, "inner 2 · outer 0")
    }

    /// A tap next to the button reaches the outer gesture.
    @MainActor
    func testATapBesideTheButtonReachesTheOuterGesture() throws {
        let app = launch("gestures")
        let counts = app.staticTexts["lab.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        app.staticTexts["Tap the button, or anywhere else in the card"].tap()
        XCTAssertEqual(counts.label, "inner 0 · outer 1")
    }

    /// `.accessibilityElement(children: .combine)` keeps the children's identifiers findable.
    @MainActor
    func testACombinedElementsChildIdentifierIsFound() throws {
        let app = launch("combined")
        XCTAssertTrue(app.descendants(matching: .any)["lab.combined.outer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["lab.combined.inner"].exists)
        // A button's label content that contains its own elements is found inside it.
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Quarterly Note")).firstMatch.exists)
    }

    /// Three swipes to the right take a scrolling chart weeks back, not days.
    @MainActor
    func testSwipesScrollAChartBackByWeeks() throws {
        let app = launch("chart")
        let position = app.staticTexts["lab.chart.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let before = position.label
        let chart = app.descendants(matching: .any)["lab.chart"].firstMatch
        for _ in 0..<3 { chart.swipeRight() }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        guard let start = formatter.date(from: before), let end = formatter.date(from: position.label) else {
            return XCTFail("Couldn't read the chart position: \(before) → \(position.label)")
        }
        let days = start.timeIntervalSince(end) / 86_400
        XCTAssertGreaterThan(days, 21, "Three swipes scrolled \(Int(days)) days (\(before) → \(position.label))")
    }

    /// Two slow swipes take the chart back by more than two weeks.
    @MainActor
    func testSlowSwipesScrollAChartBackByWeeks() throws {
        let app = launch("chart")
        let position = app.staticTexts["lab.chart.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let before = position.label
        let chart = app.descendants(matching: .any)["lab.chart"].firstMatch
        chart.swipeRight(velocity: .slow)
        chart.swipeRight(velocity: .slow)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        guard let start = formatter.date(from: before), let end = formatter.date(from: position.label) else {
            return XCTFail("Couldn't read the chart position: \(before) → \(position.label)")
        }
        let days = start.timeIntervalSince(end) / 86_400
        XCTAssertGreaterThan(days, 14, "Two slow swipes scrolled \(Int(days)) days (\(before) → \(position.label))")
    }

    /// After a scrub, slow swipes still scroll, and a scrub after them selects a day back there.
    @MainActor
    func testScrubbingAfterScrollingBackSelectsADayBackThere() throws {
        let app = launch("chart")
        let position = app.staticTexts["lab.chart.position"]
        let selected = app.staticTexts["lab.chart.selected"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let chart = app.descendants(matching: .any)["lab.chart"].firstMatch
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
            .press(forDuration: 0.8, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.4)
        let first = selected.label
        XCTAssertNotEqual(first, "none", "The first scrub selected nothing")
        let before = position.label
        chart.swipeRight(velocity: .slow)
        chart.swipeRight(velocity: .slow)
        XCTAssertNotEqual(position.label, before, "The swipes didn't scroll")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
            .press(forDuration: 0.8, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.4)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        guard let a = formatter.date(from: first), let b = formatter.date(from: selected.label) else {
            return XCTFail("Couldn't read the selections: \(first) → \(selected.label)")
        }
        XCTAssertGreaterThan(a.timeIntervalSince(b) / 86_400, 14, "The second scrub selected \(selected.label), after \(first)")
    }

    /// A Stepper's increment button works (and doesn't crash the app).
    @MainActor
    func testAStepperIncrements() throws {
        let app = launch("stepper")
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 10))
        stepper.buttons["Increment"].tap()
        XCTAssertTrue(stepper.label.hasSuffix("4"), "The stepper says \(stepper.label)")
    }

    /// Swiping up until a row is hittable reaches every row: no swipe jumps past one.
    @MainActor
    func testSwipingUpReachesEveryRow() throws {
        let app = launch("list")
        XCTAssertTrue(app.buttons["Row 0"].waitForExistence(timeout: 10))
        for row in [12, 25, 38, 47] {
            let button = app.buttons["Row \(row)"]
            var swipes = 0
            while !button.isHittable && swipes < 10 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(button.isHittable, "Swiping up jumped past Row \(row)")
        }
    }

    /// A submenu in a context menu opens its own items.
    @MainActor
    func testAContextMenuSubmenuOpens() throws {
        let app = launch("menu")
        let task = app.staticTexts["Task"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Tomorrow"].exists, "The submenu's items showed before it was opened")
        app.buttons["Snooze"].tap()
        app.buttons["Tomorrow"].tap()
        XCTAssertEqual(app.staticTexts["lab.chosen"].label, "Tomorrow")
    }

    /// A submenu in a Menu opens its own items.
    @MainActor
    func testAMenuSubmenuOpens() throws {
        let app = launch("menu")
        app.buttons["Options"].tap()
        app.buttons["Style"].tap()
        app.buttons["Detailed"].tap()
        XCTAssertEqual(app.staticTexts["lab.chosen"].label, "Detailed")
    }

    /// A Button in a Menu keeps its accessibility identifier.
    @MainActor
    func testAMenuItemKeepsItsIdentifier() throws {
        let app = launch("menu")
        app.buttons["Options"].tap()
        XCTAssertTrue(app.buttons["lab.rename"].waitForExistence(timeout: 5))
        app.buttons["lab.rename"].tap()
        XCTAssertEqual(app.staticTexts["lab.chosen"].label, "Rename")
    }

    /// A menu Picker's choice saved with @AppStorage survives a relaunch.
    @MainActor
    func testAMenuPickerChoiceSurvivesARelaunch() throws {
        var app = launch("menu")
        app.buttons["lab.theme"].tap()
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons["lab.theme"].label.contains("Dark") || (app.buttons["lab.theme"].value as? String ?? "").contains("Dark"),
                      "The picker shows \(app.buttons["lab.theme"].label) \(app.buttons["lab.theme"].value ?? "")")
        app.terminate()
        app = launch("menu")
        app.buttons["lab.theme"].tap()
        app.buttons["Light"].tap()
        app.terminate()
        app = launch("menu")
        XCTAssertTrue(app.buttons["lab.theme"].label.contains("Light") || (app.buttons["lab.theme"].value as? String ?? "").contains("Light"),
                      "After a relaunch the picker shows \(app.buttons["lab.theme"].label) \(app.buttons["lab.theme"].value ?? "")")
    }

    /// A predicate expectation on a switch's value and on a query's count completes.
    @MainActor
    func testPredicateExpectationsComplete() throws {
        let app = launch("waits")
        let toggle = app.switches["lab.auto"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let start = toggle.value as? String
        XCTAssertNotNil(start, "The switch's value isn't a string: \(String(describing: toggle.value))")
        let next = start == "1" ? "0" : "1"
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let flipped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", next), object: toggle)
        XCTAssertEqual(XCTWaiter().wait(for: [flipped], timeout: 5), .completed, "The switch reports \(String(describing: toggle.value))")

        let chips = app.buttons.matching(identifier: "lab.chip")
        let before = chips.count
        chips.firstMatch.tap()
        let fewer = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count < %d", before), object: chips)
        XCTAssertEqual(XCTWaiter().wait(for: [fewer], timeout: 5), .completed, "\(chips.count) chips left of \(before)")
    }

    /// A long press in a text field offers Select All, and typing then replaces the text.
    @MainActor
    func testATextFieldsEditMenuSelectsAll() throws {
        let app = launch("waits")
        let field = app.textFields["lab.link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("not a url")
        field.press(forDuration: 1.0)
        XCTAssertTrue(app.menuItems["Select All"].waitForExistence(timeout: 2))
        app.menuItems["Select All"].tap()
        field.typeText("example.com")
        XCTAssertEqual(field.value as? String, "example.com")
    }

    /// A menu item that raises a confirmation dialog: the dialog shows, and Cancel works.
    @MainActor
    func testAMenuItemsConfirmationDialogShows() throws {
        let app = launch("menu")
        app.buttons["Options"].tap()
        app.buttons["Style"].tap()
        app.buttons["Bullet List"].tap()
        let cancel = app.buttons["lab.cancel"]
        XCTAssertTrue(app.buttons["lab.confirm"].waitForExistence(timeout: 5), "The confirmation dialog didn't show")
        XCTAssertTrue(cancel.exists, "The dialog has no Cancel")
        cancel.tap()
        XCTAssertEqual(app.staticTexts["lab.chosen"].label, "Kept")
    }

    /// A skipped test keeps its reason in the results.
    @MainActor
    func testASkipKeepsItsReason() throws {
        try XCTSkipUnless(false, "The lab only covers this on an iPad")
    }

    /// A tab view's tabs are buttons: in a tab bar on an iPhone, and on an iPad
    /// (where XCUITest shows no tab bar around the floating one's tabs, checked
    /// in an iPad simulator) right in the app.
    @MainActor
    func testATabBarsTabsAreButtons() throws {
        let app = launch("tabs")
        let iPad = app.windows.firstMatch.frame.width >= 600
        let profile = iPad ? app.buttons["Profile"].firstMatch : app.tabBars.buttons["Profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "No Profile tab button")
        if iPad { XCTAssertFalse(app.tabBars.firstMatch.exists, "An iPad's floating tab bar isn't a tab bar to XCUITest") }
        profile.tap()
        XCTAssertTrue(app.staticTexts["Posts"].waitForExistence(timeout: 5), "The Profile tab didn't open")
    }
}
