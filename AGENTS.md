# Agent instructions

Read [docs/swift-style.md](docs/swift-style.md) before editing Swift.

After changing Swift:

1. Run `Scripts/format.sh`.
2. Run `Scripts/check.sh`.
3. Run an Xcode build when the change touches the iPhone, Widget, Watch, entitlements, or project configuration.

Treat formatter and lint failures as code defects. Fix the code instead of adding inline disables. Change the shared configuration only when the project rule itself is wrong, and document the reason in `docs/swift-style.md`.

Keep UI state explicit. A view that displays remote data must handle loading, available, unavailable, and failure states without changing unrelated layout. Keep shared route behavior in `TransitCore`; iPhone, Widget, and Watch views consume the shared model.

Use structured concurrency. Isolate UI state to `@MainActor`, make values crossing isolation boundaries `Sendable`, retain cancellable tasks that can outlive a view action, and reject stale asynchronous results before publishing them.

Do not add generated build output, DerivedData, credentials, API responses containing user coordinates, or simulator state to the repository.
