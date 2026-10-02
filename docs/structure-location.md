# Finding structures from a plugin

## /locate

`structure_locate.lua` answers `/locate <StructureType>` in the style of the pre-1.16
Java command, which is the one that matches this server's 1.12.2 protocol: no
`structure` sub-keyword, case-sensitive type names, type and nothing else -- no
coordinates and no radius, the search starts at the executor's position -- and a reply of
the nearest structure's coordinates plus the distance. The search covers the same area
Java's does -- a 201 x 201 chunk square centred on the executor's chunk -- and the
coordinates are a clickable part that puts the teleport command into the chat box
(rather than running it outright), which is what Java does as well. Cuberite's
self-teleport is `/tp <x> <y> <z>` where Java uses `/teleport @s <x> <y> <z>`.

A type the world does not generate
fails with a reason (`Fortress` in the overworld, for instance); a type whose biome test
cannot be run yet is still reported, but marked as a candidate.

The console command is a separate entry point, because a console has no position to start
from; there it is `locate <StructureType> <x> <z> [radius] [world]`.

## Cross-plugin API

Plugins do not share a Lua state: `cPluginLua` owns its own `cLuaState`, so another plugin
cannot reach `StructureLocate` directly. The only channel is
`cPluginManager:CallPlugin(PluginName, FunctionName, ...)`, which resolves the function with
`lua_getglobal` -- a plain global name, no dotted path. The exported entry points are
therefore top-level globals carrying the plugin name, not fields of a table.

```lua
local R = cPluginManager:CallPlugin("VanillaFeatureComplement", "StructureLocateFindNearest",
    World, "Mineshaft", X, Z)
if (R == nil) then
    -- the plugin, or the function, is not loaded
elseif (R.Ok) then
    -- R.Kind, R.Display, R.X, R.Y, R.Z, R.Distance, R.Confirmed, R.OriginX, R.OriginZ
else
    -- R.Error: unknown type, not generated in this world, or nothing in the window
end
```

| global | returns |
|---|---|
| `StructureLocateFindNearest(World, KindName, X, Z [, RadiusChunks [, Biomes]])` | one table, `{Ok = true, ...}` or `{Ok = false, Error = ...}` |
| `StructureLocateFindAll(World, KindName, MinX, MinZ, MaxX, MaxZ [, RefX, RefZ [, Biomes]])` | one table with `Count`, `ConfirmedCount` and `Items` |
| `StructureLocateKinds()` | a sorted array of the type names |
| `StructureLocateAPIVersion()` | `3` |

