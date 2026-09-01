# Vendored: hummingbird-websocket

- Upstream: https://github.com/hummingbird-project/hummingbird-websocket
- Vendored version: 2.7.0
- Local modification: `Package.swift` changes the `swift-websocket` dependency from
  a `from: "1.6.0"` version requirement to `.package(path: "../swift-websocket")`,
  so both vendored packages resolve against each other locally instead of fetching
  swift-websocket a second time from GitHub. No source files under `Sources/` are
  modified from upstream 2.7.0 (verified by a full tree diff against the 2.7.0 tag).
- License: Apache-2.0 (see `LICENSE.txt` in this directory, unmodified from upstream).
