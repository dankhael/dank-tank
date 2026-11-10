# dank-tank

Track how much of your Claude, Codex, Antigravity and OpenCode Go plans you have
consumed without opening their usage panels. (Formerly `claude-usage`; it
outgrew the name once it tracked more than Claude.)

Six pieces, with one source of truth per provider:

- **`claude-usage`** — CLI report: session (5h), weekly (7d), extra-usage credits,
  with pacing and reset countdowns.
- **`claude-usage-statusline`** — status line for Claude Code, so the numbers sit
  in front of you while you work.
- **`dank-tank-notify`** — unified systemd user timer for every provider
  below. It warns at 50/80/95%, reports meaningful resets, and batches all
  events found in the same poll into one desktop notification.
- **`codex-usage`** — asks the official local Codex app-server for the current
  account rate-limit windows, plan, resets and credits. Its bar output is folded
  into the same Noctalia widget as Claude.
- **`antigravity-usage`** — receives the official AGY custom-statusline payload,
  removes account/session data, and caches Gemini and third-party 5-hour and
  weekly quotas for the same Noctalia widget.
- **`opencode-usage`** — reads the OpenCode Go 5-hour, weekly and monthly
  limits with the Go key OpenCode already stores.

## Where the OpenCode Go numbers come from

`GET https://opencode.ai/zen/go/v1/usage` with `Authorization: Bearer <Go key>`.
It returns `rolling`, `weekly` and `monthly`, each with `status`, `percent` and
`resetsAt` — percentages only, no dollar figures. The key comes from
`$OPENCODE_GO_API_KEY`, else the active `opencode-go` credential in
`~/.local/share/opencode/opencode.db` (read-only, via `sqlite3`), else
`auth.json`. It is passed to curl on stdin so it never shows in `ps`.

Like the Claude endpoint, this one is **not documented** — the docs only point at
the web console — so it can change without notice. Results are cached for 60 s
in `~/.cache/opencode-usage/`; a failed refresh keeps the last reading, marked
stale. Exit codes: 2 no key, 3 key rejected, 4 query failed.

The monthly window is a calendar month ending at its reset, so pacing for it is
measured against that month's real length.

## Where the Antigravity numbers come from

AGY's supported custom statusline JSON. On Google AI Pro it reports four quota
buckets: `gemini-5h`, `gemini-weekly`, `3p-5h`, and `3p-weekly`, each with a
remaining fraction and reset time. `antigravity-usage --ingest` is registered as
the AGY renderer; it writes only plan, model, context percentage, quota values,
and capture time to `~/.cache/antigravity-usage/status.json`. Email, conversation
ID, paths and authentication data are discarded.

Unlike Claude and Codex, AGY currently pushes quota while an interactive session
is running instead of documenting a headless quota API. The bar therefore keeps
the last snapshot and marks it stale after ten minutes without an AGY update.

## Where the Codex numbers come from

`codex app-server` method `account/rateLimits/read`. The app-server owns login,
token refresh and the backend request; `codex-usage` never reads or copies the
tokens in `~/.codex/auth.json`. The response can contain one or two rolling
windows depending on the plan and active limit bucket, so the widget renders
every window returned rather than assuming there is always a 5-hour limit.

The response is cached for 60 seconds. If a refresh fails, the last good result
stays visible and is marked stale.

## Where the numbers come from

`GET https://api.anthropic.com/api/oauth/usage`, authenticated with the OAuth
access token Claude Code stores in `~/.claude/.credentials.json`. It returns
exactly what `/usage` shows in the app, and the limits are shared across
claude.ai, Claude Code and the IDE extensions — so one poll covers everything.

This endpoint is **not documented or supported**; it can change without notice.
If it does, every script here degrades to "no data" rather than misreporting.

The status line prefers the `rate_limits` block Claude Code passes on stdin
(free, no network, no token handling) and only falls back to the cache when that
is absent. A `*` after the countdown means the reading came from the cache.

### On tokens

These scripts **read** the access token and never refresh it — Claude Code
rewrites the file itself whenever it runs, and the token lasts ~8–12 hours. If
it does expire, the notifier says so once a day instead of every five minutes,
and any `claude` command fixes it. Nothing here touches your refresh token.

## Install

```bash
./install.sh
```

Symlinks the scripts into `~/.local/bin`, seeds `~/.config/dank-tank/config.env`,
enables the timer, and registers the status line in `~/.claude/settings.json`
(backing it up first, and refusing to clobber a status line you already have).

It also migrates an install from the old `claude-usage` name: disables and
removes the `claude-usage-notify` timer and link, moves `~/.config/claude-usage`
to `~/.config/dank-tank`, swaps the Noctalia plugin source, and re-points any bar
widget still typed `dankhael/claude-usage:usage`. The notifier copies its old
threshold state from `~/.cache/claude-usage/` on first run, so nothing re-fires.

Dependencies: `bash`, `jq`, `curl`, `awk`, `notify-send`; `sqlite3` for OpenCode.

## Use

