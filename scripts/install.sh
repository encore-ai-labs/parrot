#!/usr/bin/env bash
# parrot installer.
#   curl -fsSL https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh | sh
#
# Fetches the latest arm64 macOS binary from GitHub Releases and strips the
# quarantine xattr so Gatekeeper doesn't block the unsigned binary. On Macs
# where /usr/local/bin is admin-owned, the real binary lives in the user's
# data directory and /usr/local/bin/parrot is a stable one-time symlink.
#
# Apple Silicon only — WhisperKit uses the Apple Neural Engine via CoreML,
# which only ships on M-series chips.

set -euo pipefail

REPO="encore-ai-labs/parrot"
BIN_NAME="parrot"
INSTALL_DIR="${PARROT_INSTALL_DIR:-/usr/local/bin}"
MANAGED_INSTALL_DIR="${PARROT_MANAGED_INSTALL_DIR:-${HOME}/.local/share/parrot/bin}"
ASSET="parrot-macos-arm64.tar.gz"
CHECKSUM="${ASSET}.sha256"

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }

# 1. sanity
if [ "$(uname -s)" != "Darwin" ]; then
    red "parrot is macOS-only (detected $(uname -s))"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    red "parrot requires Apple Silicon (detected $ARCH)"
    red "the on-device inference engine uses the Apple Neural Engine, which Intel Macs don't have."
    exit 1
fi

for cmd in curl tar shasum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

# 2. resolve latest release
dim "→ resolving latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
CHECKSUM_URL="https://github.com/${REPO}/releases/download/${TAG}/${CHECKSUM}"

# 3. download + extract
TMP=$(mktemp -d)
STAGED=""
cleanup() {
    rm -rf "$TMP"
    if [ -n "$STAGED" ]; then
        rm -f "$STAGED"
    fi
}
trap cleanup EXIT

dim "→ downloading ${ASSET}..."
curl -fsSL "$URL" -o "$TMP/${ASSET}"
curl -fsSL "$CHECKSUM_URL" -o "$TMP/${CHECKSUM}"

dim "→ verifying SHA-256 checksum..."
(cd "$TMP" && shasum -a 256 -c "$CHECKSUM")

dim "→ extracting..."
tar -xzf "$TMP/${ASSET}" -C "$TMP"

if [ ! -f "$TMP/${BIN_NAME}" ]; then
    red "archive did not contain ${BIN_NAME}"
    exit 1
fi

chmod +x "$TMP/${BIN_NAME}"

# 4. strip quarantine so Gatekeeper lets the unsigned binary run
xattr -d com.apple.quarantine "$TMP/${BIN_NAME}" 2>/dev/null || true

# 5. install
TARGET="${INSTALL_DIR}/${BIN_NAME}"

atomic_install() {
    local source="$1"
    local destination_dir="$2"
    local destination="$3"

    STAGED=$(mktemp "${destination_dir}/.parrot-update.XXXXXX")
    cp "$source" "$STAGED"
    chmod 755 "$STAGED"
    mv -f "$STAGED" "$destination"
    STAGED=""
}

# Always replace the executable with a new inode. Overwriting a running,
# signed Mach-O binary in place can leave macOS killing later launches even
# when the new bytes and signature are valid. Replacing the directory entry
# avoids that executable-vnode cache failure.
if [ -w "$INSTALL_DIR" ]; then
    if [ -e "$TARGET" ]; then
        dim "→ updating ${TARGET}..."
    else
        dim "→ installing to ${TARGET}..."
    fi
    atomic_install "$TMP/${BIN_NAME}" "$INSTALL_DIR" "$TARGET"
    FINAL_BINARY="$TARGET"
else
    MANAGED_TARGET="${MANAGED_INSTALL_DIR}/${BIN_NAME}"
    mkdir -p "$MANAGED_INSTALL_DIR"
    chmod 700 "$MANAGED_INSTALL_DIR"
    dim "→ updating ${MANAGED_TARGET}..."
    atomic_install "$TMP/${BIN_NAME}" "$MANAGED_INSTALL_DIR" "$MANAGED_TARGET"
    FINAL_BINARY="$MANAGED_TARGET"

    # Existing installations may have a root-owned executable at the public
    # command path. Replace it once with a symlink; every later update swaps
    # only the user-owned target and needs no password or authorization dialog.
    CURRENT_LINK="$(readlink "$TARGET" 2>/dev/null || true)"
    if [ ! -L "$TARGET" ] || [ "$CURRENT_LINK" != "$MANAGED_TARGET" ]; then
        if ! /usr/bin/tty </dev/tty >/dev/null 2>&1; then
            red "one-time Parrot install migration requires a terminal"
            red "run 'parrot update' from Terminal to finish without an osascript dialog"
            exit 1
        fi
        dim "→ one-time administrator access required"
        dim "  future Parrot updates will not need a password"
        /usr/bin/sudo -p "Parrot one-time install migration — Password: " -v
        /usr/bin/sudo /bin/mkdir -p "$INSTALL_DIR"
        /usr/bin/sudo /bin/ln -sfn "$MANAGED_TARGET" "$TARGET"
    fi
fi

xattr -d com.apple.quarantine "$FINAL_BINARY" 2>/dev/null || true

green "✓ parrot ${TAG} installed at ${TARGET}"
if [ "${PARROT_UPDATE_MODE:-0}" != "1" ]; then
    echo
    echo "next:"
    echo "  parrot setup       # grant mic + accessibility"
    echo "  parrot hotkeys     # pick a push-to-talk key (fn only works on Apple keyboards)"
    echo "  parrot devices     # pick a mic — avoid Bluetooth if you listen to music"
    echo "  parrot             # run the daemon"
fi
