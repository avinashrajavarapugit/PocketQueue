import XCTest

@MainActor
final class PocketQueueUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            app.launchEnvironment["POCKETQUEUE_TEST_ID"] = UUID().uuidString
            app.launch()
        }
    }

    func testSaveSearchFavoriteReadAndRelaunch() {
        saveLink("https://example.com/reading", note: "Learn Swift actors")
        let article = app.staticTexts["Saved article from example.com"]
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        article.tap()
        XCTAssertTrue(app.buttons["openOriginalButton"].waitForExistence(timeout: 3))
        app.buttons["toggleFavoriteButton"].tap()
        app.buttons["toggleReadButton"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Read"].tap()
        XCTAssertTrue(article.waitForExistence(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 5))
        app.buttons["All"].tap()
        XCTAssertTrue(article.waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("actors")
        XCTAssertTrue(article.exists)
    }

    func testFailedPreviewStillSavesAndAllowsNotesEditing() throws {
        saveLink("https://preview-fails.example/article", note: "Keep this")
        let article = app.staticTexts["preview-fails.example"].firstMatch
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        article.tap()
        XCTAssertTrue(app.staticTexts["metadataStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keep this"].exists)
        app.buttons["editNotesButton"].tap()
        let note = app.descendants(matching: .any).matching(identifier: "editNoteField").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3))
        note.tap()
        note.typeText(" for tomorrow")
        let editedNote = try XCTUnwrap(note.value as? String)
        XCTAssertTrue(editedNote.contains("for tomorrow"))
        app.buttons["saveNotesButton"].tap()
        XCTAssertTrue(app.staticTexts[editedNote].waitForExistence(timeout: 3))
    }

    func testInvalidURLDoesNotDismissTheForm() {
        app.buttons["addBookmarkButton"].tap()
        let input = app.textFields["urlField"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("javascript:alert(1)")
        app.buttons["confirmSaveButton"].tap()
        XCTAssertTrue(app.staticTexts["saveError"].waitForExistence(timeout: 3))
        XCTAssertTrue(input.exists)
    }

    func testDeleteRequiresConfirmation() {
        saveLink("https://example.com/delete")
        let article = app.staticTexts["Saved article from example.com"]
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        article.tap()
        app.swipeUp()
        app.buttons["deleteBookmarkButton"].tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.staticTexts["Your next good read starts here"].waitForExistence(timeout: 5))
    }

    func testShareExtensionWritesToTheRealSharedLibrary() {
        let url = "https://share-test.example/\(UUID().uuidString)"
        saveLink(url)
        let article = app.staticTexts["Saved article from share-test.example"]
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        article.tap()
        app.swipeUp()
        app.buttons["shareBookmarkButton"].tap()
        let shareAction = app.cells.matching(
            NSPredicate(format: "label == %@ OR label == %@", "PocketQueue", "Save to PocketQueue")
        ).firstMatch
        if !shareAction.waitForExistence(timeout: 3) {
            app.cells["More"].firstMatch.tap()
        }
        XCTAssertTrue(shareAction.waitForExistence(timeout: 5), app.debugDescription)
        shareAction.tap()
        let extensionSave = app.buttons["shareSaveButton"]
        XCTAssertTrue(extensionSave.waitForExistence(timeout: 5), app.debugDescription)
        extensionSave.tap()
        XCTAssertTrue(extensionSave.waitForNonExistence(timeout: 5), app.debugDescription)
        app.terminate()
        app.launchArguments = []
        app.launch()
        let shared = app.staticTexts["share-test.example"].firstMatch
        XCTAssertTrue(shared.waitForExistence(timeout: 10))
        shared.tap()
        XCTAssertTrue(app.staticTexts[url].waitForExistence(timeout: 5))
    }

    func testWidgetStyleDeepLinkOpensTheSavedBookmark() throws {
        saveLink("https://example.com/deep-link")
        XCTAssertTrue(app.staticTexts["Saved article from example.com"].waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")
        ).firstMatch
        let id = String(row.identifier.dropFirst("bookmark-".count))
        XCTAssertNotNil(UUID(uuidString: id))
        let link = try XCTUnwrap(URL(string: "pocketqueue://bookmark/\(id)"))
        app.open(link)
        XCTAssertTrue(app.buttons["openOriginalButton"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["https://example.com/deep-link"].exists)
    }

    func testLibrarySupportsAccessibilityTextSizes() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["addBookmarkButton"].waitForExistence(timeout: 5))
        saveLink("https://example.com/large-type")
        let article = app.staticTexts["Saved article from example.com"]
        for _ in 0 ..< 5 where !article.exists {
            app.swipeUp()
        }
        XCTAssertTrue(article.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func saveLink(_ url: String, note: String = "") {
        app.buttons["addBookmarkButton"].tap()
        let input = app.textFields["urlField"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText(url)
        if !note.isEmpty {
            let noteInput = app.descendants(matching: .any).matching(identifier: "noteField").firstMatch
            noteInput.tap()
            noteInput.typeText(note)
        }
        app.buttons["confirmSaveButton"].tap()
    }
}
