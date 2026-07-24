# VanillaFeatureComplement
A Cuberite Plugin that adds some Vanilla feature that is missing in Cuberite.
Currently includes:
- Map zoomout and clone on crafting table
    - Zooming out map doesn't create a new map number; instead overwriting the original one
- Elytra powered flight by firework
    - random time if no firework star; no damage on firework star explosion
- Shield support
    - Raises main- or offhand shield when right-click does not consume the main hand item
    - Blocks melee, ranged, and explosion damage from the front
    - Deflects projectiles and applies simulated shield durability loss
    - Limitation: offhand shield raising uses per-tick batched USING_ITEM events and heuristics, so certain clients or rare interaction patterns may still mis-detect shield use (currently only support viaforge/viafabricplus, not vanilla); durability is emulated because Cuberite has no native shield durability support
- End platform generation
- Sleep clears weather