#!/usr/bin/env bash

set -e

# ── config ───────────────────────────────────────────────────────────────────
GITHUB_USER="rosstoss"
GITHUB_REPO="midium-dist"
BINARY_NAME="midium"
REAL_BINARY="Midium"
COURIER_ROOT="$HOME/Midium"
LEGACY_ROOT="$HOME/.courier"
APP_DIR="$COURIER_ROOT/app"
BIN_DIR="$COURIER_ROOT/bin"
ASSET_NAME="midium-macos-arm64.tar.gz"
EDITION_LABEL="Midium"

LATEST_RELEASE_URL="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/releases/latest"
COURIER_VERSION="$(curl -fsSL "$LATEST_RELEASE_URL" 2>/dev/null \
  | grep '"tag_name":' | head -1 \
  | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' | tr -d '[:space:]')"
[ -z "$COURIER_VERSION" ] && COURIER_VERSION="latest"

DOWNLOAD_URL="https://github.com/$GITHUB_USER/$GITHUB_REPO/releases/latest/download/$ASSET_NAME"
# A private temp file (a fixed /tmp path could be pre-created by another user).
TMP_TAR="$(mktemp -t midium_download).tar.gz"
ENGINE_PORT="${UCE_PORT:-9100}"
ORIG_PATH="$PATH"

ACCENT=$'\033[38;2;122;158;177m'
SUCCESS=$'\033[38;2;127;174;127m'
ERRC=$'\033[38;2;201;122;122m'
MUTED=$'\033[38;2;138;141;148m'
DIM=$'\033[38;2;94;96;102m'
TEXT=$'\033[38;2;212;214;219m'
BOLD=$'\033[1m'
NC=$'\033[0m'
CLR=$'\033[K'
HIDE_CUR=$'\033[?25l'
SHOW_CUR=$'\033[?25h'
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
LABEL_W=15

RESET=$'\033[0m'

TTY=0; [ -t 1 ] && TTY=1

if [ "$TTY" -eq 1 ]; then
  BG=$'\033[48;2;21;23;28m'
  NC=$'\033[0m'"${BG}"$'\033[38;2;212;214;219m'
else
  BG=""
fi
cleanup() {
  rm -f "$TMP_TAR" "${TMP_TAR%.tar.gz}" 2>/dev/null || true
  [ "$TTY" -eq 1 ] && printf '%s%s' "$RESET" "$SHOW_CUR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── helpers ───────────────────────────────────────────────────────────────────
bar() {
  local pct=${1:-0} width=${2:-18} filled i out=""
  filled=$(( pct * width / 100 ))
  if [ "$filled" -lt 0 ]; then filled=0; fi
  if [ "$filled" -gt "$width" ]; then filled=$width; fi

  out="$SUCCESS"
  for (( i=0; i<width; i++ )); do
    if [ "$i" -eq "$filled" ]; then out="$out$DIM"; fi
    if [ "$i" -lt "$filled" ]; then out="$out-"; else out="$out-"; fi
  done
  printf '%s%s' "$out" "$NC"
}

human() {  # $1 bytes -> human size
  local b=${1:-0}
  if [ "$b" -ge 1073741824 ]; then
    printf '%d.%01d GB' $(( b / 1073741824 )) $(( b % 1073741824 * 10 / 1073741824 ))
  elif [ "$b" -ge 1048576 ]; then
    printf '%d MB' $(( b / 1048576 ))
  else
    printf '%d KB' $(( b / 1024 ))
  fi
}

step_done() { printf '\r  %s[✓]%s %-*s %s%s%s%s\n' "$SUCCESS" "$NC" "$LABEL_W" "$1" "$DIM" "${2:-}" "$NC" "$CLR"; }
step_fail() { printf '\r  %s[✗]%s %-*s %s%s%s%s\n' "$ERRC" "$NC" "$LABEL_W" "$1" "$ERRC" "${2:-}" "$NC" "$CLR"; }

# Download $1 -> $2 with a live progress bar (%, size, speed, ETA).
download() {
  local url=$1 out=$2 total cur=0 start elapsed speed eta pct tick=0
  total=$(curl -fsIL "$url" 2>/dev/null \
    | awk '{ if (tolower($0) ~ /^content-length:/) v=$2 } END { gsub(/[^0-9]/,"",v); print v+0 }')
  [ -z "$total" ] && total=0
  rm -f "$out"
  curl -fL "$url" -o "$out" 2>/dev/null &
  local pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ -f "$out" ]; then cur=$(stat -f%z "$out" 2>/dev/null || echo 0); fi
    elapsed=$(( SECONDS - start )); if [ "$elapsed" -lt 1 ]; then elapsed=1; fi
    speed=$(( cur / elapsed ))
    if [ "$total" -gt 0 ]; then
      pct=$(( cur * 100 / total )); if [ "$pct" -gt 99 ]; then pct=99; fi
      eta=0; if [ "$speed" -gt 0 ]; then eta=$(( (total - cur) / speed )); fi
      printf '\r  %s%s%s %-*s %s %s%3d%%%s  %s%s / %s · %s/s · ETA %ds%s%s' \
        "$ACCENT" "${SPIN[tick%10]}" "$NC" "$LABEL_W" "Downloading" "$(bar "$pct")" \
        "$TEXT" "$pct" "$NC" "$DIM" "$(human "$cur")" "$(human "$total")" "$(human "$speed")" "$eta" "$NC" "$CLR"
    else
      printf '\r  %s%s%s %-*s %s%s · %s/s%s%s' \
        "$ACCENT" "${SPIN[tick%10]}" "$NC" "$LABEL_W" "Downloading" "$DIM" "$(human "$cur")" "$(human "$speed")" "$NC" "$CLR"
    fi
    tick=$(( tick + 1 )); sleep 0.2
  done
  local rc=0; wait "$pid" || rc=$?
  return $rc
}

