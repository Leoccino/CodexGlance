<p align="center">
  <img src="Assets/CodexGlanceIcon.png" width="96" alt="CodexGlance icon">
</p>

# CodexGlance

**Codex usage, at a glance.**

CodexGlance is a tiny macOS menu bar app for people who just want to know one thing: how much Codex usage is left.

```text
5h [████████▊ ] 88% 2h14m
```

- `5h` is the current 5-hour Codex usage window.
- `wk` is the optional weekly Codex usage window.
- Numbers are remaining percentages, rounded to whole numbers. This matches the Codex app's "Usage remaining" panel.
- The colored usage meter is continuous, so 88% looks close to full instead of being rounded into coarse blocks.
- The time at the end is the reset countdown for that usage window.

It is intentionally narrow:

- Codex only.
- Menu bar only.
- One glance first; details on click.

Click the menu bar item to see account, credits, the last data update time, and a manual refresh command.
Weekly usage is hidden by default and can be added from the menu when you need it.

## Privacy

CodexGlance reads usage from the local Codex app server. It does not ship tokens, cookies, prompts, or usage data to any third-party service.

## Download

Download `CodexGlance.app.zip` from the latest [GitHub release](https://github.com/Leoccino/CodexGlance/releases), unzip it, and open `CodexGlance.app`.

Because the app is currently unsigned, macOS may require right-clicking the app and choosing `Open` the first time.

Requirements:

- macOS 13 or newer.
- Codex installed and signed in locally.

Weekly usage is hidden by default. Click the menu bar item and enable `Show Weekly in Menu Bar` when you want it.

## Build From Source

Clone, build, and launch:

```sh
git clone https://github.com/Leoccino/CodexGlance.git
cd CodexGlance
./Scripts/package-app.sh
open .build/CodexGlance.app
```

For development, you can run it directly:

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

Create a release zip locally:

```sh
./Scripts/package-release.sh
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
