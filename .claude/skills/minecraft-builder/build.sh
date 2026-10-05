#!/usr/bin/env bash
# Usage: build.sh <file.schem> [x y z] [world]
#   Uploads the schematic to the Minecraft pod and, when coordinates are given, pastes it there.
#   Pastes with the schematic's own origin at x,y,z (the (0,0,0) corner you built it with).
set -euo pipefail

file=${1:?usage: build.sh <file.schem> [x y z] [world]}
name=$(basename "$file")
ns=minecraft
dep=deploy/minecraft-app-deployment
rcon() { kubectl -n "$ns" exec "$dep" -- rcon-cli "$@" | sed 's/\x1b\[[0-9;]*m//g'; }

pod=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=minecraft --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$ns" cp "$file" "$pod:/data/plugins/WorldEdit/schematics/$name" -c app
echo "uploaded $name"

if [[ $# -ge 4 ]]; then
  world=${5:-world}
  rcon "//world $world"
  rcon "//schem load $name"
  rcon "//pos1 $2,$3,$4"
  rcon "//paste ${PASTE_FLAGS:--a}"   # -a skips air so water/terrain inside the bounding box survives; PASTE_FLAGS="" to clear it
fi
