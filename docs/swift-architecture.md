# Swift architecture rules

## Dependency direction

Dependencies flow from iPhone, Widget, and Watch presentation into their state models and platform adapters, then into `TransitCore`. `TransitCore` owns route preparation, selection, freshness, and last-train behavior. It must not import SwiftUI, WidgetKit, CoreLocation, MapKit, or WatchConnectivity.

Keep code in a target directory while only that target consumes it. Move code to `Shared` only when multiple Apple targets use the same platform implementation. Move behavior to `TransitCore` when it is meaningful without a device framework. A target must not import another target's implementation.

Define a protocol where domain logic crosses into location, time, persistence, transport, or network behavior. Inject that protocol into the state owner. Keep the concrete live adapter at the application composition boundary. Do not introduce an interface solely for a hypothetical implementation.

## State and side effects

Views are pure projections of input state. They do not read persistence, request location, perform network work, generate identity, or obtain the current time while deciding a branch. User events and scene lifecycle events call a `@MainActor` model, and that model coordinates side effects.

Represent mutually exclusive loading, available, unavailable, and failure conditions with an enum. Store the minimum state and derive display flags and labels from it. Preserve the previous successful value in states that must keep the surrounding layout stable.

Retain an unstructured task when it can outlive the initiating call. Cancel it when its destination or request is replaced, and check both cancellation and request identity after every suspension that precedes publication. Pass time into domain decisions through `WallClock` or an explicit `Date` parameter.

WatchConnectivity transports a versioned snapshot; it does not own route or screen state. Because `WCSession` has one delegate, its singleton is a platform boundary rather than shared mutable domain state. The receiving model validates and persists the snapshot before exposing it.

## Code boundaries

Split by responsibility and ownership, not by a line-count target. A useful extraction reduces the caller's decisions or isolates an external side effect. A file used once is acceptable when it owns one coherent concern. Avoid pass-through wrappers that add no policy, state, layout, or abstraction.

Keep target-specific presentation next to its feature. Keep generic visual primitives in `Shared` only when they have no target-specific behavior. Prefer narrow inputs over passing an entire model or response to a child view.

Comments explain a constraint the types and names cannot express. Prefer changing a name, type, or structure when that makes a comment unnecessary. A comment must describe the code that ships beside it, not an issue, review, or past decision.

## Testing

Every new branch must be reachable by a test that fails when that branch breaks. Put pure route behavior in `TransitCore` so Swift Package tests can exercise it without Apple UI frameworks. Use injected fakes for time, location, storage, transport, and network boundaries; do not add test-only setters or production branches.

Name a test with its condition and result. Keep one behavior and one primary assertion per test. Compare an `Equatable` result as a whole when its structure is the behavior under test. Treat an Xcode target build as a wiring check, not as a substitute for branch tests.

## Change partitioning

A feature is the smallest change that leaves the repository formatted, checked, buildable, and useful when committed alone. Changes that can be reverted independently belong in separate commits. Shared prerequisites land before the features that consume them. Stage named paths so unrelated workspace changes never enter a commit.