# Extract $1 -> $2 with a progress bar driven by gzip's uncompressed-size footer.
extract() {
  local tarball=$1 dest=$2 total_b total_kb cur_kb pct tick=0
  total_b=$(tail -c 4 "$tarball" 2>/dev/null | od -An -tu4 2>/dev/null | tr -d ' ' || echo 0)
  [ -z "$total_b" ] && total_b=0
  total_kb=$(( total_b / 1024 ))
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xf "$tarball" -C "$dest" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    cur_kb=$(du -sk "$dest" 2>/dev/null | awk '{print $1}'); [ -z "$cur_kb" ] && cur_kb=0
    if [ "$total_kb" -gt 1024 ]; then
      pct=$(( cur_kb * 100 / total_kb )); if [ "$pct" -gt 99 ]; then pct=99; fi
      printf '\r  %s%s%s %-*s %s %s%3d%%%s  %s%s%s%s' \
        "$ACCENT" "${SPIN[tick%10]}" "$NC" "$LABEL_W" "Extracting" "$(bar "$pct")" \
        "$TEXT" "$pct" "$NC" "$DIM" "$(human $(( cur_kb * 1024 )))" "$NC" "$CLR"
    else
      printf '\r  %s%s%s %-*s %s%s%s%s' \
        "$ACCENT" "${SPIN[tick%10]}" "$NC" "$LABEL_W" "Extracting" "$DIM" "$(human $(( cur_kb * 1024 )))" "$NC" "$CLR"
    fi
    tick=$(( tick + 1 )); sleep 0.2
  done
  local rc=0; wait "$pid" || rc=$?
  return $rc
}

# Ad-hoc codesign the binary + native libs with a per-file progress bar.
sign() {
  local dir=$1 list total i=0 pct f
  list=$(find "$dir" -type f \( -name "Midium" -o -name "Courier" -o -name "Courier OS" -o -name "*.dylib" -o -name "*.so" \) 2>/dev/null || true)
  total=$(printf '%s\n' "$list" | grep -c . 2>/dev/null || true); [ -z "$total" ] && total=0
  if [ "$total" -eq 0 ]; then return 0; fi
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    codesign --force --deep --sign - "$f" >/dev/null 2>&1 || true
    i=$(( i + 1 )); pct=$(( i * 100 / total )); if [ "$pct" -gt 100 ]; then pct=100; fi
    printf '\r  %s%s%s %-*s %s %s%3d%%%s  %s%d / %d%s%s' \
      "$ACCENT" "${SPIN[i%10]}" "$NC" "$LABEL_W" "Verifying" "$(bar "$pct")" \
      "$TEXT" "$pct" "$NC" "$DIM" "$i" "$total" "$NC" "$CLR"
  done <<< "$list"
  return 0
}

# ── banner ────────────────────────────────────────────────────────────────────
if [ "$TTY" -eq 1 ]; then
  printf '%s\033[2J\033[H%s' "$NC" "$HIDE_CUR"
else
  clear 2>/dev/null || true
fi
printf '%s\n' "$ACCENT"
echo "███╗   ███╗██╗██████╗ ██╗██╗   ██╗███╗   ███╗"
echo "████╗ ████║██║██╔══██╗██║██║   ██║████╗ ████║"
echo "██╔████╔██║██║██║  ██║██║██║   ██║██╔████╔██║"
echo "██║╚██╔╝██║██║██║  ██║██║██║   ██║██║╚██╔╝██║"
echo "██║ ╚═╝ ██║██║██████╔╝██║╚██████╔╝██║ ╚═╝ ██║"
echo "╚═╝     ╚═╝╚═╝╚═════╝ ╚═╝ ╚═════╝ ╚═╝     ╚═╝"
printf '%s   %s · installing v%s%s\n\n' "$MUTED" "$EDITION_LABEL" "$COURIER_VERSION" "$NC"

