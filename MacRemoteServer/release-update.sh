#!/bin/zsh
# Kept as a compatibility entry point. Production releases now require the
# hardened-runtime, notarized workflow in release-mac.sh.
set -euo pipefail
root="${0:A:h}"
exec "$root/release-mac.sh" "$@"
