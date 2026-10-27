#!/bin/bash
# Craft Suite Setup: build the storytold Craft App Suite from source on a Mac and run it from the
# ArtCraft Launcher dashboard.
#
#   ./run.sh                 interactive menu
#   ./run.sh setup           first-time setup: tools, clone, build every app, install the launcher app
#   ./run.sh update          pull updates (and any new Craft app), rebuild what changed, open the dashboard
#   ./run.sh open            open the dashboard
#   ./run.sh status          versions checked out vs built
#   ./run.sh check           look for new code on GitHub and say which apps need rebuilding
#   ./run.sh rebuild [apps]  rebuild the outdated apps (or the ones named) so the launcher offers Update
#   ./run.sh watch [on|off]  check every day in the background and pop up an alert when updates exist
#   ./run.sh agent-tools     install every app's CLI and connect all 13 apps to Claude (MCP)
#   ./run.sh install-apps    (re)install "ArtCraft Launcher.app" and "Craft Suite Setup.app"
#   ./run.sh publish         push this project to your own GitHub repo
#
# Where the source lives: $CRAFT_HOME (default ~/Documents/Projects_Folder/storytold).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRAFT_HOME="${CRAFT_HOME:-$HOME/Documents/Projects_Folder/storytold}"
L="$CRAFT_HOME/craft-launcher"
# The builds and the local server live outside ~/Documents: macOS blocks apps (the launcher, which
# starts the server) from Documents, so a server or mirror in there silently fails to start.
SUPPORT="$HOME/Library/Application Support/Craft Suite"
MIRROR="$SUPPORT/local-mirror"
SERVER="$SUPPORT/bin/xtask"
SERVE_LOG="$SUPPORT/serve.log"
PATCH="$SELF_DIR/patches/craft-launcher-local-mirror-signing.patch"
PATCHED_FILES=(crates/native/src/install.rs crates/native/src/backend.rs)
LAUNCHER_APP="/Applications/ArtCraft Launcher.app"
SETUP_APP="/Applications/Craft Suite Setup.app"
AGENT="$HOME/Library/LaunchAgents/com.craftsuite.update-check.plist"
CHECK_HOUR="${CHECK_HOUR:-10}"   # when the daily background check runs (24h clock)
PORT=8787
RESVG_VERSION=0.48.1
# Fallback list; the real list is read from the launcher's own catalog once it's cloned.
DEFAULT_APPS="photocraft vectorcraft filmcraft lightcraft pdfcraft effectcraft designcraft figcraft wordcraft soundcraft deckcraft cadcraft gridcraft"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*"; exit 1; }

# ---- prerequisites ------------------------------------------------------------------------------
prereqs() {
  [ "$(uname)" = Darwin ] || die "this script is for macOS"
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null
    die "Apple's command line tools are installing (a window opened). Finish that, then run this again."
  fi
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  if ! command -v cargo >/dev/null; then
    say "Installing Rust"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || die "Rust install failed"
    source "$HOME/.cargo/env"
  fi
  if ! command -v resvg >/dev/null; then
    say "Installing resvg (needed to package some apps)"
    cargo install resvg --locked --version "$RESVG_VERSION" || die "resvg install failed"
  fi
}

app_list() {
  if [ -f "$L/xtask/src/local.rs" ]; then
    grep -oE '^[[:space:]]*\("[a-z0-9-]+", "' "$L/xtask/src/local.rs" | grep -oE '[a-z0-9-]+'
  else
    echo $DEFAULT_APPS | tr ' ' '\n'
  fi
}

clone_or_pull() { # $1 = repo name
  if [ -d "$CRAFT_HOME/$1/.git" ]; then
    git -C "$CRAFT_HOME/$1" pull --ff-only -q || warn "couldn't fast-forward $1; using it as it is"
  else
    say "Cloning $1"
    git clone -q "https://github.com/storytold/$1.git" "$CRAFT_HOME/$1" || die "couldn't clone $1"
  fi
}

# ---- launcher + local patch ---------------------------------------------------------------------
update_launcher() {
  mkdir -p "$CRAFT_HOME"
  if [ -d "$L/.git" ]; then
    # Take the patch off, update, put it back.
    git -C "$L" checkout -q -- "${PATCHED_FILES[@]}" 2>/dev/null
  fi
  clone_or_pull craft-launcher
  apply_patch
}

