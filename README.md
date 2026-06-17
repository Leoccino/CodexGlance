# CodexGlance

**Codex usage, at a glance.**

CodexGlance is a tiny macOS menu bar app for people who just want to know one thing: how much Codex usage is left.

```text
5h ▰▰▰▰▱ 68%  wk ▰▰▱▱▱ 41%
```

- `5h` is the current 5-hour Codex usage window.
- `wk` is the weekly Codex usage window.
- Numbers are remaining percentages, rounded to whole numbers. This matches the Codex app's "Usage remaining" panel.

It is intentionally narrow:

- Codex only.
- Menu bar only.
- One glance first; details on click.

Click the menu bar item to see reset times, account, credits, and a manual refresh command.

## Privacy

CodexGlance reads usage from the local Codex app server. It does not ship tokens, cookies, prompts, or usage data to any third-party service.

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
