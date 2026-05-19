#!/usr/bin/env bash
#
# I-2: storage-layout regression guard.
# Re-renders the storage layout of upgradeable contracts and diffs against the
# checked-in snapshots in snapshots/storage/. Any drift is a potential
# upgrade-safety bug — a renamed/reordered slot collides with the existing proxy.
#
# The raw `forge inspect ... storageLayout --json` output embeds compiler-internal
# AST identifiers (`astId` on every storage/type entry, plus numeric suffixes on
# `t_struct(...)NNN_storage` type keys/references). Those drift on every unrelated
# source edit and produce noise diffs that pressure reviewers to rubber-stamp
# snapshot refreshes — at which point a *real* slot shift could slip through. We
# canonicalise the JSON before snapshotting and comparing so only load-bearing
# fields (slot, offset, label, type modulo astId) drive the diff.
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

# Strip compiler-internal AST identifiers so the snapshot only changes when the
# load-bearing storage layout (slot/offset/label/type) changes.
normalize() {
  jq '
    def strip_struct_id: gsub("t_struct\\((?<n>[^)]+)\\)[0-9]+_storage"; "t_struct(\(.n))_storage");
    walk(if type == "object" then del(.astId) else . end)
    | .storage |= map(.type |= strip_struct_id)
    | .types |= (
        with_entries(.key |= strip_struct_id)
        | map_values(
            if has("members") then .members |= map(.type |= strip_struct_id) else . end
          )
      )
  '
}

failed=0
for name in "${CONTRACTS[@]}"; do
  current="$(forge inspect "$name" storageLayout --json | normalize)"
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
