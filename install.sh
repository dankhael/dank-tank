#!/usr/bin/env bash
# install.sh — put dank-tank on PATH, register the statusline, start the timer.
#
# Symlinks rather than copies, so editing the repo takes effect immediately.
# Re-running is safe.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
UNITS="$HOME/.config/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dank-tank"
OLD_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-usage"
SETTINGS="$HOME/.claude/settings.json"
AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

say() { printf '  %s\n' "$*"; }

for dep in jq curl notify-send awk; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done

echo "Installing dank-tank"

# ---- migrate from the old "claude-usage" name (safe to re-run) ----
if [[ -e "$UNITS/claude-usage-notify.timer" || -L "$UNITS/claude-usage-notify.timer" ]]; then
  systemctl --user disable --now claude-usage-notify.timer >/dev/null 2>&1 || true
  rm -f "$UNITS/claude-usage-notify.timer" "$UNITS/claude-usage-notify.service"
  say "removed old claude-usage-notify timer"
fi
if [[ -L "$BIN/claude-usage-notify" ]]; then
  rm -f "$BIN/claude-usage-notify"
  say "removed old $BIN/claude-usage-notify"
fi
if [[ -d "$OLD_CONF_DIR" && ! -e "$CONF_DIR" ]]; then
  mv "$OLD_CONF_DIR" "$CONF_DIR"
  say "moved $OLD_CONF_DIR to $CONF_DIR"
fi

mkdir -p "$BIN" "$UNITS" "$CONF_DIR"
for f in claude-usage codex-usage antigravity-usage opencode-usage claude-usage-statusline dank-tank-notify; do
  chmod +x "$SRC/$f"
  ln -sfn "$SRC/$f" "$BIN/$f"
  say "linked $BIN/$f"
done

if [[ ! -e "$CONF_DIR/config.env" ]]; then
  cp "$SRC/config.env.example" "$CONF_DIR/config.env"
  say "wrote $CONF_DIR/config.env"
else
  say "kept existing $CONF_DIR/config.env"
fi

# AGY has no headless quota command. Its supported custom statusline receives a
# live quota payload, so antigravity-usage acts as both renderer and sanitized
# cache writer for the Noctalia widget. Preserve unrelated AGY settings.
if command -v agy >/dev/null && [[ -f "$AGY_SETTINGS" ]]; then
  current=$(jq -r '.statusLine.command // ""' "$AGY_SETTINGS")
  if [[ "$current" == "$BIN/antigravity-usage --ingest" ]]; then
    say "AGY quota status line already registered"
  elif [[ -z "$current" || "$current" == "/tmp/agy-status-capture.sh" ]]; then
    cp "$AGY_SETTINGS" "$AGY_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    jq --arg cmd "$BIN/antigravity-usage --ingest" \
      '.statusLine = {type:"command", command:$cmd}' \
      "$AGY_SETTINGS" > "$AGY_SETTINGS.tmp" && mv "$AGY_SETTINGS.tmp" "$AGY_SETTINGS"
    say "registered AGY quota status line in $AGY_SETTINGS"
  else
    say "NOTE: an AGY status line is already configured, leaving it alone:"
    say "      $current"
    say "      antigravity-usage needs the AGY status payload to refresh its cache"
  fi
fi

command -v sqlite3 >/dev/null \
  || say "NOTE: sqlite3 not found — opencode-usage needs it (or \$OPENCODE_GO_API_KEY) to find the Go key"

for u in dank-tank-notify.service dank-tank-notify.timer; do
  ln -sfn "$SRC/systemd/$u" "$UNITS/$u"
done
systemctl --user daemon-reload
systemctl --user enable --now dank-tank-notify.timer
say "timer enabled — $(systemctl --user is-active dank-tank-notify.timer)"

# Register the status line, preserving whatever else is in settings.json.
if [[ -f "$SETTINGS" ]]; then
  current=$(jq -r '.statusLine.command // ""' "$SETTINGS")
  if [[ "$current" == "$BIN/claude-usage-statusline" ]]; then
    say "status line already registered"
  elif [[ -n "$current" ]]; then
    say "NOTE: a status line is already configured, leaving it alone:"
    say "      $current"
    say "      to switch: set .statusLine.command to $BIN/claude-usage-statusline"
  else
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    jq --arg cmd "$BIN/claude-usage-statusline" \
      '.statusLine = {type:"command", command:$cmd, padding:0}' \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    say "registered status line in $SETTINGS (backup alongside it)"
  fi
else
  say "no $SETTINGS found — skipping status line registration"
fi

# noctalia bar widget, if noctalia is around. Registering the source and
# enabling the plugin is safe and idempotent; *placing* the widget in a lane is
# not done here, because writing a [bar] section into settings.toml replaces the
# default layout wholesale rather than merging with it.
if command -v noctalia >/dev/null; then
  if ! noctalia msg plugins source list 2>/dev/null | grep -q "$SRC/noctalia"; then
    # A source registered under this name but pointing somewhere else is a repo
    # that moved: noctalia keeps the dead path and silently drops the plugin on
    # the next reload, so re-point it instead of adding a second entry.
    if noctalia msg plugins source list 2>/dev/null | grep -q "^dank-tank "; then
      noctalia msg plugins source remove dank-tank >/dev/null
      say "re-pointing noctalia plugin source at $SRC/noctalia"
    fi
    noctalia msg plugins source add dank-tank path "$SRC/noctalia" >/dev/null
    say "registered noctalia plugin source"
  else
    say "noctalia plugin source already registered"
  fi
  noctalia msg plugins enable dankhael/dank-tank >/dev/null 2>&1 || true
  say "noctalia plugin enabled"

  # Old name, once the new plugin is live: re-point every bar widget instance
  # that still names it, then drop the old plugin and source. This goes through
  # `config-set` rather than editing settings.toml: noctalia rewrites that file
  # from memory on the next plugin command and would undo a direct edit.
  NOCT_SETTINGS="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml"
  if [[ -f "$NOCT_SETTINGS" ]]; then
    awk '/^\[widget\./ { name = substr($0, 9, length($0) - 9) }
         /^type = "dankhael\/claude-usage:usage"/ { print name }' "$NOCT_SETTINGS" |
    while read -r instance; do
      noctalia msg config-set "widget.$instance.type" '"dankhael/dank-tank:usage"' >/dev/null \
        && say "re-pointed bar widget '$instance' to dankhael/dank-tank"
    done
  fi
  if noctalia msg plugins source list 2>/dev/null | grep -q "^claude-usage "; then
    noctalia msg plugins disable dankhael/claude-usage >/dev/null 2>&1 || true
    noctalia msg plugins source remove claude-usage >/dev/null 2>&1 || true
    say "removed old claude-usage noctalia plugin source"
  fi

  grep -q '"dankhael/dank-tank:usage"' "$NOCT_SETTINGS" 2>/dev/null \
    || say "add it to the bar in Settings → Bar → Add widget → dank-tank"
fi

echo
echo "Done. Try:"
echo "  claude-usage                    # full report"
echo "  codex-usage                     # Codex plan windows"
echo "  antigravity-usage               # cached AGY plan/model quotas"
echo "  opencode-usage                  # OpenCode Go 5h/weekly/monthly"
echo "  dank-tank-notify --test         # check notifications reach your desktop"
echo "  dank-tank-notify --dry-run      # what would fire right now"
