#!/bin/bash
# Startup check for the Craft App Suite: runs when you log in, fixes what it can, and alerts you
# about anything that needs you (a problem, or apps with new code to rebuild).
#
#   ./startup-check.sh             run the checks now
#   ./startup-check.sh install     run them every time you log in
#   ./startup-check.sh uninstall   stop running them at login
#
# It runs in a Terminal window because macOS only lets Terminal read your Documents folder.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRAFT_HOME="${CRAFT_HOME:-$HOME/Documents/Projects_Folder/storytold}"
SUPPORT="$HOME/Library/Application Support/Craft Suite"
MIRROR="$SUPPORT/local-mirror"
SERVER="$SUPPORT/bin/xtask"
PORT=8787
AGENT="$HOME/Library/LaunchAgents/com.craftsuite.startup-check.plist"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; PROBLEMS+=("$*"); }
PROBLEMS=()

install_agent() {
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.craftsuite.startup-check</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/osascript</string>
    <string>-e</string><string>delay 30</string>
    <string>-e</string><string>tell application "Terminal" to do script "bash '$SELF_DIR/startup-check.sh'; exit"</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$AGENT" && echo "Startup check on: it runs 30 seconds after you log in."
}

case "${1:-}" in
  install) install_agent; exit ;;
  uninstall) launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null; rm -f "$AGENT"; echo "Startup check off."; exit ;;
esac

echo "Craft Suite startup check  ($(date '+%d %b %H:%M'))"

# 1. Tools
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
command -v cargo >/dev/null && ok "Rust is installed" || bad "Rust (cargo) not found: run ./run.sh setup"
command -v git   >/dev/null && ok "git is installed"  || bad "git not found: run xcode-select --install"

# 2. Source code
[ -d "$CRAFT_HOME/craft-launcher/.git" ] && ok "source code found in $CRAFT_HOME" || bad "craft-launcher missing from $CRAFT_HOME: run ./run.sh setup"

# 3. Installed pieces
[ -d "/Applications/ArtCraft Launcher.app" ] && ok "ArtCraft Launcher is installed" || bad "ArtCraft Launcher.app missing: run ./run.sh install-apps"
[ -x "$SERVER" ] && ok "local build server is installed" || bad "build server missing: run ./run.sh install-apps"
n=0; for app in "$MIRROR"/*/; do ls "$app"*/.complete >/dev/null 2>&1 && n=$((n+1)); done
[ "${n:-0}" -gt 0 ] && ok "$n apps built and ready to install" || bad "no built apps in $MIRROR: run ./run.sh update"

# 4. Server: start it if it's down, then make sure it answers
if ! nc -z 127.0.0.1 $PORT 2>/dev/null && [ -x "$SERVER" ]; then
  nohup "$SERVER" local serve --mirror "$MIRROR" --port $PORT > "$SUPPORT/serve.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 0.5; done
fi
served=$(curl -s -m 5 "http://127.0.0.1:$PORT/release_info.json" | grep -o '"latest_release"' | wc -l | tr -d ' ')
[ "${served:-0}" -gt 0 ] && ok "build server running, offering $served apps" || bad "build server isn't answering on port $PORT (see $SUPPORT/serve.log)"

# 5. Disk space
free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
[ "${free_gb:-0}" -ge 20 ] && ok "${free_gb} GB free" || bad "only ${free_gb} GB free (rebuilds need 20+ GB)"

# Problems → one alert; then the app update check (it shows its own alert when an app has new code).
if [ ${#PROBLEMS[@]} -gt 0 ]; then
  msg=$(printf '%s\n' "${PROBLEMS[@]}" | sed 's/"/\\"/g')
  osascript -e "display alert \"Craft Suite: ${#PROBLEMS[@]} problem(s)\" message \"$msg\"" >/dev/null 2>&1
fi
[ -x "$SELF_DIR/run.sh" ] || chmod +x "$SELF_DIR/run.sh" 2>/dev/null
bash "$SELF_DIR/run.sh" check --alert
