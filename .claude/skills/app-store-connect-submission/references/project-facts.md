# Ouchikaeru submission facts

Use these as project-specific starting facts and verify them against the current repository and App Store Connect before submission.

## Identity

- App name: オウチカエル / Ouchikaeru
- App Store Connect app ID: `6811621694`
- iPhone bundle ID: `jp.ouchikaeru.app`
- Widget bundle ID: `jp.ouchikaeru.app.widget`
- Watch bundle ID: `jp.ouchikaeru.app.watchkitapp`
- App Group: `group.jp.ouchikaeru.app`
- App Store Connect app root: `https://appstoreconnect.apple.com/apps/6811621694/distribution`

Resolve the active version, build, and submission ID from App Store Connect on every run. Submission IDs and statuses are not stable facts.

## Product description

Ouchikaeru is a Japanese-language utility for people in Japan who repeatedly travel from their current position to one familiar destination such as home. It shows walking time, the next public-transit departure and arrival, transfers, the final walking segment, and the day's last train with the time by which the user should leave.

The iPhone app stores one destination locally. The Home Screen widget displays the last saved result. The Apple Watch app receives the destination and route snapshot from iPhone and can refresh with the Watch's location and network connection.

## Current access and business-model facts

At the time this reference was written:

- No account, login, registration, or account deletion flow.
- No user-generated content.
- No paid content, in-app purchase, subscription, advertising, or AI functionality.
- No demo credentials or sample files are required for the iPhone flow.
- Route search requires location access, network access, and current/destination coordinates within the supported Japan search bounds.
- The UI is Japanese. The feature set is the same across storefronts where distributed, but transit-data coverage is Japan-specific.
- The app is not a medical, financial, gambling, government, or other highly regulated service.

Re-check these claims with repository search before each submission.

## External services and platform facilities

- Transit API at `https://api.transit.ls8h.com/`: place, station, timetable, route, and last-train data. See `Sources/TransitCore/TransitAPI.swift`.
- Apple Core Location: obtains current-location updates. See `Shared/LocationProvider.swift`.
- Apple MapKit: destination search, reverse geocoding, and walking directions. See `iPhone/DestinationEditor.swift` and `Shared/MapWalkingProvider.swift`.
- WidgetKit, WatchConnectivity, and App Groups: local display and synchronization between iPhone, widget, and Watch. See `Widget/`, `Shared/WatchSync.swift`, and `Shared/SharedStore.swift`.

There were no third-party authentication, payment, analytics, advertising, or AI SDKs when this reference was written.

## Reviewer flow

1. Launch from the Home Screen and allow location access when prompted.
2. Open the destination editor.
3. Search for a public place in Japan, select it, and tap `この住所を登録`, or choose a point on the map.
4. Return to the main screen and wait for route and last-train results.
5. Use refresh to update the results.
6. Add the Ouchikaeru Home Screen widget after a result is available.
7. For Watch review, use a paired Watch and open the Watch app after iPhone synchronization.

Xcode's LLDB symbol resolution can leave a debug launch blank for several minutes. This is not representative of a customer launch. Install the app, stop Xcode, and launch from the device icon for review recording.
