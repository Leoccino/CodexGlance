<p align="center">
  <img src="Assets/CodexGlanceIcon.png" width="96" alt="CodexGlance icon">
</p>

<h1 align="center">CodexGlance</h1>

<p align="center">
  <strong>Codex usage at a glance. No clicks.</strong>
</p>

<p align="center">
  <a href="https://leoccino.github.io/CodexGlance/">Website</a>
  ·
  <a href="https://github.com/Leoccino/CodexGlance/releases">Download</a>
  ·
  <a href="https://github.com/Leoccino/CodexGlance">GitHub</a>
</p>

CodexGlance is a tiny macOS menu bar app for Codex and Claude Code users who only need one answer while working: how much usage is left right now.

<p align="center">
  <img src="docs/assets/codexglance-menubar.png" width="184" alt="CodexGlance menu bar item showing current Codex usage">
</p>

## Product Focus

CodexGlance is intentionally narrow:

- **Codex and Claude Code:** one menu bar item shows either product; switch with **Show in Menu Bar**. The menu lists both.
- **Menu bar only:** no dashboard to keep open, no extra account, no separate service.
- **Current limit first:** the active limit is always shown with its real duration.
- **Additional limits when present:** extra windows and model-specific buckets stay one click away.

The menu bar item shows:

- Product mark: when both Codex and Claude report usage, a small mark shows which one is in the menu bar: `>_` for Codex, an orange spark for Claude. With only one product, there is no mark.
- Window label: derived from the reported limit, such as `5h`, `wk`, or another duration.
- Percentage: remaining usage, rounded to whole numbers.
- Gauge: red for low remaining, orange for caution, green for healthy.
- Underline: time left before the current window resets.

Click the menu bar item to see a section per product with account details, all reported limits (including Claude's per-model weekly limits), reset credits, reset times, and the last update time, plus a manual refresh command. The menu bar shows Codex by default; switch to Claude under **Show in Menu Bar**. The same menu picks which limits to show: the short window (such as `5h`), the weekly one (`wk`), or both. Choices are remembered.

The menu also includes **Check for Updates…**, **Download Latest Version**, and **Website**. Update checks compare the installed version with the latest public GitHub release and open its download page when requested. Installing an update still requires replacing the app; this build does not install updates automatically.

## Visual Design

The public site and README use the same visual model as the macOS app: a 210 degree gauge start, 240 degree sweep, and a needle mapped to the remaining percentage.

<p align="center">
  <img src="Assets/visual-design.svg" alt="CodexGlance visual design: enlarged menu bar gauge and reset line">
</p>

## Install

Download `CodexGlance.app.zip` from the latest [GitHub release](https://github.com/Leoccino/CodexGlance/releases), unzip it, and open `CodexGlance.app`.

Because the app is currently unsigned, macOS may require right-clicking the app and choosing `Open` the first time.

Requirements:

- macOS 13 or newer.
- For Codex: ChatGPT or Codex installed and signed in locally.
- For Claude: the Claude Code CLI (`claude`) signed in with a Claude subscription (Pro, Max, Team, or Enterprise). The desktop app keeps its own sign-in, so sign in to the CLI once. API-key-only setups have no subscription limits to show.

## Privacy

CodexGlance reads Codex usage from the local Codex app server.

For Claude, it reads Claude Code's existing sign-in from the login keychain (`Claude Code-credentials`, via `/usr/bin/security`) or `~/.claude/.credentials.json`, and sends it only to Anthropic: the usage endpoint (`api.anthropic.com/api/oauth/usage`) and, when the access token has expired, Claude Code's own token refresh endpoint (`platform.claude.com/v1/oauth/token`). A refreshed token is written back to the same place, changing only the token fields and holding the same lock files Claude Code uses (`~/.claude/.oauth_refresh.lock`, `~/.claude/.storage-write.lock`), so Claude Code and CodexGlance keep sharing one sign-in. The account email comes from the local `~/.claude.json`.

It does not ship tokens, cookies, prompts, or usage data to any third-party service.

Only a manual update check contacts GitHub's public releases API. It sends no account or usage data.

## Build From Source

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

For a one-shot terminal check without starting the menu bar UI (prints every product; add `--provider codex` or `--provider claude` for one):

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

CodexGlance reads usage from the local Codex app server:

1. Starts `codex app-server`.
2. Initializes JSON-RPC.
3. Calls `account/rateLimits/read`.
4. Calls `account/read` for account identity.

Claude usage comes from Anthropic's subscription usage endpoint: the 5-hour and weekly windows, plus any per-model weekly windows it reports. Window keys such as `five_hour` or `seven_day_opus` are parsed rather than hard-coded, so new windows still appear. Expired access tokens are refreshed automatically, so Claude keeps working even if you only use Claude Code in the desktop app. If the stored refresh token itself is no longer valid, run `claude` in Terminal and sign in once. Claude is polled at most once a minute; if the endpoint throttles, the last reading stays on screen with its original update time.

CodexGlance automatically finds the Codex executable bundled with either `ChatGPT.app` or `Codex.app`, in `/Applications` or `~/Applications`. It supports both the original `Contents/Resources/codex` layout and the newer `Contents/Resources/codex-cli/` launcher/nested CLI layout, then falls back to `codex` on PATH. Set `CODEX_BIN=/path/to/codex` to override discovery for a custom installation.

Compatibility is based on the available executable layout and reported quota windows, rather than a fixed ChatGPT/Codex version number. Unknown future protocol changes may still require an update.

## Verify

```sh
swift test
swift build
./Scripts/build.sh
./Scripts/package-app.sh
```
