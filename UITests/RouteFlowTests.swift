import XCTest

final class RouteFlowTests: XCTestCase {
    func testRegisterDestinationAndDisplayRealRoute() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        if app.buttons["目的地を登録"].waitForExistence(timeout: 5) {
            app.buttons["目的地を登録"].tap()
            let address = app.textFields["目的地の住所を入力"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.tap()
            address.typeText("東金")
            let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "place-result-")).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 30), "住所検索の候補が表示されない")
            first.tap()
            let save = app.buttons["この住所を登録"]
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            save.tap()
        }

        XCTAssertTrue(app.buttons["再読み込み"].waitForExistence(timeout: 100), "経路と終電の更新が完了しない")
        XCTAssertFalse(app.staticTexts["route-error-message"].exists, "経路取得エラー: \(app.debugDescription)")
        let arrival = app.staticTexts["final-arrival-time"]
        XCTAssertTrue(arrival.waitForExistence(timeout: 90), "経路取得が完了しない: \(app.debugDescription)")
        if app.staticTexts["東金"].firstMatch.exists {
            XCTAssertFalse(app.staticTexts["甲府"].firstMatch.exists, "東京→東金で途中比較の大回り経路が採用されている")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "実APIで取得した東京から目的地への経路"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.swipeUp()
        XCTAssertTrue(app.buttons["目的地を変更"].isHittable, "目的地変更が上部に固定されていない")
        let refresh = app.buttons["再読み込み"]
        XCTAssertTrue(refresh.isHittable, "スクロール後に更新できない")
        refresh.tap()
        let progress = app.progressIndicators["route-loading-progress"]
        // Cached refreshes can finish before XCTest takes its next snapshot.
        if progress.waitForExistence(timeout: 2) {
            XCTAssertTrue(progress.isHittable, "プログレスバーが画面外にある")
        } else {
            XCTAssertTrue(refresh.exists, "進行状況も更新完了も表示されない")
        }
        XCTAssertTrue(refresh.waitForExistence(timeout: 100), "手動更新が完了しない")
        XCTAssertFalse(app.staticTexts["route-error-message"].exists, "手動更新が失敗した: \(app.debugDescription)")

        app.terminate()
        app.launch()
        XCTAssertTrue(arrival.waitForExistence(timeout: 10), "再起動後に目的地と経路が保持されない")
        XCTAssertFalse(app.buttons["目的地を登録"].exists)
    }
}