# ── 1. system check (Apple Silicon + macOS version) ───────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  step_fail "System check" "Midium requires an Apple Silicon Mac"
  exit 1
fi

MIN_MACOS_MAJOR=26
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo "")"
MACOS_MAJOR="${MACOS_VER%%.*}"
case "$MACOS_MAJOR" in ""|*[!0-9]*) MACOS_MAJOR=0 ;; esac
if [ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
  step_fail "System check" "requires macOS ${MIN_MACOS_MAJOR}+ (Tahoe), but you're on ${MACOS_VER:-unknown}."
  printf '  %sUpdate macOS via  System Settings → General → Software Update,  then re-run this installer.%s\n' "$MUTED" "$NC"
  exit 1
fi
step_done "System check" "Apple Silicon · macOS $MACOS_VER"

# ── 2. home folder + PATH ─────────────────────────────────────────────────────
ENGINE_WAS_RUNNING=0
ENGINE_PID="$(lsof -nP -iTCP:"$ENGINE_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
ENGINE_EXE=""
if [ -n "$ENGINE_PID" ]; then
  ENGINE_EXE="$(lsof -a -p "$ENGINE_PID" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  if [[ "$ENGINE_EXE" == "$APP_DIR/"* ]] || [[ "$ENGINE_EXE" == "$LEGACY_ROOT/app/"* ]]; then
    ENGINE_WAS_RUNNING=1
  fi
fi

LEGACY_INSTALL=0
if { [ -d "$LEGACY_ROOT" ] && [ ! -L "$LEGACY_ROOT" ]; } \
   || [ -f "$APP_DIR/Courier" ] || [ -f "$APP_DIR/Courier OS" ]; then
  LEGACY_INSTALL=1
  for old in "Courier" "Courier OS" "Enclave"; do pkill -x "$old" 2>/dev/null || true; done
fi
KEEP_COURIER_ALIAS=$LEGACY_INSTALL
{ [ -e "$BIN_DIR/courier" ] || [ -L "$BIN_DIR/courier" ]; } && KEEP_COURIER_ALIAS=1
REMOVED_APPS=""
for old in "Courier" "Courier OS" "Enclave"; do
  for dir in "/Applications" "$HOME/Applications"; do
    bundle="$dir/$old.app"
    [ -d "$bundle" ] || continue
    # Only ask a RUNNING app to quit — `tell application` launches one that isn't.
    if pgrep -x "$old" >/dev/null 2>&1; then
      osascript -e "tell application \"$old\" to quit" >/dev/null 2>&1 || true
      sleep 1
      pkill -x "$old" 2>/dev/null || true
    fi
    dest="$HOME/.Trash/$old.app"
    [ -e "$dest" ] && dest="$HOME/.Trash/$old $(date +%Y%m%d-%H%M%S).app"
    if mv "$bundle" "$dest" 2>/dev/null; then
      REMOVED_APPS="${REMOVED_APPS:+$REMOVED_APPS, }$old"
    else
      step_fail "Old apps" "couldn't move ${bundle/#$HOME/~} to the Trash — remove it by hand"
    fi
  done
done
[ -n "$REMOVED_APPS" ] && step_done "Old apps" "moved to Trash: $REMOVED_APPS"

if [ ! -e "$COURIER_ROOT" ] && [ -d "$LEGACY_ROOT" ] && [ ! -L "$LEGACY_ROOT" ]; then
  mv "$LEGACY_ROOT" "$COURIER_ROOT" && ln -s "$COURIER_ROOT" "$LEGACY_ROOT"
  step_done "Migrate" "moved ~/.courier → ~/Midium"
fi
mkdir -p "$APP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"
if [[ "$SHELL" == *"bash"* ]]; then
  SHELL_CONFIGS=("$HOME/.bash_profile" "$HOME/.bashrc")
else
  SHELL_CONFIGS=("$HOME/.zshenv")
fi
ADDED_TO=""
for cfg in "${SHELL_CONFIGS[@]}"; do
  [ -f "$cfg" ] || touch "$cfg"
  if ! grep -q "$BIN_DIR" "$cfg" 2>/dev/null; then
    printf "\n# Midium\nexport PATH=\"%s:\$PATH\"\n" "$BIN_DIR" >> "$cfg"
    ADDED_TO="${ADDED_TO:+$ADDED_TO, }${cfg/#$HOME/~}"
  fi
done
if [ -n "$ADDED_TO" ]; then
  step_done "Configure PATH" "added to $ADDED_TO"
else
  step_done "Configure PATH" "already configured"
fi

# ── 3. download ───────────────────────────────────────────────────────────────
if download "$DOWNLOAD_URL" "$TMP_TAR"; then
  step_done "Download" "$(human "$(stat -f%z "$TMP_TAR" 2>/dev/null || echo 0)") · $ASSET_NAME"
else
  step_fail "Download" "could not fetch $ASSET_NAME — check your connection"
  exit 1
fi

if ! tar -tf "$TMP_TAR" >/dev/null 2>&1; then
  step_fail "Download" "archive is corrupt — please retry"
  rm -f "$TMP_TAR"; exit 1
fi

if [ "$ENGINE_WAS_RUNNING" -eq 1 ]; then
  if lsof -nP -iTCP:"$ENGINE_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
    if [ -x "$APP_DIR/$REAL_BINARY" ]; then
      "$APP_DIR/$REAL_BINARY" stop >/dev/null 2>&1 || kill "$ENGINE_PID" 2>/dev/null || true
    else
      kill "$ENGINE_PID" 2>/dev/null || true
    fi
    for _ in $(seq 1 40); do
      lsof -nP -iTCP:"$ENGINE_PORT" -sTCP:LISTEN -t >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  step_done "Stop engine" "stopped the running engine (it restarts after the update)"
fi
for old in Midium Courier "Courier OS" Enclave; do
  if [ -f "$APP_DIR/$old" ]; then
    pkill -f "^$APP_DIR/$old( |\$)" 2>/dev/null || true
    rm -f "$APP_DIR/$old"
  fi
done
for old in enclave courier-os; do
  if [ -L "$BIN_DIR/$old" ] || [ -f "$BIN_DIR/$old" ]; then rm -f "$BIN_DIR/$old"; fi
done

# ── 4. extract ────────────────────────────────────────────────────────────────
if extract "$TMP_TAR" "$APP_DIR"; then
  step_done "Extract" "unpacked to ${APP_DIR/#$HOME/~}"
else
  step_fail "Extract" "failed to unpack the archive"
  exit 1
fi
rm -f "$TMP_TAR"

# ── 5. verify (quarantine + codesign) ─────────────────────────────────────────
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
sign "$APP_DIR"
step_done "Verify" "signed for this Mac"

# ── 6. finalize ───────────────────────────────────────────────────────────────
[ -L "$BIN_DIR/$BINARY_NAME" ] && rm "$BIN_DIR/$BINARY_NAME"
ln -sf "$APP_DIR/$REAL_BINARY" "$BIN_DIR/$BINARY_NAME"
if [ "$KEEP_COURIER_ALIAS" -eq 1 ]; then
  ln -sf "$APP_DIR/$REAL_BINARY" "$BIN_DIR/courier"
fi
chmod +x "$APP_DIR/$REAL_BINARY"
hash -r 2>/dev/null || true
echo "$COURIER_VERSION" > "$COURIER_ROOT/VERSION"
step_done "Finalize" "midium v$COURIER_VERSION ready"

if [ "$ENGINE_WAS_RUNNING" -eq 1 ]; then
  ( cd "$COURIER_ROOT" && "$APP_DIR/$REAL_BINARY" start --detach >/dev/null 2>&1 ) || true
  UP=0
  for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:$ENGINE_PORT/healthz" >/dev/null 2>&1; then UP=1; break; fi
    sleep 1
  done
  if [ "$UP" -eq 1 ]; then
    step_done "Restart engine" "running again on :$ENGINE_PORT"
  else
    step_fail "Restart engine" "didn't come back within 2 min — check: midium logs"
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────────
printf '\n  %s%s✓ Midium installed.%s\n\n' "$BOLD" "$SUCCESS" "$NC"
if [ "$LEGACY_INSTALL" -eq 1 ]; then
  printf '  %sCourier is now Midium. Your models, chats and settings moved to ~/Midium,\n  and `courier` still works as another name for `midium`.%s\n\n' "$MUTED" "$NC"
fi
if [ "$ENGINE_WAS_RUNNING" -ne 1 ]; then
  printf '  %sRun:%s %s%s setup%s\n\n' "$MUTED" "$NC" "$BOLD" "$BINARY_NAME" "$NC"
fi
[ "$TTY" -eq 1 ] && printf '%s%s' "$RESET" "$SHOW_CUR"

case ":$ORIG_PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    if [ -z "${MIDIUM_UPDATING:-}" ] && [ -t 1 ] && { : </dev/tty; } 2>/dev/null; then
      exec "${SHELL:-/bin/zsh}" -l </dev/tty
    fi
    ;;
esac
