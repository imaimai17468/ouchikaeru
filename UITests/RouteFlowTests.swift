import XCTest

final class RouteFlowTests: XCTestCase {
    func testAccessibilitySmoke() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let register = app.buttons["目的地を登録"]
        if register.waitForExistence(timeout: 5) {
            register.tap()
        } else {
            let editAddress = app.buttons["住所を変更"]
            XCTAssertTrue(editAddress.waitForExistence(timeout: 10))
            editAddress.tap()
        }

        let currentLocation = app.descendants(matching: .any)["destination-current-location"]
        let close = app.buttons["閉じる"]
        let search = app.textFields["目的地の住所を入力"]
        let selectMapCenter = app.buttons["地図の中心を選択"]
        for element in [currentLocation, close, search, selectMapCenter] {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(element.frame.width, 44)
            XCTAssertGreaterThanOrEqual(element.frame.height, 44)
        }

        selectMapCenter.tap()
        let save = app.buttons["この住所を登録"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
    }

    func testSelectCurrentLocationAsDestination() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let register = app.buttons["目的地を登録"]
        if register.waitForExistence(timeout: 5) {
            register.tap()
        } else {
            let loading = app.progressIndicators["route-loading-progress"]
            if loading.exists {
                let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
                XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 100), .completed, "経路更新が完了しない")
            }
            let editAddress = app.buttons["住所を変更"]
            XCTAssertTrue(editAddress.waitForExistence(timeout: 100), "住所変更画面を開けない")
            editAddress.tap()
        }

        let currentLocation = app.descendants(matching: .any)["destination-current-location"]
        XCTAssertTrue(currentLocation.waitForExistence(timeout: 5))
        let editorScreenshot = XCTAttachment(screenshot: app.screenshot())
        editorScreenshot.name = "住所編集画面"
        editorScreenshot.lifetime = .keepAlways
        add(editorScreenshot)
        currentLocation.tap()

        let save = app.buttons["この住所を登録"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "現在地の住所を確認できない: \(app.debugDescription)")
        save.tap()
        XCTAssertTrue(app.buttons["住所を変更"].waitForExistence(timeout: 10), "現在地を目的地として保存できない")
    }

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
