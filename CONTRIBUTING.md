# Contributing to TailMount

Contributions are welcome! Here's how to get started.

## Development Setup

1. Install [Xcode 16+](https://developer.apple.com/xcode/) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   ```bash
   brew install xcodegen
   ```

2. Clone and build:
   ```bash
   git clone https://github.com/YOUR_USERNAME/TailMount.git
   cd TailMount
   xcodegen generate
   xcodebuild -project TailMount.xcodeproj -scheme TailMount build
   ```

3. The `.xcodeproj` is generated from `project.yml` — edit `project.yml` for project settings, not the Xcode project directly.

## Making Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test by building and running the app
5. Commit your changes (`git commit -m 'Add my feature'`)
6. Push to your branch (`git push origin feature/my-feature`)
7. Open a Pull Request

## Code Style

- Swift 5.10, SwiftUI, targeting macOS 14+
- Follow existing patterns in the codebase
- Keep services as actors or final classes for thread safety
- Use async/await for all I/O operations

## Project Structure

- `project.yml` — XcodeGen project definition (source of truth)
- `TailMount/App/` — App entry point and state management
- `TailMount/Services/` — Tailscale discovery, SFTP, WebDAV, mounting
- `TailMount/Views/` — SwiftUI views
- `TailMount/Models/` — Data models
- `scripts/` — Build and packaging scripts

## Reporting Issues

Use [GitHub Issues](../../issues) for bugs and feature requests. Include:
- macOS version
- Tailscale version
- Steps to reproduce
- Any error messages from the app
