# Releasing

parrot lives at **`encore-ai-labs/parrot`**, a public fork of `digimata/parrot`. Releases are
cut from this fork; we don't sync with upstream.

## Updating your own install

While developing, skip releases entirely:

```sh
swift build -c release
sudo cp .build/release/parrot /usr/local/bin/parrot
pkill -x parrot          # then restart it in a terminal tab
```

`/usr/local/bin` is root-owned, hence the `sudo`. Release binaries report their stamped tag
with `parrot --version`; local development builds report `development`.

## Cutting a release

`.github/workflows/release.yml` fires on any `v*` tag. It builds an arm64 release binary on a
`macos-15` runner, strips it, tars it, and attaches `parrot-macos-arm64.tar.gz` plus a
`.sha256` to a GitHub Release. Before compiling, the workflow stamps the tag into
`AppVersion.current`; do not manually edit that development placeholder.

```sh
git tag -a v0.1.0 -m "v0.1.0 — short description"
git push origin v0.1.0
gh run watch -R encore-ai-labs/parrot        # ~3 min, mostly WhisperKit compile
gh release view v0.1.0 -R encore-ai-labs/parrot
```

The repository's fork workflow permission is enabled, so pushing a `v*` tag starts the release
automatically. Do not also dispatch `release.yml`; that creates a redundant second run for the
same tag. If a future fork has Actions disabled, enable it once in the repository's **Actions**
tab, then push the tag.

Tags are the only automatic trigger — pushing to `master` builds nothing. There is no CI on
pull requests yet either, so nothing is compiled or tested before a tag goes out (roadmap 6.1).

**On a fresh fork, the workflow may not be registered at all.** GitHub only picks up inherited
workflow files once the fork gets its own push. If
`gh api repos/encore-ai-labs/parrot/actions/workflows` comes back empty, push a commit to
`master` first, then tag.

After the run is green, verify what actually shipped:

```sh
curl -fsSL https://api.github.com/repos/encore-ai-labs/parrot/releases/latest | grep tag_name
```

The installer resolves the download URL from that endpoint, so if it doesn't report your new
tag, `curl | sh` will still hand people the old build.

If a release goes out wrong:

```sh
gh release delete v0.1.0 -R encore-ai-labs/parrot --yes
git push --delete origin v0.1.0
git tag -d v0.1.0
```

## How someone else installs it

The repo is public, so this needs no auth:

```sh
curl -fsSL https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh | sh
```

The installer refuses to run on Intel (WhisperKit needs the Apple Neural Engine), pulls the
latest release's tarball, drops the binary in `/usr/local/bin`, and strips the quarantine
xattr. It resolves "latest release" from the GitHub API, so **at least one release must
exist** — otherwise it exits with "couldn't determine latest release tag".

There's no `gh-pages` branch on this fork, so the `raw.githubusercontent.com` URL is the
install path. (Upstream's `digimata.github.io/parrot/install.sh` serves *their* build, not
ours — don't send people there.)

Building from source is the other option and needs no release at all:

```sh
git clone https://github.com/encore-ai-labs/parrot.git
cd parrot && swift build -c release
sudo cp .build/release/parrot /usr/local/bin/parrot
```

### What to tell them after they install

```sh
parrot setup      # grants mic + accessibility (attaches to their terminal, not parrot)
parrot hotkeys    # fn only works on Apple keyboards — pick another on a mechanical
parrot devices    # avoid a Bluetooth default input if they listen to music
parrot --hotkey end
```

Three things reliably trip people up, in order:

1. **`fn` does nothing on a third-party keyboard.** It's a firmware-local layer key that never
   reaches macOS. Not a bug, not fixable — pick another key.
2. **Bluetooth headphones turn to telephone quality.** If their default *input* is a headset,
   opening the mic drags it off A2DP. System Settings → Sound → Input → built-in or USB.
3. **Short taps capture nothing.** The mic needs ~170 ms to produce its first sample. Hold,
   then talk.

If dictation does nothing at all, `parrot doctor` covers the usual causes (accessibility not
granted, mic denied, Fn mapped to emoji/dictation).

## If the repo goes private

A public fork **cannot be flipped to private** — GitHub blocks it. You'd need to mirror-push
into a fresh private repo:

```sh
git clone --bare https://github.com/encore-ai-labs/parrot.git
cd parrot.git && git push --mirror https://github.com/encore-ai-labs/<new-name>.git
```

Anonymous `curl | sh` stops working at that point: release assets on private repos need an
authenticated request. The installer would have to switch to
`gh release download -R encore-ai-labs/<new-name>`, which means everyone installing needs `gh`
and org membership.

## Not yet wired

- **Signing and notarization** (roadmap 5.2/5.3). Builds are ad-hoc signed with no Team ID, so
  macOS revokes the Accessibility grant on **every update** — after upgrading, users must
  re-toggle parrot in System Settings → Privacy & Security → Accessibility. A Developer ID
  identity is available; wiring it in removes this entirely.
- **`--launch-at-login`.** Lifecycle controls, single-instance locking, private logs, explicit
  bootstrap errors, and a 30-second failure throttle are implemented. Don't recommend it until
  signing lands: under `launchd` Parrot still gets its own TCC identity, and an updated ad-hoc
  binary can lose its Accessibility grant.
