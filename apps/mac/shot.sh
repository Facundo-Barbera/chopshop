#!/bin/bash
set -euo pipefail
out="$1"; sec="${2:-overview}"
rm -f "$out" "$out.done"
echo "$sec $out" > /tmp/chopshop-shot.req
for i in $(seq 1 40); do [ -f "$out.done" ] && break; sleep 0.5; done
cat "$out.done"; rm -f "$out.done"
