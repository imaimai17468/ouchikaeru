# Swift engineering rules

The checked-in configuration is the source of truth:

- `.swift-format` defines whitespace, wrapping, imports, and syntax formatting.
- `.swiftlint.yml` detects bug-prone constructs and maintainability problems.
- `Scripts/format.sh` rewrites all Swift sources.
- `Scripts/check.sh` rejects formatting drift, lint findings, and unit-test failures.

## Code conventions

Follow the Swift API Design Guidelines. Prefer names that make a call site read clearly, describe side effects, and distinguish mutating work from value-returning work. Use terminology consistently across the shared model and all three clients.

Prefer immutable values and small value types. Model distinct states with an enum when more than two states are meaningful. Avoid force unwraps, force casts, force tries, and implicitly unwrapped optionals. Validate data at the boundary and return a typed error or optional value.

Keep functions focused enough to understand without comments. Extract parsing, selection, date normalization, and cache-validity decisions into testable functions. Comments explain constraints that the type system cannot express; they do not narrate the next line.

Use access control deliberately. Keep implementation details `private` unless another file or target consumes them. Shared public declarations should expose app concepts rather than API response details.

## Concurrency

UI-observed mutable state belongs to `@MainActor`. Values passed between tasks should conform to `Sendable`. Prefer child tasks and task groups for scoped parallel work. Store and cancel unstructured tasks when a newer refresh or destination replaces their result. Check request identity after suspension before publishing UI state.

Do not use `Task.detached` to bypass actor isolation. The lint configuration rejects `@preconcurrency`, `@unchecked Sendable`, and `nonisolated(unsafe)`; express actor isolation and `Sendable` behavior in the type structure.

## SwiftUI

Views describe presentation. Route parsing, selection, caching, networking, and time normalization stay outside view bodies. Give interactive controls clear labels and at least a 44-point hit area. Support Dynamic Type, VoiceOver labels, dark mode, reduced motion, and variable-length Japanese place names.

Use semantic system colors. Use monospaced digits for times that users compare. Preserve the position and dimensions of surrounding content while data refreshes. Animations must remain interruptible and must not be required for content to become visible.

## Verification

`Scripts/check.sh` is required after every Swift change. It intentionally fails when SwiftLint is unavailable. The project currently expects the Xcode toolchain's `swift format` command and SwiftLint 0.63 or newer. Its caches and Swift Package scratch build live under `/tmp` so coding agents do not write to user-level tool caches. SwiftPM's own sandbox remains enabled for regular local use; it is disabled only when the check already runs inside the Codex sandbox, which does not permit a nested sandbox.

The analyzer-only SwiftLint rules for unused imports and declarations require compiler logs, so the regular check does not claim to run them. Use `swiftlint analyze --compiler-log-path <clean-build-log>` for a dedicated audit after a clean build.

No source-level lint or formatter suppression comments are allowed, and a custom lint rule rejects them. The `opening_brace` rule accepts multiline declarations and conditions because that is the layout produced by swift-format; single-line brace spacing remains checked. Do not add entries to `disabled_rules`, baselines, or warning-suppression compiler flags.

Primary references:

- Swift API Design Guidelines: https://www.swift.org/documentation/api-design-guidelines/
- swift-format: https://github.com/swiftlang/swift-format
- swift-format configuration: https://github.com/swiftlang/swift-format/blob/main/Documentation/Configuration.md
- SwiftLint: https://github.com/realm/SwiftLint
- Swift concurrency migration: https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/
