#!/usr/bin/env bash
# parrot installer.
#   curl -fsSL https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh | sh
#
# Fetches the latest arm64 macOS binary from GitHub Releases, drops it
# in /usr/local/bin, and strips the quarantine xattr so Gatekeeper doesn't
# block the unsigned binary.
#
# Apple Silicon only — WhisperKit uses the Apple Neural Engine via CoreML,
# which only ships on M-series chips.

set -euo pipefail

REPO="encore-ai-labs/parrot"
BIN_NAME="parrot"
INSTALL_DIR="${PARROT_INSTALL_DIR:-/usr/local/bin}"
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
    STAGED=$(mktemp "${INSTALL_DIR}/.parrot-update.XXXXXX")
    cp "$TMP/${BIN_NAME}" "$STAGED"
    chmod 755 "$STAGED"
    mv -f "$STAGED" "$TARGET"
    STAGED=""
else
    dim "→ administrator access required"
    dim "  approve the standard macOS prompt to finish the update"
    /usr/bin/osascript \
        -e 'use scripting additions' \
        -e 'on run argv' \
        -e 'set installDirectory to item 1 of argv' \
        -e 'set sourcePath to item 2 of argv' \
        -e 'set targetPath to item 3 of argv' \
        -e 'set installCommand to "/bin/mkdir -p " & quoted form of installDirectory & " && /bin/mv " & quoted form of sourcePath & " " & quoted form of targetPath & " && /bin/chmod 755 " & quoted form of targetPath' \
        -e 'do shell script installCommand with administrator privileges' \
        -e 'end run' \
        "$INSTALL_DIR" "$TMP/${BIN_NAME}" "$TARGET" >/dev/null
fi

xattr -d com.apple.quarantine "$TARGET" 2>/dev/null || true

green "✓ parrot ${TAG} installed at ${TARGET}"
if [ "${PARROT_UPDATE_MODE:-0}" != "1" ]; then
    echo
    echo "next:"
    echo "  parrot setup       # grant mic + accessibility"
    echo "  parrot hotkeys     # pick a push-to-talk key (fn only works on Apple keyboards)"
    echo "  parrot devices     # pick a mic — avoid Bluetooth if you listen to music"
    echo "  parrot             # run the daemon"
fi