apply_patch() {
  if git -C "$L" apply -R --check "$PATCH" 2>/dev/null; then return 0; fi   # already applied
  if git -C "$L" apply "$PATCH"; then
    echo "   local-mirror signing patch applied"
  else
    die "the launcher's code changed and the local signing patch no longer fits. Ask Claude to update patches/$(basename "$PATCH")."
  fi
}

# ---- mirror + server outside ~/Documents ------------------------------------------------------
prepare_support() {
  mkdir -p "$SUPPORT/bin" || die "couldn't create $SUPPORT"
  if [ -d "$CRAFT_HOME/local-mirror" ] && [ ! -d "$MIRROR" ]; then
    mv "$CRAFT_HOME/local-mirror" "$MIRROR" && echo "   moved the built apps to $MIRROR"
  fi
  mkdir -p "$MIRROR"
}

install_server() {
  prepare_support
  (cd "$L" && cargo build -q -p xtask) || die "couldn't build the local server"
  cp "$L/target/debug/xtask" "$SERVER.new" && mv -f "$SERVER.new" "$SERVER" && codesign --force --sign - "$SERVER" 2>/dev/null
}

# ---- build --------------------------------------------------------------------------------------
build_apps() {
  for app in $(app_list); do
    [ -d "$CRAFT_HOME/$app/.git" ] || clone_or_pull "$app"
  done
  local free_gb; free_gb=$(df -g "$CRAFT_HOME" | awk 'NR==2{print $4}')
  [ "${free_gb:-0}" -lt 30 ] && warn "only ${free_gb} GB free; building every app can need 30-60 GB"
  say "Building apps (only new or changed versions; a first build can take 1-3 hours)"
  prepare_support
  pkill -f "xtask local serve" 2>/dev/null
  (cd "$L" && cargo xtask local sync --keep 1 --mirror "$MIRROR") 2>&1 | tee "$CRAFT_HOME/craft_build_log.txt"
  echo "   full log: $CRAFT_HOME/craft_build_log.txt"
}

