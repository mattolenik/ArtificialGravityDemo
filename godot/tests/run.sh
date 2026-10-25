#!/bin/sh
# Runs every headless test; fails if any test errors, hangs, or doesn't print PASS.
cd "$(dirname "$0")/.." || exit 1
godot --headless --path . --import >/dev/null 2>&1
status=0
for t in tests/test_*.gd; do
  out=$(godot --headless --path . --fixed-fps 60 --quit-after 7200 -s "res://$t" 2>&1)
  echo "$out" | tail -n 3
  # Warnings (e.g. the intermittent Jolt "max jobs" one from --fixed-fps) are engine noise and pass.
  echo "$out" | grep -qE '^(SCRIPT )?ERROR' && { echo "FAIL $t"; status=1; }
  echo "$out" | tail -n 1 | grep -q '^PASS' || { echo "FAIL $t"; status=1; }
done
exit $status
