# Review response guidance

Mirror Apple's numbered questions. Replace bracketed values only with verified facts and remove sections Apple did not request.

## Information-needed template

```text
App Review Information – Ouchikaeru [version]

1. Physical-device screen recording
The requested recording is attached to this App Review message. It was captured on a physical [device model] running [OS version] and begins on the Home Screen before a cold launch. It demonstrates [verified flows visible in the recording].

2. Purpose, audience, and value
Ouchikaeru is a Japanese-language transit utility for people in Japan who repeatedly travel from their current location to a familiar destination such as home. It provides walking time, the next public-transit departure and arrival, transfer details, the final walking segment, and the day's last train including the time by which the user should leave. The iPhone app stores one destination locally; the widget shows the last route result; and the Apple Watch app synchronizes with iPhone and can refresh using Watch location and connectivity.

3. Setup and access instructions
No account, login, credentials, or sample files are required for the iPhone app.
a. Launch the app and allow location access.
b. Open the destination editor.
c. Search for a public place in Japan, select it, and tap “この住所を登録” (Register this address), or select a point on the map.
d. Wait for the main screen to display walking time, the next route, departure/arrival times, transfers, and last-train information.
e. Use refresh to update results.
f. Add the Ouchikaeru widget after obtaining a route. Use a paired Apple Watch to review Watch synchronization and refresh.

The app has no account registration/deletion, user-generated content, paid content, in-app purchases, subscriptions, advertising, or AI functionality.

4. External services and platforms
- Transit API (https://api.transit.ls8h.com/): transit places, stations, timetables, routes, and last-train data.
- Apple Core Location: current location.
- Apple MapKit: destination search, reverse geocoding, and walking directions.
- Apple WidgetKit, WatchConnectivity, and App Groups: local display and synchronization between iPhone, widget, and Watch.
There is no third-party authentication, payment processor, analytics SDK, advertising SDK, or AI service.

5. Regional differences
The feature set is the same in every storefront where the app is distributed. Transit search is limited to current locations and destinations within Japan because the underlying data coverage is Japan-specific. Outside the supported area, the app displays an unavailable-area message. The UI is Japanese.

6. Regulated industry and protected material
The app is not a highly regulated service and does not distribute protected third-party media. Transit data remains attributable to its providers, with provider information available through in-app links. No additional authorization credentials apply.
```

## Consistency checks

- Use `is attached` only after the attachment is visible in App Store Connect; use a future-tense sentence only in an unsent draft.
- List only flows actually visible in the recording.
- Verify the device OS against Apple's current public release pages on the recording date. A new major or security release can invalidate a recording made the previous day.
- Do not describe simulator footage as physical-device footage.
- Keep App Review Notes and the sent reply materially identical when Apple requests both.
