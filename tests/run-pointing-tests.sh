#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macremote-pointing-tests.XXXXXX)
# Keep the compiled binary in the temporary directory for easy reruns/debugging.
swiftc -module-cache-path "$test_dir/cache" \
  iOS/MacRemoteClient/OrientationPointer.swift \
  iOS/MacRemoteClient/TouchSurfaceState.swift \
  iOS/MacRemoteClient/ReconnectActionBuffer.swift \
  MacRemoteServer/Sources/MacRemoteServer/VirtualCursor.swift \
  MacRemoteServer/Sources/MacRemoteServer/PointerResetState.swift \
  MacRemoteServer/Sources/MacRemoteServer/StatusPoller.swift \
  MacRemoteServer/Sources/MacRemoteServer/CursorSmoother.swift \
  MacRemoteServer/Sources/MacRemoteServer/CursorVisibilityState.swift \
  tests/PointingTests.swift -o "$test_dir/pointing-tests"
"$test_dir/pointing-tests"
