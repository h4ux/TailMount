# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

TailMount is a macOS menu bar app (SwiftUI, macOS 14+) that discovers Tailscale SSH-enabled servers and lets users mount them as local Finder volumes with a single click. No external dependencies need to be installed — all SSH/SFTP functionality is built in via the Citadel Swift package.

## Build Commands

```bash
# Generate Xcode project from project.yml (required before first build)
xcodegen generate

# Build
xcodebuild -project TailMount.xcodeproj -scheme TailMount -configuration Release build

# Create distributable DMG
./scripts/build-dmg.sh
```

The `.xcodeproj` is gitignored and generated from `project.yml` via XcodeGen. Always edit `project.yml` for project settings — never the xcodeproj directly.

## Dependencies

**Build-time (SPM, declared in project.yml):**
- `Citadel` — Pure Swift SSH/SFTP client (built on SwiftNIO SSH)
- `swift-nio` — NIOCore, NIOPosix, NIOHTTP1 for the local WebDAV server

**Runtime:**
- Tailscale CLI — discovered at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/usr/local/bin/tailscale`, or `/opt/homebrew/bin/tailscale`
- The Tailscale binary needs `TERM` env var set to run in CLI mode from a subprocess (otherwise it tries to launch as GUI and fails)

## Architecture

**Menu bar app** — `LSUIElement=true` in Info.plist, no Dock icon. Uses `MenuBarExtra` with `.window` style.

**Data flow:**
1. `TailscaleService` runs `tailscale status --json` (stdout written to temp file to avoid 64KB pipe buffer deadlock), parses peers, filters to online non-mobile nodes, then probes SSH port 22 concurrently
2. `AppState` (central `@MainActor ObservableObject`) tracks per-node `MountState` and auto-refreshes every 30s
3. On mount: `MountService` creates an `SFTPBridge` → connects via Citadel SSH with "none" auth (Tailscale SSH) → starts a local `WebDAVServer` (NIO HTTP on 127.0.0.1) → calls `mount_webdav` (with admin privilege escalation for /Volumes)
4. Mount points appear at `/Volumes/<server-name>/`

**Key design decisions:**
- SSH auth uses NIO SSH "none" offer — Tailscale SSH authenticates via WireGuard tunnel identity, no keys/passwords needed
- `~/.ssh/config` is parsed for per-host `User` directives; falls back to macOS username
- Tailscale CLI output goes to a temp file (not a pipe) because the JSON can exceed 800KB, causing pipe buffer deadlock
- `TERM=xterm-256color` is set in the process environment so the Tailscale macOS binary runs in CLI mode instead of trying to launch as a GUI
- The app is not sandboxed — needs to run CLI tools, create mount points in /Volumes, and bind local server ports
- `SFTPBridge` is an actor for thread-safe SFTP operations from the NIO event loop
