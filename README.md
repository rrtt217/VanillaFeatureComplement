# VanillaFeatureComplement
A Cuberite Plugin that adds some Vanilla feature that is missing in Cuberite.
Currently includes:
- Map zoomout and clone on crafting table
    - Zooming out keeps the picture the map already has (copied at half resolution, centred) instead of wiping it
    - Limitation: the zoomed map reuses the original map number, so every copy of that map zooms together. Vanilla hands out a new map id, which needs cMapManager::CreateMap -- not exposed to Lua by upstream; the plugin uses it automatically on a server that binds it
- Elytra powered flight by firework
    - Uses the rocket's real flight time, read out of its undocumented `cFireworkItem` payload
      (see `firework_item.lua`); falls back to a random 20-60 ticks only when the payload is unreadable
    - No damage on firework star explosion
    - Limitation: a rocket carrying no firework colours is still rejected by the engine, so it uses
      the speed-push fallback; another firework item's payload can be copied onto it with
      `FireworkItem.Copy()`
- Shield support
    - Raises main- or offhand shield when right-click does not consume the main hand item
    - Blocks melee, ranged, and explosion damage from the front
    - Deflects projectiles (Cuberite reports no damage for those, so they do not wear the shield)
    - Plays the vanilla shield block sound on every block
    - Wears the shield down like vanilla: hits of 3+ damage cost 1 + floor(damage) durability, reduced by Unbreaking, and nothing is worn in creative
    - Durability is stored in the shield's unused damage field (`m_ItemDamage`): `cItem::GetMaxDamage()`
      has no shield case, so the engine never reads or writes that field for a shield, and the client draws
      its own durability bar from it. Shields saved with the older lore-based counter are migrated to the
      damage field on their next hit
    - Limitation: offhand shield raising uses heuristics, so rare interaction patterns may still mis-detect shield use
- End platform generation
- Sleep clears weather
- Player death XP and off-hand drop fix
    - Players drop experience orbs worth min(7 × level, 100) on death, regardless of cause
    - The off-hand (shield) slot item is dropped on death (Cuberite clears it without dropping)

## Settings

`settings.ini` has one toggle per feature under `[Features]`. Verbose per-event
diagnostics (item / shield / damage traces, elytra fallback notices) are off by
default, because they fire on every right-click and every damage event; enable
them only while debugging:

```ini
[Debug]
EnableDebugLog=1
```

## Reading `cItem.m_FireworkItem`

`firework_item.lua` exposes Cuberite's undocumented `cFireworkItem` payload through
`tolua.cast()` type punning. On this build it can read `Type` and `FlightTimeInTicks`,
count the entries of both colour lists, and copy the whole payload (colours included)
between items — the only way to give a rocket the colours the engine demands. Colour
*values* are not reachable. Every cast is guarded, because `tolua.cast()` to an
unregistered type name SIGSEGVs the server.

Full method, evidence and hazards: [docs/m_FireworkItem-research.md](docs/m_FireworkItem-research.md).

## Tests

The shield state machine ships with an offline robustness suite. It mocks the Cuberite API
and drives every itemtype the engine can put in a hand through the use / release / damage
hooks, checking both that no handler ever raises a Lua error and that the offhand shield
raises exactly when the right-click was not consumed by the main-hand item:

```sh
lua    tests/shield_test.lua      # Lua 5.4
luajit tests/shield_test.lua      # Lua 5.1 (the version Cuberite embeds)
```

It exits 0 only when every check passes.