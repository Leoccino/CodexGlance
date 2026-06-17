# CodexGlance

Codex usage, at a glance.

CodexGlance is a tiny macOS menu bar app that shows the current Codex account usage in the shortest useful form:

```text
C68 W41
```

- `C` is the current 5-hour Codex usage window.
- `W` is the weekly Codex usage window.
- Numbers are used percentages, rounded to whole numbers.

Click the menu bar item to see reset times, credits, account, and a manual refresh command.

## Run

```sh
swift run CodexGlance
```

For a one-shot terminal check without starting the menu bar UI:

```sh
swift run CodexGlance -- --print
```

If SwiftPM cannot find the active macOS SDK, use the direct build script:

```sh
./Scripts/build.sh
.build/manual/CodexGlance
```

Package and launch as a local menu bar app:

```sh
./Scripts/package-app.sh
open .build/CodexGlance.app
```

One-shot terminal check with the direct build:

```sh
.build/manual/CodexGlance --print
```

CodexGlance reads usage from the local Codex app server:

1. Starts `codex app-server`.
2. Initializes JSON-RPC.
3. Calls `account/rateLimits/read`.
4. Calls `account/read` for account identity.

Set `CODEX_BIN=/path/to/codex` if your `codex` executable is not on the app's PATH.

## Verify

```sh
swift test
swift build
./Scripts/build.sh
./Scripts/package-app.sh
```
