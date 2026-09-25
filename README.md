# Midium releases

Public release channel for **Midium** - the local AI desktop app for Apple Silicon Macs.

- **Download the app:** [Midium.dmg](https://github.com/rosstoss/midium-dist/releases/latest/download/Midium.dmg)
- **Headless / SSH install** (engine + `midium` CLI, no app):

  ```bash
  curl -fsSL https://raw.githubusercontent.com/rosstoss/midium-dist/refs/heads/main/install.sh | bash
  ```

  Then run `midium setup`.

Requires macOS on Apple Silicon (M-series).

Each release is tagged `v<version>` and carries two assets: `Midium.dmg` (the app) and
`midium-macos-arm64.tar.gz` (the engine, used by `install.sh` and `midium update`).