# ---- update check -------------------------------------------------------------------------------
# For each app: fetch from GitHub (without touching the checkout) and compare the newest code with
# the commit its newest local build came from (local-mirror/<app>/<version>/.commit).
OUTDATED=()   # built, but from older code
MISSING=()    # never built
check_apps() { # $1 = "quiet" to skip the table
  OUTDATED=(); MISSING=()
  prepare_support
  local app repo target behind mark built state
  [ "${1:-}" = quiet ] || printf '\n   %-13s %-14s %-14s %s\n' app built-from latest status
  for app in $(app_list); do
    repo="$CRAFT_HOME/$app"
    [ -d "$repo/.git" ] || continue
    git -C "$repo" fetch -q 2>/dev/null || warn "couldn't reach GitHub for $app; checking what's already downloaded"
    behind=$(git -C "$repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    if [ "${behind:-0}" -gt 0 ]; then target=$(git -C "$repo" rev-parse '@{u}'); else target=$(git -C "$repo" rev-parse HEAD); fi
    mark=$(ls -t "$MIRROR/$app"/*/.complete 2>/dev/null | head -1)
    built=""; [ -n "$mark" ] && built=$(tr -d '[:space:]' < "$(dirname "$mark")/.commit" 2>/dev/null)
    if [ -z "$built" ]; then
      state="not built yet"; MISSING+=("$app")
    elif [ "$(git -C "$repo" rev-parse -q --verify "$built^{commit}" 2>/dev/null)" = "$target" ]; then
      state="up to date"
    else
      if [ "${behind:-0}" -gt 0 ]; then state="UPDATE: $behind new commit(s) on GitHub"; else state="UPDATE: build is older than the checkout"; fi
      OUTDATED+=("$app")
    fi
    [ "${1:-}" = quiet ] || printf '   %-13s %-14s %-14s %s\n' "$app" "${built:0:12}" "${target:0:12}" "$state"
  done
}

notify() { osascript -e "display notification \"$1\" with title \"Craft Suite\" sound name \"Glass\"" >/dev/null 2>&1; }

# Build the given apps as a new dev version (<next patch>-dev.<commit time>) so the launcher sees a
# newer version and shows Update; an ordinary --rebuild keeps the same version and the launcher
# wouldn't notice.
rebuild_apps() { # app ...
  local only; only=$(IFS=,; echo "$*")
  say "Rebuilding: $only"
  prepare_support
  pkill -f "xtask local serve" 2>/dev/null
  (cd "$L" && cargo xtask local sync --keep 1 --mirror "$MIRROR" --every-commit --only "$only") 2>&1 | tee -a "$CRAFT_HOME/craft_build_log.txt"
}

# ---- Mac apps -----------------------------------------------------------------------------------
install_launcher_app() {
  say "Building ArtCraft Launcher.app"
  (cd "$L" && cargo build --release -p artcraft-launcher --features local-mirror) || die "launcher build failed"
  install_server
  local version; version=$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$L/Cargo.toml" | head -1)
  rm -rf "$LAUNCHER_APP"
  mkdir -p "$LAUNCHER_APP/Contents/MacOS" "$LAUNCHER_APP/Contents/Resources"
  cp "$L/target/release/artcraft-launcher" "$LAUNCHER_APP/Contents/MacOS/artcraft-launcher-bin"
  cp "$L/assets/app-icon/artcraft-launcher.icns" "$LAUNCHER_APP/Contents/Resources/ArtCraft Launcher.icns"
  sed -e "s/@VERSION@/$version/g" -e "s/@SHORT_VERSION@/${version%%-*}/g" -e "s/@BUILD_SHA@/local/g" \
    "$L/packaging/macos/Info.plist.in" > "$LAUNCHER_APP/Contents/Info.plist"
  printf 'APPL????' > "$LAUNCHER_APP/Contents/PkgInfo"
  # Entry point: start the local build server if it isn't running, then become the launcher.
  cat > "$LAUNCHER_APP/Contents/MacOS/ArtCraft Launcher" <<EOF
#!/bin/bash
if ! nc -z 127.0.0.1 $PORT 2>/dev/null; then
  nohup "$SERVER" local serve --mirror "$MIRROR" --port $PORT > "$SERVE_LOG" 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 0.5; done
fi
export ARTCRAFT_LAUNCHER_DOWNLOAD_BASE="http://127.0.0.1:$PORT/"
exec "\$(dirname "\$0")/artcraft-launcher-bin" "\$@"
EOF
  chmod +x "$LAUNCHER_APP/Contents/MacOS/ArtCraft Launcher"
  xattr -cr "$LAUNCHER_APP"
  codesign --force --sign - "$LAUNCHER_APP/Contents/MacOS/artcraft-launcher-bin"
  codesign --force --sign - "$LAUNCHER_APP"
  touch "$LAUNCHER_APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$LAUNCHER_APP" 2>/dev/null
  killall Dock 2>/dev/null
  echo "   installed $LAUNCHER_APP"
}

install_setup_app() {
  say "Installing Craft Suite Setup.app (double-click it for the update menu)"
  rm -rf "$SETUP_APP"
  osacompile -o "$SETUP_APP" \
    -e 'tell application "Terminal"' \
    -e 'activate' \
    -e "do script \"bash '$SELF_DIR/run.sh'\"" \
    -e 'end tell' || warn "couldn't create $SETUP_APP"
}

# ---- commands -----------------------------------------------------------------------------------
start_server() { # the launcher downloads every app from here; builds stop it, so restart it when needed
  nc -z 127.0.0.1 $PORT 2>/dev/null && return 0
  prepare_support
  [ -x "$SERVER" ] || install_server
  nohup "$SERVER" local serve --mirror "$MIRROR" --port $PORT > "$SERVE_LOG" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $PORT 2>/dev/null && return 0; sleep 0.5; done
  warn "the local build server didn't start; see $SERVE_LOG"
}

cmd_open() {
  [ -d "$LAUNCHER_APP" ] || die "ArtCraft Launcher.app isn't installed yet: run ./run.sh setup"
  start_server
  # A launcher that was already open has given up on the server (it shows apps as Offline);
  # restart it so it reads the current builds.
  if pgrep -f "ArtCraft Launcher.app/Contents/MacOS/artcraft-launcher-bin" >/dev/null; then
    osascript -e 'tell application "ArtCraft Launcher" to quit' >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "artcraft-launcher-bin" >/dev/null || break; sleep 0.5; done
  fi
  open -a "ArtCraft Launcher"
}

cmd_setup() {
  prereqs
  update_launcher
  build_apps
  install_launcher_app
  install_setup_app
  say "All set. Click Install on each app in the dashboard, then Open."
  cmd_open
}

cmd_update() {
  prereqs
  local before=""; [ -d "$L/.git" ] && before=$(git -C "$L" rev-parse HEAD)
  update_launcher
  local after; after=$(git -C "$L" rev-parse HEAD)
  build_apps
  # Same version number but newer code (sync skips those): rebuild them too.
  check_apps quiet
  [ ${#OUTDATED[@]} -gt 0 ] && rebuild_apps "${OUTDATED[@]}"
  if [ "$before" != "$after" ] || [ ! -d "$LAUNCHER_APP" ]; then install_launcher_app; fi
  [ -d "$SETUP_APP" ] || install_setup_app
  say "Up to date. Click Update/Install on any app that offers it."
  cmd_open
}

cmd_status() {
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  (cd "$L" && cargo xtask local status --mirror "$MIRROR")
}

cmd_check() { # --alert: answer with a dialog instead of the terminal (used by the background check)
  say "Checking the Craft apps for new code"
  check_apps
  [ ${#MISSING[@]} -gt 0 ] && warn "never built: ${MISSING[*]} (./run.sh update builds them)"
  if [ ${#OUTDATED[@]} -eq 0 ]; then echo; echo "   Every app is built from the latest code."; return 0; fi
  local list="${OUTDATED[*]}" ans=""
  if [ "${1:-}" = --alert ]; then
    ans=$(osascript -e "button returned of (display dialog \"New code is available for: ${list// /, }\" & return & return & \"Rebuild them now? (A few minutes per app; Terminal will open.)\" with title \"Craft Suite\" buttons {\"Later\", \"Rebuild now\"} default button 2 giving up after 3600)" 2>/dev/null)
    if [ "$ans" = "Rebuild now" ]; then
      osascript -e 'tell application "Terminal"' -e 'activate' -e "do script \"bash '$SELF_DIR/run.sh' rebuild $list\"" -e 'end tell' >/dev/null
    else
      notify "Updates waiting for: ${list// /, }. Run Craft Suite Setup → Rebuild outdated apps."
    fi
  elif [ -t 0 ]; then
    echo; read -r -p "Rebuild ${list// /, } now? [y/N] " ans
    case "$ans" in [Yy]*) cmd_rebuild "${OUTDATED[@]}" ;; *) echo "   later: ./run.sh rebuild" ;; esac
  else
    notify "Updates ready to build: ${list// /, }"
    echo "   run: ./run.sh rebuild"
  fi
}

cmd_rebuild() { # [app ...]   no apps: whatever check finds outdated
  prereqs
  local apps=("$@")
  if [ $# -eq 0 ]; then
    check_apps quiet
    [ ${#OUTDATED[@]} -gt 0 ] && apps=("${OUTDATED[@]}")
  fi
  if [ ${#apps[@]} -eq 0 ]; then say "Nothing to rebuild: every app is built from the latest code"; return 0; fi
  rebuild_apps "${apps[@]}"
  say "Done. In the dashboard, click Update on: ${apps[*]}"
  cmd_open
}

cmd_watch() { # on | off
  local uid; uid=$(id -u)
  case "${1:-on}" in
    off)
      launchctl bootout "gui/$uid" "$AGENT" 2>/dev/null; rm -f "$AGENT"
      say "Daily update check turned off" ;;
    on)
      mkdir -p "$(dirname "$AGENT")"; prepare_support
      cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.craftsuite.update-check</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/osascript</string>
    <string>-e</string><string>tell application "Terminal" to do script "bash '$SELF_DIR/run.sh' check --alert; exit"</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>CRAFT_HOME</key><string>$CRAFT_HOME</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>$CHECK_HOUR</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$SUPPORT/check.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/check.log</string>
</dict></plist>
EOF
      launchctl bootout "gui/$uid" "$AGENT" 2>/dev/null
      launchctl bootstrap "gui/$uid" "$AGENT" || die "couldn't start the background check"
      say "Daily update check on: every day at $CHECK_HOUR:00 (or when the Mac wakes, if it was asleep then)."
      echo "   An alert pops up only when an app has new code. Turn off with: ./run.sh watch off"
      echo "   It runs in a Terminal window (macOS only lets Terminal read your Documents folder)." ;;
    *) die "use: ./run.sh watch on | off" ;;
  esac
}

# ---- AI agent tools (CLI + MCP) ----------------------------------------------------------------
# Each app ships a <app>-cli (a separate zip on macOS) with an MCP server, so Claude can drive the
# app: create, edit, render and export. This unpacks the CLIs and registers them with the Claude
# desktop app. Agent work happens in ~/CraftStudio (outside ~/Documents, which macOS guards).
AGENT_BIN="$HOME/.craft-suite/bin"
STUDIO="${CRAFT_STUDIO:-$HOME/CraftStudio}"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

# Prints the MCP args an app's CLI accepts (they differ a little between apps), one per line.
mcp_args() { # $1 = cli path
  local full help
  full=$(perl -e 'alarm 8; exec @ARGV' "$1" mcp --help </dev/null 2>&1)
  # Some CLIs print their whole usage here; keep only the `mcp` part so flags of other
  # subcommands (e.g. `info --compact`) aren't passed to the MCP server.
  help=$(awk '/-cli mcp( |$)/ {on=1; print; next}
              on && /-cli / && ($0 ~ /^[^ ]/ || $0 ~ /^ [^ ]/ || $0 ~ /^  [^ ]/ || $0 ~ /^   [^ ]/) {on=0}
              on' <<<"$full")
  [ -n "$help" ] || help=$full
  echo mcp
  if grep -q -- '--headless' <<<"$help"; then echo --headless; fi
  if grep -q -- '--autosave' <<<"$help"; then echo --autosave; fi
  if grep -q -- '--compact' <<<"$help"; then echo --compact; fi
  if grep -q -- '--automation-read-root' <<<"$help"; then
    printf '%s\n' --automation-read-root "$HOME" --automation-write-root "$STUDIO"
  elif grep -q -- '--root' <<<"$help"; then
    printf '%s\n' --root "$STUDIO"
  fi
}

cmd_agent_tools() {
  prepare_support
  mkdir -p "$AGENT_BIN" "$STUDIO" || die "couldn't create $AGENT_BIN or $STUDIO"
  say "Installing each app's command-line tool into $AGENT_BIN"
  local app zip tmp cli entries="" n=0
  for app in $(app_list); do
    zip=$(ls -t "$MIRROR/$app"/*/"$app"-cli-*.zip 2>/dev/null | head -1)
    [ -n "$zip" ] || { warn "$app: no CLI built yet (./run.sh update builds it)"; continue; }
    tmp=$(mktemp -d)
    unzip -q -o "$zip" -d "$tmp" || { warn "$app: couldn't unzip $(basename "$zip")"; rm -rf "$tmp"; continue; }
    cli=$(find "$tmp" -type f -name "$app-cli" -perm -u+x | head -1)
    if [ -z "$cli" ]; then warn "$app: no $app-cli inside $(basename "$zip")"; rm -rf "$tmp"; continue; fi
    cp -f "$cli" "$AGENT_BIN/$app-cli" && xattr -c "$AGENT_BIN/$app-cli" 2>/dev/null
    rm -rf "$tmp"
    # One line per app for the config writer: name<TAB>command<TAB>arg<TAB>arg...
    entries+="$app"$'\t'"$AGENT_BIN/$app-cli"$'\t'"$(mcp_args "$AGENT_BIN/$app-cli" | paste -sd $'\t' -)"$'\n'
    printf '   %-12s %s\n' "$app" "$("$AGENT_BIN/$app-cli" --version 2>/dev/null | head -1)"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "no CLIs found; run ./run.sh update first"

  say "Connecting $n apps to the Claude desktop app"
  mkdir -p "$(dirname "$CLAUDE_CONFIG")"
  [ -f "$CLAUDE_CONFIG" ] && cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.bak-$(date +%Y%m%d%H%M%S)"
  ENTRIES="$entries" /usr/bin/python3 - "$CLAUDE_CONFIG" <<'PYEOF' || die "couldn't update the Claude config (a backup is next to it)"
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f: cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
servers = cfg.setdefault("mcpServers", {})
for line in os.environ["ENTRIES"].splitlines():
    parts = line.split("\t")
    if len(parts) < 3: continue
    name, command, args = parts[0], parts[1], [a for a in parts[2:] if a]
    servers[name] = {"command": command, "args": args}
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(cfg, f, indent=2)
os.replace(tmp, path)
print(f"   {len(servers)} MCP servers in {path}")
PYEOF
  echo
  echo "   Done. Quit the Claude app completely (Cmd+Q) and open it again so it loads the apps."
  echo "   Your projects folder: $STUDIO  (connect it in Claude when it asks)"
}

# ---- publish to GitHub --------------------------------------------------------------------------
GH_USER=""
gitc() { git -c user.name="${GIT_NAME:-$GH_USER}" -c user.email="${GIT_EMAIL:-$GH_USER@users.noreply.github.com}" "$@"; }

gh_ready() {
  if ! command -v gh >/dev/null; then
    if command -v brew >/dev/null; then say "Installing the GitHub CLI"; brew install gh || die "gh install failed"
    else die "install Homebrew first (https://brew.sh) or the GitHub CLI (https://cli.github.com), then re-run"; fi
  fi
  gh auth status >/dev/null 2>&1 || { say "Sign in to GitHub (your browser will open)"; gh auth login --web --git-protocol https || die "GitHub sign-in failed"; }
  gh auth setup-git >/dev/null 2>&1   # lets plain `git push` use your GitHub sign-in
  GH_USER=$(gh api user -q .login) || die "couldn't read your GitHub user"
  GIT_NAME=$(git config --global user.name || true); GIT_EMAIL=$(git config --global user.email || true)
  echo "   signed in as $GH_USER"
}

# push the current repo's main to $GH_USER/$1, creating the repo (private) if needed
push_own_repo() { # $1 = repo name, $2 = description
  if ! git remote get-url origin >/dev/null 2>&1; then
    if gh repo view "$GH_USER/$1" >/dev/null 2>&1; then
      git remote add origin "https://github.com/$GH_USER/$1.git"
    else
      gh repo create "$GH_USER/$1" --private --description "$2" --source . --remote origin >/dev/null || die "couldn't create $1"
    fi
  fi
  git push -u origin main || die "push of $1 failed; see the message above"
  echo "   https://github.com/$GH_USER/$1"
}

# 1. this project
publish_setup() {
  say "Publishing craft-suite-setup"
  cd "$SELF_DIR" || exit 1
  chmod +x run.sh
  [ -d .git ] || git init -q -b main
  git add -A && gitc commit -qm "Update craft-suite-setup" 2>/dev/null
  push_own_repo craft-suite-setup "Build and run the storytold Craft App Suite from source on macOS"
}

# 2. (B) fork craft-launcher and push the patch as a branch, without touching your working copy
publish_launcher_fork() {
  say "Forking craft-launcher and pushing the local-mirror-signing branch"
  gh repo view "$GH_USER/craft-launcher" >/dev/null 2>&1 || gh repo fork storytold/craft-launcher --clone=false >/dev/null \
    || die "couldn't fork storytold/craft-launcher"
  git -C "$L" remote get-url fork >/dev/null 2>&1 || git -C "$L" remote add fork "https://github.com/$GH_USER/craft-launcher.git"
  local tmp; tmp=$(mktemp -d)
  git -C "$L" worktree add -q --detach "$tmp/wt" HEAD || die "couldn't prepare the branch"
  git -C "$tmp/wt" apply "$PATCH" || { git -C "$L" worktree remove --force "$tmp/wt"; die "patch doesn't apply to the current launcher"; }
  gitc -C "$tmp/wt" commit -qam "Local mirror: accept ad-hoc-signed builds served from the loopback mirror

Builds from \`cargo xtask local serve\` are the developer's own ad-hoc-signed builds and can't
carry the team's Developer ID. Skip only that check when a local mirror is active (loopback only,
local-mirror feature only); checksum and version checks still apply."
  local ok=0
  for i in 1 2 3 4 5 6; do   # a brand-new fork can take a few seconds to accept pushes
    git -C "$tmp/wt" push -q -f fork HEAD:refs/heads/local-mirror-signing 2>/dev/null && { ok=1; break; }
    sleep 5
  done
  git -C "$L" worktree remove --force "$tmp/wt"; rm -rf "$tmp"
  [ "$ok" = 1 ] || die "couldn't push to your fork; try again in a minute"
  echo "   https://github.com/$GH_USER/craft-launcher/tree/local-mirror-signing"
  echo "   (to offer it upstream: gh pr create -R storytold/craft-launcher -H $GH_USER:local-mirror-signing)"
}

# 3. (A) the storytold folder as a workspace repo of submodules
publish_workspace() {
  say "Publishing the storytold folder as storytold-workspace"
  cd "$CRAFT_HOME" || die "$CRAFT_HOME not found"
  [ -d .git ] || git init -q -b main
  # Track only the workspace files; each repo is recorded as a submodule (a link + commit), not copied.
  printf '/*\n!/.gitignore\n!/.gitmodules\n!/README.md\n' > .gitignore
  local n=0
  for d in */; do
    d=${d%/}
    [ -d "$d/.git" ] || continue
    if ! git config -f .gitmodules --get "submodule.$d.path" >/dev/null 2>&1; then
      local url; url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
      git submodule add --force -q "$url" "$d" >/dev/null 2>&1 || { warn "couldn't add $d"; continue; }
    fi
    git add --force "$d"     # record its current commit
    n=$((n+1))
  done
  {
    echo "# storytold workspace"
    echo
    echo "All $n repositories from [github.com/storytold](https://github.com/storytold), as submodules pinned to the"
    echo "commits on this Mac. Built and run with [craft-suite-setup](https://github.com/$GH_USER/craft-suite-setup)."
    echo
    echo '```bash'
    echo "git clone --recurse-submodules https://github.com/$GH_USER/storytold-workspace.git storytold   # everything (~7 GB)"
    echo "git clone https://github.com/$GH_USER/storytold-workspace.git storytold && cd storytold && git submodule update --init craft-launcher pdfcraft   # just some"
    echo '```'
    echo
    echo "craft-launcher's local-mirror signing fix is on [$GH_USER/craft-launcher@local-mirror-signing](https://github.com/$GH_USER/craft-launcher/tree/local-mirror-signing)."
    echo
    echo "| Repository | Commit |"
    echo "|---|---|"
    git submodule status 2>/dev/null | awk '{gsub(/^[-+ U]/,"",$1); print "| " $2 " | `" substr($1,1,12) "` |"}'
  } > README.md
  git add .gitignore .gitmodules README.md
  gitc commit -qm "Update workspace ($n repositories)" 2>/dev/null
  push_own_repo storytold-workspace "The storytold repositories as one workspace (submodules)"
}

