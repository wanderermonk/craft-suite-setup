#!/bin/bash
# Craft Suite Setup: build the storytold Craft App Suite from source on a Mac and run it from the
# ArtCraft Launcher dashboard.
#
#   ./run.sh                 interactive menu
#   ./run.sh setup           first-time setup: tools, clone, build every app, install the launcher app
#   ./run.sh update          pull updates (and any new Craft app), rebuild what changed, open the dashboard
#   ./run.sh open            open the dashboard
#   ./run.sh status          versions checked out vs built
#   ./run.sh install-apps    (re)install "ArtCraft Launcher.app" and "Craft Suite Setup.app"
#   ./run.sh publish         push this project to your own GitHub repo
#
# Where the source lives: $CRAFT_HOME (default ~/Documents/Projects_Folder/storytold).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRAFT_HOME="${CRAFT_HOME:-$HOME/Documents/Projects_Folder/storytold}"
L="$CRAFT_HOME/craft-launcher"
MIRROR="$CRAFT_HOME/local-mirror"
PATCH="$SELF_DIR/patches/craft-launcher-local-mirror-signing.patch"
PATCHED_FILES=(crates/native/src/install.rs crates/native/src/backend.rs)
LAUNCHER_APP="/Applications/ArtCraft Launcher.app"
SETUP_APP="/Applications/Craft Suite Setup.app"
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

# ---- build --------------------------------------------------------------------------------------
build_apps() {
  for app in $(app_list); do
    [ -d "$CRAFT_HOME/$app/.git" ] || clone_or_pull "$app"
  done
  local free_gb; free_gb=$(df -g "$CRAFT_HOME" | awk 'NR==2{print $4}')
  [ "${free_gb:-0}" -lt 30 ] && warn "only ${free_gb} GB free; building every app can need 30-60 GB"
  say "Building apps (only new or changed versions; a first build can take 1-3 hours)"
  pkill -f "xtask local serve" 2>/dev/null
  (cd "$L" && cargo xtask local sync --keep 1) 2>&1 | tee "$CRAFT_HOME/craft_build_log.txt"
  echo "   full log: $CRAFT_HOME/craft_build_log.txt"
}

# ---- Mac apps -----------------------------------------------------------------------------------
install_launcher_app() {
  say "Building ArtCraft Launcher.app"
  (cd "$L" && cargo build --release -p artcraft-launcher --features local-mirror && cargo build -q -p xtask) \
    || die "launcher build failed"
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
  nohup "$L/target/debug/xtask" local serve --mirror "$MIRROR" --port $PORT > "$CRAFT_HOME/craft_serve_log.txt" 2>&1 &
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
cmd_open() {
  [ -d "$LAUNCHER_APP" ] || die "ArtCraft Launcher.app isn't installed yet: run ./run.sh setup"
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
  if [ "$before" != "$after" ] || [ ! -d "$LAUNCHER_APP" ]; then install_launcher_app; fi
  [ -d "$SETUP_APP" ] || install_setup_app
  say "Up to date. Click Update/Install on any app that offers it."
  cmd_open
}

cmd_status() {
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  (cd "$L" && cargo xtask local status)
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
  select c in "Update everything and open" "Open dashboard" "Status" "Full setup" "Reinstall apps" "Publish to GitHub" "Quit"; do
    case "$REPLY" in
      1) cmd_update; break ;; 2) cmd_open; break ;; 3) cmd_status; break ;; 4) cmd_setup; break ;;
      5) prereqs; install_launcher_app; install_setup_app; break ;; 6) cmd_publish; break ;; *) break ;;
    esac
  done
}

case "${1:-menu}" in
  setup) cmd_setup ;;
  update) cmd_update ;;
  open) cmd_open ;;
  status) cmd_status ;;
  install-apps) prereqs; install_launcher_app; install_setup_app ;;
  publish) cmd_publish ;;
  menu) menu ;;
  -h|--help|help) sed -n '2,14p' "$0" ;;
  *) die "unknown command '$1' (try: ./run.sh help)" ;;
esac