```bash
claude-usage                    # full report
claude-usage --line             # one line, for a bar or prompt
claude-usage --json             # raw payload
claude-usage --refresh          # ignore cache age
codex-usage                     # Codex plan report
codex-usage --bar-json          # Codex widget payload
codex-usage --refresh           # force a fresh app-server query
antigravity-usage               # AGY Gemini/third-party quota report
antigravity-usage --bar-json    # AGY widget payload
opencode-usage                  # OpenCode Go 5h / weekly / monthly
opencode-usage --bar-json       # OpenCode widget payload
opencode-usage --refresh        # ignore cache age

dank-tank-notify --test         # confirm notifications reach your desktop
dank-tank-notify --dry-run      # what would fire right now, changing nothing
dank-tank-notify --status       # which thresholds have fired this window
dank-tank-notify --reset        # forget them
```

Report output:

```
Claude usage
  session  ███░░░░░░░░░░░░░░░░░  15%  ↓  resets in 44m
  weekly   █░░░░░░░░░░░░░░░░░░░   8%  ↓  resets in 4d15h
  credits  ████████████░░░░░░░░  63%  BRL 69.00 of BRL 110.00
  ↑ ahead of pace · → on track · ↓ under
```

**Pacing** is the number worth watching. It compares consumption against how far
into the window you are: at 40% through a 5h session, 15% used is `↓` (fine) and
60% used is `↑` (you will run out early).

## Configure

Edit `~/.config/dank-tank/config.env`:

```sh
SESSION_THRESHOLDS="50 80 95"   # "" to silence a category
WEEKLY_THRESHOLDS="50 80 95"
SPEND_THRESHOLDS="50 80 95"
CODEX_SESSION_THRESHOLDS="50 80 95"
CODEX_WEEKLY_THRESHOLDS="50 80 95"
ANTIGRAVITY_SESSION_THRESHOLDS="50 80 95"
ANTIGRAVITY_WEEKLY_THRESHOLDS="50 80 95"
OPENCODE_SESSION_THRESHOLDS="50 80 95"
OPENCODE_WEEKLY_THRESHOLDS="50 80 95"
OPENCODE_MONTHLY_THRESHOLDS="50 80 95"   # defaults to the weekly ones
NOTIFY_ON_RESET=1               # tell me when a window I nearly exhausted resets
RESET_NOTICE_ABOVE=80
```

Each provider/window/threshold fires at most once. When a window rolls over, its
fired set clears independently. If several thresholds are discovered during one
five-minute timer run, they are combined into one notification with one line per
provider. Stale Antigravity and OpenCode readings are skipped until a fresh one
arrives.

## Timer

```bash
systemctl --user status dank-tank-notify.timer
systemctl --user start dank-tank-notify.service   # poll right now
journalctl --user -u dank-tank-notify -n 20
```

Polling every 5 minutes is ~288 requests/day, which is nothing, and it keeps the
status line's cache warm for terminals where Claude Code has not yet reported.

## noctalia bar widget

`noctalia/dank-tank/` is the `dankhael/dank-tank` plugin, with two entries backed
by one script: a `[[widget]]` bar entry and the `[[panel]]` it toggles. It runs
every provider command independently; if one is unavailable, the others keep
working.

The bar carries **one number per agent** — the worst window that agent currently
has open — as `C 46% │ X 27% │ A 0% │ O 15%`, each coloured by its own severity,
with the icon following the worst of all. Four agents times three or four
windows does not survive a glance, so the breakdown moved into the panel.

Left click opens the **detail panel**: one card per agent with plan, model, a
progress bar per window, pace arrow, reset countdown, credits and a stale marker,
plus a refresh button. Right click on the widget forces a re-read without opening
anything, and the tooltip keeps a one-line summary for a hover.

Both entries point at `usage.luau`. Each runs in its own VM but both see the
`barWidget` and `panel` namespaces, so the script latches onto whichever surface
the host addresses first (`onOpen` means panel) and never repaints one with the
other's tree. A shared module would be tidier, but `require()` needs plugin API 22
and noctalia 5.0.0-beta.8 caps at 20.

`install.sh` registers the source and enables the plugin. Placing it in a lane
is the one manual step:

```
Settings → Bar → (pick a lane) → Add widget → dank-tank
```

That last step is deliberately not scripted: the bar layout lives in
`~/.local/state/noctalia/settings.toml`, and writing a `[bar]` section there
**replaces** the default layout rather than merging into it, so a script that
adds one widget would silently drop every other one. (Re-pointing an existing
widget during migration is fine: it goes through `noctalia msg config-set`,
because noctalia rewrites settings.toml from memory and would undo a direct
edit.)

Settings live at the plugin level now (Settings → Plugins → the gear on the
plugin row), because the widget and the panel read the same ones: provider
command paths and visibility, icon, Claude credit visibility, refresh interval,
warning/alert thresholds and the warning colour. That colour is a plain hex
rather than a palette role — `error` is red in every theme, but the accent roles
that would fit the middle band are green in plenty of them, which reads as fine
rather than as caution.

## Other bars

`claude-usage --line` is meant for this:

```
s 15% · w 8% · BRL 69.00
```

For Waybar, `claude-usage --bar-json` plus a `jq` format string works.
