#!/usr/bin/env bash
#
# I-2: storage-layout regression guard.
# Re-renders the storage layout of upgradeable contracts and diffs against the
# checked-in snapshots in snapshots/storage/. Any drift is a potential
# upgrade-safety bug — a renamed/reordered slot collides with the existing proxy.
#
# Usage:
#   bash scripts-js/check-storage-layout.sh           # check
#   UPDATE_SNAPSHOTS=1 bash scripts-js/check-storage-layout.sh   # rewrite
set -euo pipefail

CONTRACTS=(
  SplitRiskPool
  SplitRiskPoolFactory
)

SNAPSHOT_DIR="snapshots/storage"
mkdir -p "$SNAPSHOT_DIR"

failed=0
for name in "${CONTRACTS[@]}"; do
  current="$(forge inspect "$name" storageLayout --json)"
  snap="$SNAPSHOT_DIR/$name.json"

  if [[ "${UPDATE_SNAPSHOTS:-}" == "1" ]]; then
    printf '%s\n' "$current" > "$snap"
    echo "snapshot updated: $snap"
    continue
  fi

  if [[ ! -f "$snap" ]]; then
    echo "missing snapshot: $snap (run UPDATE_SNAPSHOTS=1 $0)" >&2
    failed=1
    continue
  fi

  if ! diff -u "$snap" <(printf '%s\n' "$current"); then
    echo "storage layout drifted for $name. If intentional, run UPDATE_SNAPSHOTS=1 $0" >&2
    failed=1
  else
    echo "ok: $name"
  fi
done

exit "$failed"
