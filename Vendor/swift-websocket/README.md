# Vendored: swift-websocket

- Upstream: https://github.com/hummingbird-project/swift-websocket
- Vendored version: 1.6.1
- Local modification: `Sources/WSCore/WebSocketHandler.swift` replaces three uses of
  `Task.sleep(for:)` with `ContinuousClock().sleep(until:)` (the close-timeout task at
  line 198 and the auto-ping loop at lines 246 and 250). Verified by a full tree diff
  against the 1.6.1 tag - this is the only file that differs from upstream.
- License: Apache-2.0 (see `LICENSE.txt` in this directory, unmodified from upstream).
  Upstream 1.6.1 also ships a `NOTICE.txt` attributing MIT-licensed code from
  `swift-nio-extras`; that notice is required by Apache-2.0 §4(d) and is included
  alongside this README as `NOTICE.txt`, fetched verbatim from the 1.6.1 tag.