`FindNearest` searches Java's chunk window. `FindAll` takes an explicit inclusive block
rectangle instead and returns everything inside it, sorted by distance from `(RefX, RefZ)`
(the rectangle's centre when omitted). An oversized rectangle is refused rather than
walked, because every grid cell costs two emulated-32-bit noise lookups: the cap is
`MAX_CELLS`, about a 14k x 14k block region for a village grid.

### Confirming with the caller's own biomes

`GetBiomeAt` only answers for chunks the server has loaded, so a far-away village or
desert pyramid comes back as a candidate with `Confirmed = false` and no way for the
plugin to do better on its own. A caller that keeps its own biome cache can close that gap
by passing `Biomes`: a table keyed `"blockX,blockZ"` (floored, no spaces) whose values
are biome ids. The plugin consults it only where the engine returned -1.

The engine's own answer always wins, so a wrong or stale table can only be ignored, never
believed - a caller cannot talk the plugin into a village on a chunk the server has
actually generated as ocean. Both forms take it; for `FindAll` it is the ninth
argument, so `nil` has to be passed for `RefX` and `RefZ` if only the biomes matter:

```lua
local R = cPluginManager:CallPlugin("VanillaFeatureComplement", "StructureLocateFindAll",
    World, "Village", MinX, MinZ, MaxX, MaxZ, nil, nil, MyBiomeCache)
-- R.Count villages in range, R.ConfirmedCount of them vouched for
```

A function cannot be passed instead of the table - see the measurement below - which is
why this is a table of values rather than a callback the plugin calls back into.

The shape is deliberate, and the limits were measured rather than assumed. A probe was
exported that echoed back what actually arrived:

| argument | crosses the boundary? |
|---|---|
| numbers, strings, bools, nil | yes, exactly, and nils are counted |
| tables, numeric or string keys, nested | yes, copied recursively; 256 entries arrived intact |
| a `cWorld` | yes, as a class |
| a function | **no** -- and neither does any table that contains one |

The engine says so itself: `CopySingleValueFrom: Unsupported value: 'function' at stack
position 4. Can only copy numbers, strings, bools, classes and simple tables!` followed
by `Failed to copy table in pos 4`. A rejected argument makes the whole call return
**no values at all**, which is exactly why the "always one table" contract matters:
`nil` means the call did not land, never that the answer was empty. The other way to get
`nil` is a name that is not a function at all: the engine logs
`Function '<name>' not found` and returns nothing either. A plugin that answers a refusal
does *not* do that -- it returns a table with `Ok = false` -- which is how a caller tells
"the feature is missing" from "the answer is no".

Every structure Cuberite places on a grid is a `cGridStructGen` descendant and shares the
same cell/origin maths, so one locator covers them all:

| type | source | eligibility | position |
|---|---|---|---|
| `Mineshaft` | `MineShafts*` in world.ini | none - always generated | the dirt room, not the grid origin |
| `Village` | `Village*` in world.ini | all 256 biomes of the origin chunk | the grid origin |
| `Desert_Pyramid`, `Jungle_Pyramid`, `Swamp_Hut`, `Desert_Well` | the cubeset metadata | the single biome at the origin | the grid origin |
| `Fortress` | the NetherFort cubeset metadata | the single biome at the origin | the grid origin |

The cubeset-sourced kinds also apply a `SeedOffset`, which the world.ini-sourced ones
never do.


## The problem

Cuberite exposes nothing about generated structures. `cChunkDesc` has no structure list,
the chunk hooks carry only `(World, ChunkX, ChunkZ, ChunkDesc)`, and the whole structure
machinery -- `cPrefab`, `cPiece`, `cPiecePool`, `cPieceGenerator` -- is outside the tolua
parse set: `src/Bindings/AllToLua.pkg` takes exactly one header from `Generating/`, and it
is `ChunkDesc.h`. `cPrefab` has zero `tolua_begin`/`tolua_export` markers and zero
`tolua_AllToLua_*Prefab*` symbols in the binary, against 48 for `cBlockArea`.

What the engine *does* have is a fully deterministic placement algorithm, and that is what
`structure_locate.lua` reimplements.

## The algorithm

**Cell placement** -- `cGridStructGen`, `Generating/GridStructGen.cpp`, `GetStructuresForChunk()`:

    MinBlockX = MinX - MaxStructureSize - MaxOffset
    MaxBlockX = MaxX + MaxStructureSize + MaxOffset
    MinGridX  = MinBlockX / GridSizeX            // C integer division
    MaxGridX  = (MaxBlockX + GridSizeX - 1) / GridSizeX
    for (x = MinGridX; x < MaxGridX; x++) { GridX = x * GridSizeX; ... }

    OriginX = GridX + (IntNoise2DInt(GridX + 3, GridZ + 5) / 7) % (2 * MaxOffsetX) - MaxOffsetX
    OriginZ = GridZ + (IntNoise2DInt(GridX + 5, GridZ + 3) / 7) % (2 * MaxOffsetZ) - MaxOffsetZ

`GridX` / `GridZ` are cell *points* (multiples of `GridSize`), not cell indices. `MinBlockX`
is negative for negative coordinates, so the division must truncate towards zero, not floor;
`DivC()` in the module does that.

For villages `GridSize = VillageGridSize` (384), `MaxOffset = VillageMaxOffset` (128) and
`MaxStructureSize = VillageMaxSize` (128), all read from `[Generator]` of the world's
`world.ini` (`cWorld:GetIniFileName()`).

**Seed** -- `cChunkGenerator::CreateFromIniFile()` sets the generator seed from `[Seed] Seed`,
which is what `cWorld:GetSeed()` returns. Villages never apply a cubeset `SeedOffset`:
`cGridStructGen::SetGeneratorParams()`, the only place that adds it, is called by the
SinglePieceStructures and PieceStructures generators only.

**Village or not** -- `cVillageGen::CreateStructure()`, `Generating/VillageGen.cpp`:

    Biomes = biome generator's 16x16 map for the chunk containing the origin
    Available = pools for which EVERY one of the 256 biome columns is in AllowedBiomes
    if Available is empty -> no village here
    rnd  = cNoise(seed + 1000).IntNoise2DInt(OriginX, OriginZ) / 11
    pool = Available[rnd % #Available]

`AllowedBiomes` is a cubeset metadata string (`Prefabs/Villages/<Name>.cubeset`); the module
reads it with a pattern rather than executing the file, so world data is never run as code.
A pool without the field accepts nothing, which is what `cVillagePiecePool` does.

`IntNoise2DInt` is `inline` in `src/Noise/Noise.h` and is not bound, so it is ported. The
wraparound is the hard part: Lua 5.1 has only doubles and `n * n * 15731` overflows the
53-bit exact-integer range, so the multiply is split into 16-bit halves (`Mul32`) and the
XOR is bit-banged (`BXor32`).

## Two engine traps

**`cChunkDesc:GetBiome()` is meaningless in `HOOK_CHUNK_GENERATING`.** The biome map is
`memset(..., 0)` in the constructor (`Generating/ChunkDesc.cpp`) and only filled by
`cComposableGenerator::Generate()` -- which runs *after* that hook
(`ChunkGeneratorThread.cpp`: the hook at one line, `Generate` on the next). Reading it there
returns `0 = biOcean` for every column, a valid biome id, so the answer is silently wrong
rather than an error. Measured on a live chunk: `b00 = b88 = b1515 = 0` before generation,
`24` (= `biDeepOcean`) after.

**`cWorld:GetBiomeAt()` only answers for loaded chunks.** `cChunkMap::GetBiomeAt()` looks the
chunk up with `FindChunk()` and returns `biInvalidBiome` (`-1`) otherwise -- it does *not*
fall back to the generator, contrary to the APIDoc string. Measured: `spawn(0,0) = -1`,
`(1000000, 1000000) = -1`, while loaded chunks answer normally. A village origin is usually
outside the loaded area, so the pool cannot always be resolved; the module reports
"candidate" plus the reason instead of guessing.

`cChunkDesc` does have `GetBiome` / `SetBiome`, and they are the right tool for the *current*
chunk -- see above for when they are valid.

## Verification

*Offline.* `tests/structure_locate_test.lua` (108 checks) compares the port against an
independent Node implementation that uses native 32-bit arithmetic (`Math.imul`, `<<`, `^`,
`&`) -- 72 noise cases, 12 origin cases, 4 candidate enumerations, multiply/XOR tables and
pool-pick indices. The Lua emulation must agree with the native one, so this tests the port
rather than restating it.

*Live.* The four origins below were predicted by the module against the real server (world
seed 1402121502, grid 384, offset 128, size 128), then their chunk was generated with
`cWorld:ChunkStay` and scanned for village blocks (planks, cobblestone, doors, fences,
farmland, wheat, glass panes, bookshelves, crafting tables) in y 62..76:

| cell point | predicted origin | biome(s) | module | village blocks found |
|---|---|---|---|---|
| (-768, 0)      | (-694, 3)    | Plains (1)          | village PlainsVillage | **1295** |
| (-384, -1152)  | (-273, -1075)| Plains (1)          | village PlainsVillage | **698** (incl. farmland + wheat) |
| (768, 768)     | (806, 881)   | SunflowerPlains(129)| village PlainsVillage | **867** |
| (0, 0)         | (-72, -33)   | 131                 | no village            | **0** |

Perfect separation: every origin the module promotes to a village holds one, and the origin
it rejects holds none. The three village origins are also pinned as `LIVE_ORIGINS` in the
test suite.

## Limitations

- A **candidate** is exact geometry; the village **type** needs the biomes of the origin
  chunk, which the engine only reports once that chunk is loaded. Unloaded origins are
  reported as candidates with the reason, never guessed.
- `cVillageGen::CreateStructure` can return a village whose piece tree ends up empty, which
  draws nothing. The module cannot predict that; it needs the origin chunk's biomes.
- Gzipped cubesets (`<Name>.cubeset.gz`) are not supported -- `cFile` cannot decompress, so
  such a pool's `AllowedBiomes` is unknown and resolution reports an error rather than a
  wrong answer.
- The reported distance is to the origin; the village extends up to `VillageMaxSize` blocks
  further out in every direction.

## An unresolved observation

While scanning, `cBlockArea:Read()` returned `false` for boxes whose chunks were demonstrably
loaded -- `cWorld:GetBlock()` on the same coordinates returned real block ids, and
`cWorld:GetBiomeAt()` answered normally. The scans in this document therefore use
`cWorld:GetBlock()`. `cBlockArea:Read()` did succeed for some boxes and some chunks,
including a 44 x 26 x 42 one, so the condition is not obviously size or chunk-coverage; it
was not chased down because nothing in the module depends on it.

## Village chest contents

The same format limit that makes villages cheap also makes their chests useless: a
cubeset describes blocks only, so a chest arrives with no NBT and the engine
materialises it as an empty `cChestEntity`. Five of the shipped village cubesets do
place chests -- eight of them in total:

| cubeset | piece | chest position in the piece |
|---|---|---|
| **PlainsVillage** | Forge | (6, 2, 6) |
| **PlainsVillage** | WoodenGranary | (3, 2, 6) |
| **PlainsVillage** | WoodenChurchMid | (3, 6, 4) |
| **PlainsVillage** | WoodenMill5x5 | (2, 2, 6) |
| AlchemistVillage | BlackSmith | (1, 2, 9) |
| JapaneseVillage | HouseWithSakura1 | (6, 2, 5) |
| JapaneseVillage | Forge | (3, 2, 10) |
| SandFlatRoofVillage | Forge | (7, 2, 7) |

Only `PlainsVillage` and `SandVillage` are enabled by a default world, and
SandVillage has no container at all, so in practice only the four PlainsVillage chests
can appear.

`village_loot.lua` fills them at `HOOK_CHUNK_GENERATED`, which is the last moment the
chunk data can still be changed: the hook runs before `OnChunkGenerated()` moves
`ChunkDesc.GetBlockEntities()` into the chunk (`World.cpp`), so a block entity created
there is stored.

**Which chests are village chests.** Only the empty ones. The engine fills its own chests
during generation -- `MineShafts.cpp` and `DungeonRoomsFinisher.cpp` call
`cChunkDesc::GetBlockEntity()` and then
`cItemGrid::GenerateRandomLootWithBooks()` with 3..6 stacks -- so a chest that is still
empty when the hook runs is one a prefab placed. The handler never touches engine loot.

**Which table.** The chest's own neighbourhood decides, because the prefab is the only
thing that has been there:

| marker | within | table |
|---|---|---|
| hay bale or hopper | 2 blocks (|dy| <= 1) | Farm |
| furnace, lit or not | 8 blocks (|dy| <= 2) | Weaponsmith |
| nothing | -- | House |

The asymmetry is deliberate: WoodenGranary has hay bales against its chest and
WoodenMill5x5 has a hopper, but a forge's furnace is not always close --
JapaneseVillage/Forge keeps its chest 6 blocks from the nearest furnace, and
AlchemistVillage/BlackSmith has no furnace in the piece at all.

**The tables** are adapted from the reference
<https://zh.minecraft.wiki/w/箱子战利品（结构索引）>, which lists the modern (1.14+)
village tables. Cuberite is a 1.8-era server: in 1.8 only the blacksmith had a chest, so
Weaponsmith is that classic, version-stable table, while Farm and House have no 1.8
counterpart and are shaped after the modern `village_*_house` and farmer tables, reduced
to items this build has. They are plain data in `VillageLoot.Tables` and are meant to be
edited.

**Cost.** Running a Lua loop over 32k blocks for every generated chunk would add
milliseconds to each one, so the chest search happens in C: the chunk is copied into a
`cBlockArea` with `cChunkDesc:ReadBlockArea()` and counted with
`CountSpecificBlocks()`. A chunk no village box can reach is skipped before that with
plain arithmetic, and the per-chest work only runs in chunks that actually contain a chest.

### Verification

`tests/village_loot_test.lua` (36 checks) covers the roller (determinism, stack sizes
inside their ranges, weights respected), the classifier and the handler's central rule:
an empty chest is filled, an already-stocked chest is left exactly as it was.

Live, on freshly generated village chunks at the predicted origin `(-3363, -88)`:

    VITEMS chest (-3354,69,-108) furnacesNear=0 -> [emerald x1, bread x3, wheat x1, wheat x4]
    VITEMS chest (-3351,67,-62)  furnacesNear=0 -> [carrot x4, beetroot_seeds x4, seeds x4, bread x3, wheat x4]

Both chests hold four to five stacks drawn from the House table, which is what the
absence of a nearby furnace selects.

One landmine worth recording: `cChunkDesc:GetBlockEntity()` is declared as returning
`cBlockEntity`, and tolua resolves methods through the *declared* class -- which has no
`GetContents()`. The handler checks the block type and then `tolua.cast()`s to
`cBlockEntityWithItems`, which is where that method lives.