cmd_publish() {
  gh_ready
  publish_setup
  publish_launcher_fork
  publish_workspace
  say "Published to github.com/$GH_USER: craft-suite-setup, craft-launcher (fork), storytold-workspace"
}

menu() {
  echo "Craft Suite Setup   (source: $CRAFT_HOME)"
  PS3="Choose: "
  select c in "Update everything and open" "Open dashboard" "Check for updates" "Rebuild outdated apps" "Status" \
      "Full setup" "Reinstall apps" "Daily update alerts on" "Daily update alerts off" "Connect apps to Claude (AI agent)" "Publish to GitHub" "Quit"; do
    case "$REPLY" in
      1) cmd_update; break ;; 2) cmd_open; break ;; 3) cmd_check; break ;; 4) cmd_rebuild; break ;;
      5) cmd_status; break ;; 6) cmd_setup; break ;; 7) prereqs; install_launcher_app; install_setup_app; break ;;
      8) cmd_watch on; break ;; 9) cmd_watch off; break ;; 10) cmd_agent_tools; break ;; 11) cmd_publish; break ;; *) break ;;
    esac
  done
}

case "${1:-menu}" in
  setup) cmd_setup ;;
  update) cmd_update ;;
  open) cmd_open ;;
  status) cmd_status ;;
  check) cmd_check "${2:-}" ;;
  rebuild) shift; cmd_rebuild "$@" ;;
  watch) cmd_watch "${2:-on}" ;;
  agent-tools) cmd_agent_tools ;;
  install-apps) prereqs; install_launcher_app; install_setup_app ;;
  publish) cmd_publish ;;
  menu) menu ;;
  -h|--help|help) sed -n '2,18p' "$0" ;;
  *) die "unknown command '$1' (try: ./run.sh help)" ;;
esac
