---
name: minecraft-builder
description: Build structures in the cluster's Minecraft server (apps/minecraft, Paper + Geyser/Floodgate + WorldEdit) by generating .schem files with Python and pasting them over RCON. Use when the user asks to build, place, generate, paste or remove something in Minecraft, or to run server commands (give, tp, time, gamerule, fill) on it.
---

# minecraft-builder

## How it is wired

- App: `apps/minecraft` (namespace `minecraft`, Deployment `minecraft-app-deployment`, one pod, world + plugins on PVC `minecraft-data` at `/data`). Paper on Java 25, Geyser + Floodgate for Bedrock, WorldEdit installed via `MODRINTH_PROJECTS=worldedit`.
- Reachable on the tailnet only (`minecraft.beaver-cloud.ts.net`, Java 25565/TCP, Bedrock 19132/UDP). Nothing else is exposed; RCON is used only from inside the pod.
- RCON: `kubectl -n minecraft exec deploy/minecraft-app-deployment -- rcon-cli "<command>"`. Output is ANSI-coloured; strip it with `sed 's/\x1b\[[0-9;]*m//g'`.
- Schematics live in `/data/plugins/WorldEdit/schematics/` on the PVC (they survive restarts; they are not in git).

## Workflow for a build

1. **Ask where.** Get coordinates and world (default `world`; the nether is `world_nether`). To find a player: `rcon-cli "data get entity <name> Pos"` (Floodgate Bedrock names start with `.`). Check what is there first (a cheap look: `execute if block x y z air`), and never paste over something the user built without asking.
2. **Generate the schematic** in the scratchpad dir with `mcschematic` (`python3 -m venv v && v/bin/pip install mcschematic`):
   ```python
   import mcschematic
   s = mcschematic.MCSchematic()
   s.setBlock((x, y, z), "minecraft:stone_bricks")   # blockstates: "minecraft:oak_stairs[facing=north,half=bottom]"
   s.save(".", "castle", mcschematic.Version.JE_1_20_1)  # writes castle.schem; WorldEdit upgrades block data
   ```
   Build relative to (0,0,0); that corner is placed at the paste position. Use loops/helper functions for walls, floors, roofs, windows, and keep the schematic origin at ground level so it sits on the terrain.
3. **Upload + paste:** `.claude/skills/minecraft-builder/build.sh castle.schem X Y Z [world]`. Without coordinates it only uploads.
4. **Verify** from the `build.sh` output ("N blocks affected") and by asking the user to look. `rcon-cli "execute if block X Y Z <block>"` only works in loaded chunks (otherwise "That position is not loaded"), so use it when a player is nearby.
5. **Undo** if wanted: `rcon-cli "//undo"` (the console session keeps history across rcon calls until the pod restarts).

## Console WorldEdit gotchas (tested)

- The console has no position or selection, so set them explicitly: `//world world`, `//pos1 x,y,z`, then `//paste` (pastes at pos1). `//paste -o` pastes at the clipboard's original position instead, which is usually (0,0,0): do not use it.
- `//schem load` needs the extension: `//schem load castle.schem`. Right after uploading, a load without it fails with "Invalid value ... schematic filename".
- `execute ... run //paste` does not work; use the pos1 route.
- `say`/`tellraw` output is not returned through rcon; use `execute if block` (loaded chunks only) or `data get` to read state back.
- Pastes load chunks themselves, but very large pastes (>1M blocks) can stall the server; split them.
- Paste flags: `build.sh` pastes with `-a` by default. Without it every unset block in the schematic's bounding box is air and erases water/terrain there (bad for builds over water). Use `PASTE_FLAGS=""` to clear a site on purpose. `-e` includes entities.
- Finding a site: players' `Pos` via `data get entity`, then probe a grid in a `sh -c` loop inside the pod (`kubectl exec ... sh -c 'for ...; do rcon-cli "execute if block x y z minecraft:water"; done'`); one rcon-cli call per probe, never pass hundreds of args to one call.

## Handy server commands

```
rcon-cli "list"                                   # who is online
rcon-cli "tp <player> x y z"
rcon-cli "fill x1 y1 z1 x2 y2 z2 minecraft:air"   # clear (32768 block limit; use //set for more)
rcon-cli "//pos1 ..." ; "//pos2 ..." ; "//set stone"   # WorldEdit selection ops also work from console
rcon-cli "time set day" ; "gamerule doDaylightCycle false"
rcon-cli "save-all"                               # before risky large edits; a PVC snapshot is the real backup
```

## Changing the server itself

Edit `apps/minecraft/deployment.yml` (env vars such as `MODE`, `DIFFICULTY`, `MODRINTH_PROJECTS`, `PLUGINS`) and let Argo CD sync. Geyser's config is on the PVC (`/data/plugins/Geyser-Spigot/config.yml`); `auth-type` was set to `floodgate` by hand there.
