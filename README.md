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
provider. Stale readings are skipped until a fresh one arrives.

## Timer

```bash
systemctl --user status dank-tank-notify.timer
systemctl --user start dank-tank-notify.service   # poll right now
journalctl --user -u dank-tank-notify -n 20
```

Polling every 5 minutes is ~288 requests/day, which is nothing, and it keeps the
status line's cache warm for terminals where Claude Code has not yet reported.

## noctalia bar widget

`noctalia/dank-tank/` is the `dankhael/dank-tank` plugin (noctalia with plugin API
48 or newer). It has three entries:

- **`poller`** — a service, and the only part that runs the provider commands.
  There is one for the whole shell however many monitors carry the widget, and it
  publishes readings through `noctalia.state`. A provider that fails never hides
  the others.
- **`usage`** — the bar widget.
- **`detail`** — the panel it toggles.

What they share (providers, windows, pace, colours) lives in `lib/model.luau`.

The bar carries **one number per agent** — the window closest to its limit — as
`46% │ 27% │ 0% │ 15%`, each beside its provider's logo. Numbers stay in plain ink
until they pass a threshold, and the icon follows the worst of all. A dash means no
reading applies right now, which is not the same as 0%; a dimmed number is an old
reading. On monitors narrower than 1500 px (portrait ones included) the automatic
style drops the `%` and the dividers so it fits beside the clock and the tray; side
bars stack the chips. *Bar style* in the settings forces full, compact, or only the
most used.

Left click opens the **detail panel**: one card per agent with every window. The
tick on each bar is where an even burn would be by now, `↑` marks a window running
ahead of it, and when that window would run out before it resets the card says
when. Hovering a row gives the exact reset time. A window that has rolled over
since its last reading shows as reset rather than repeating the old percentage.
The panel is as tall as its content, and scrolls only when the monitor is too
short. Right click on the widget forces a re-read, as does `R` in the panel or:

```bash
noctalia msg plugin dankhael/dank-tank:poller all refresh
```

The panel always opens centred on the bar of the monitor you clicked.
`open_near_click` is off on purpose: for a plugin widget the host anchors it to
the *pointer*, so the panel landed somewhere else on every click. With the widget
in an end lane, set the panel's *Position* to that end (Settings → Plugins → the
gear on dank-tank).

Background reads happen every 2 minutes, and every 5 for Codex, whose query has to
start an app-server. Both count from the reading itself, whoever fetched it.
Opening the panel asks for anything older than 30 s.

The commands share `usage-cache.sh`, which they find next to themselves through
their symlinks. It serialises fetches, so the widget, the timer and a shell asking
at once cost one request; `--refresh` accepts only a query that began after it was
asked for, or a failure that came in while it waited. A response without usable
percentages counts as a failure and never replaces the last reading. After a
failure it waits 60 s (5 min when rate limited) before retrying, and whatever the
reason, the older reading is reported as stale.

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
command paths and visibility, bar style, icon, Claude credit visibility, refresh
interval, warning/alert thresholds and the warning colour. That colour is a plain hex
rather than a palette role — `error` is red in every theme, but the accent roles
that would fit the middle band are green in plenty of them, which reads as fine
rather than as caution.

The logos in `noctalia/dank-tank/assets/logos/` are trademarks of Anthropic, OpenAI,
Google and OpenCode, used only to identify each provider. The SVGs come from
[Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT, see the `LICENSE` next to
them), trimmed to fit; this project is not affiliated with any of them.

## Other bars

`claude-usage --line` is meant for this:

```
s 15% · w 8% · BRL 69.00
```

For Waybar, `claude-usage --bar-json` plus a `jq` format string works.
