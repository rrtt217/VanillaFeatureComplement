-- tests/village_villagers_test.lua
-- Offline test suite for village_villagers.lua.
--
-- The module decides where to put villagers from three inputs: whether the locator confirms a
-- village at this chunk's origin, how many villagers are already nearby, and which blocks in
-- the chunk are walkable village floors. All three are mocked here, so the tests are about the
-- module's own policy - the deficit, the spread, the guards - rather than about the engine.
--
-- Usage (from the plugin folder):
--     lua    tests/village_villagers_test.lua
--     luajit tests/village_villagers_test.lua
--
-- Exit code 0 when every check passed, 1 otherwise.

-- ===========================================================================
-- 1. Harness
-- ===========================================================================

local Passed, Failed, Failures = 0, 0, {}

local function Check(Name, Ok, Detail)
	if Ok then
		Passed = Passed + 1
	else
		Failed = Failed + 1
		Failures[#Failures + 1] = Name .. (Detail and ("  [" .. tostring(Detail) .. "]") or "")
	end
end

local function Section(Title)
	print("")
	print("== " .. Title .. " ==")
end


-- ===========================================================================
-- 2. Engine stubs, defined before the module is loaded because it reads the
--    E_BLOCK_* constants at load time to build its floor table.
-- ===========================================================================

E_BLOCK_AIR          = 0
E_BLOCK_STONE        = 1
E_BLOCK_GRASS        = 2
E_BLOCK_DIRT         = 3
E_BLOCK_COBBLESTONE  = 4
E_BLOCK_PLANKS       = 5
E_BLOCK_GRAVEL       = 13
E_BLOCK_LOG          = 17
E_BLOCK_SANDSTONE    = 24
E_BLOCK_STONE_BRICKS = 98
E_BLOCK_HAY_BALE     = 170
mtVillager = 59

Vector3d = function(X, Y, Z) return { x = X, y = Y, z = Z } end
Vector3i = function(X, Y, Z) return { x = X, y = Y, z = Z } end
cBoundingBox = function(P1, P2)
	return { MinX = math.min(P1.x, P2.x), MaxX = math.max(P1.x, P2.x),
		MinZ = math.min(P1.z, P2.z), MaxZ = math.max(P1.z, P2.z) }
end

---The module casts each entity to cMonster before asking for its type, so the stub has to
---survive that cast and still answer GetMobType.
tolua = { cast = function(Entity) return Entity end }

---A Spy world: blocks from a table keyed "x,y,z", spawns and entities recorded.
local WorldsByName = {}
cRoot = { Get = function() return { GetWorld = function(_, Name) return WorldsByName[Name] end } end }

local function MakeWorld(a_Name)
	local W = {
		Name = a_Name,
		Blocks = {},
		Spawned = {},
		Entities = {},
		GetBlockCalls = 0,
	}
	function W:GetName() return self.Name end
	---Chunks listed here answer -1, which is what the engine reports for a chunk that is not
	---in the world. Everything else is loaded.
	function W:GetBiomeAt(X, Z)
		if self.UnloadedChunks and self.UnloadedChunks[(math.floor(X / 16) .. "," .. math.floor(Z / 16))] then
			return -1
		end
		return 1
	end
	function W:GetBlock(Pos)
		self.GetBlockCalls = self.GetBlockCalls + 1
		return self.Blocks[Pos.x .. "," .. Pos.y .. "," .. Pos.z] or E_BLOCK_AIR
	end
	function W:SpawnMob(X, Y, Z, Type)
		self.Spawned[#self.Spawned + 1] = { X = X, Y = Y, Z = Z, Type = Type }
		return #self.Spawned
	end
	function W:ForEachEntityInBox(Box, Callback)
		for _, E in ipairs(self.Entities) do
			if (E.x >= Box.MinX) and (E.x <= Box.MaxX) and (E.z >= Box.MinZ) and (E.z <= Box.MaxZ) then
				Callback(E)
			end
		end
		return true
	end
	WorldsByName[a_Name] = W
	return W
end

---Puts a walkable plank floor with two air above at every column of a chunk, at a given y.
local function FillFloor(World, ChunkX, ChunkZ, Y)
	for x = 0, 15 do
		for z = 0, 15 do
			local BX, BZ = ChunkX * 16 + x, ChunkZ * 16 + z
			World.Blocks[BX .. "," .. Y .. "," .. BZ] = E_BLOCK_PLANKS
			World.Blocks[BX .. "," .. (Y + 1) .. "," .. BZ] = E_BLOCK_AIR
			World.Blocks[BX .. "," .. (Y + 2) .. "," .. BZ] = E_BLOCK_AIR
		end
	end
end


-- ===========================================================================
-- 3. StructureLocate stub
-- ===========================================================================

---What the locator should report for the next call.
local LocateResult = nil
local LocateCalls = 0
local CandidateCalls = 0
local HasVillages = true

StructureLocate =
{
	Kinds = { Village = { Display = "村庄" } },
	GetConfig = function(World, Kind)
		if not HasVillages then
			return nil, "此世界不生成村庄"
		end
		return { Seed = 1 }
	end,
	Locate = function(World, KindName, X, Z, RadiusChunks)
		LocateCalls = LocateCalls + 1
		return LocateResult
	end,
	---The cheap pre-filter the chunk hook uses. One candidate, whose origin is the village
	---the tests place at (160, 32).
	GetCandidates = function(Cfg, MinX, MaxX, MinZ, MaxZ)
		CandidateCalls = CandidateCalls + 1
		return { { CellX = 0, CellZ = 0, OriginX = 160, OriginZ = 32 } }
	end,
}

dofile("village_villagers.lua")

---A confirmed village whose origin sits inside the given chunk.
local function ConfirmedVillage(OriginX, OriginZ)
	return { X = OriginX, Y = 64, Z = OriginZ, Distance = 0, Confirmed = true,
		OriginX = OriginX, OriginZ = OriginZ, Kind = StructureLocate.Kinds.Village }
end

---Runs both phases the way the engine would: the chunk hook queues, the tick hook does the
---work. The split is the point of the design, so tests drive it explicitly.
local function Run(World, ChunkX, ChunkZ)
	VillageVillagers.OnChunkAvailable(World, ChunkX, ChunkZ)
	return VillageVillagers.OnWorldTick(World, 0.05)
end

local function Reset(a_LocateResult)
	LocateResult = a_LocateResult
	LocateCalls = 0
	HasVillages = true
	VillageVillagers.Enabled = true
	VillageVillagers.PerVillage = 6
	VillageVillagers.OriginsPerTick = 2
	CandidateCalls = 0
	VillageVillagers.ClearQueue()
	-- The module remembers handled origins per session; that cache is module-local, so a
	-- fresh world name is how a test gets a clean slate.
end

local WorldNr = 0
local function FreshWorld()
	WorldNr = WorldNr + 1
	return MakeWorld("w" .. WorldNr)
end


-- ===========================================================================
-- 4. A. Guards
-- ===========================================================================

Section("A. guards")

Reset(ConfirmedVillage(160, 32))
local W1 = FreshWorld()
FillFloor(W1, 10, 2, 64)
Check("returns false, never true", Run(W1, 10, 2) == false)
Check("a confirmed village is populated", #W1.Spawned == 6, #W1.Spawned)
Check("the spawn type is a villager",
	(#W1.Spawned > 0) and (W1.Spawned[1].Type == mtVillager))
Check("spawns land on the floor block, not in it",
	(#W1.Spawned > 0) and (W1.Spawned[1].Y == 65), W1.Spawned[1] and W1.Spawned[1].Y)
Check("spawns are centred in the block",
	(#W1.Spawned > 0) and (W1.Spawned[1].X % 1 == 0.5) and (W1.Spawned[1].Z % 1 == 0.5))

Reset(ConfirmedVillage(160, 32))
local W2 = FreshWorld()
FillFloor(W2, 10, 2, 64)
VillageVillagers.Enabled = false
Run(W2, 10, 2)
Check("nothing happens while disabled", #W2.Spawned == 0, #W2.Spawned)
Check("the locator is not even asked while disabled", LocateCalls == 0, LocateCalls)
VillageVillagers.Enabled = true

Reset(nil)
local W3 = FreshWorld()
FillFloor(W3, 10, 2, 64)
Run(W3, 10, 2)
Check("no village here means no villagers", #W3.Spawned == 0, #W3.Spawned)

Reset({ X = 160, Y = 64, Z = 32, Distance = 0, Confirmed = false,
	OriginX = 160, OriginZ = 32, Kind = StructureLocate.Kinds.Village })
local W4 = FreshWorld()
FillFloor(W4, 10, 2, 64)
Run(W4, 10, 2)
Check("an unconfirmed village is not populated", #W4.Spawned == 0, #W4.Spawned)

Reset(ConfirmedVillage(160, 32))
HasVillages = false
local W5 = FreshWorld()
FillFloor(W5, 10, 2, 64)
Run(W5, 10, 2)
Check("a world that generates no villages is skipped", #W5.Spawned == 0, #W5.Spawned)
Check("and the locator is not asked there either", LocateCalls == 0, LocateCalls)


-- ===========================================================================
-- 5. B. Population target
-- ===========================================================================

Section("B. population target")

Reset(ConfirmedVillage(160, 32))
local W6 = FreshWorld()
FillFloor(W6, 10, 2, 64)
for i = 1, 6 do
	W6.Entities[#W6.Entities + 1] = { x = 160 + i, z = 32 + i, mobType = mtVillager,
		GetMobType = function(self) return self.mobType end }
end
Run(W6, 10, 2)
Check("a village already at its target is left alone", #W6.Spawned == 0, #W6.Spawned)

Reset(ConfirmedVillage(160, 32))
local W7 = FreshWorld()
FillFloor(W7, 10, 2, 64)
for i = 1, 4 do
	W7.Entities[#W7.Entities + 1] = { x = 160 + i, z = 32 + i, mobType = mtVillager,
		GetMobType = function(self) return self.mobType end }
end
Run(W7, 10, 2)
Check("only the deficit is spawned", #W7.Spawned == 2, #W7.Spawned)

Reset(ConfirmedVillage(160, 32))
local W8 = FreshWorld()
FillFloor(W8, 10, 2, 64)
W8.Entities[1] = { x = 160, z = 32, mobType = 42, GetMobType = function(self) return self.mobType end }
for i = 1, 5 do
	W8.Entities[#W8.Entities + 1] = { x = 160 + i, z = 32 + i, mobType = mtVillager,
		GetMobType = function(self) return self.mobType end }
end
Run(W8, 10, 2)
Check("entities that are not villagers do not count", #W8.Spawned == 1, #W8.Spawned)

Reset(ConfirmedVillage(160, 32))
local W9 = FreshWorld()
FillFloor(W9, 10, 2, 64)
VillageVillagers.PerVillage = 2
Run(W9, 10, 2)
Check("PerVillage is honoured", #W9.Spawned == 2, #W9.Spawned)


-- ===========================================================================
-- 6. C. Once per village
-- ===========================================================================

Section("C. once per village")

Reset(ConfirmedVillage(160, 32))
local W10 = FreshWorld()
FillFloor(W10, 10, 2, 64)
Run(W10, 10, 2)
local First = #W10.Spawned
Run(W10, 10, 3)
Check("a second chunk of the same village does not spawn again",
	#W10.Spawned == First, First .. " -> " .. #W10.Spawned)
-- The chunk hook's cheap pre-filter already rejected chunk (10, 3), because the origin it
-- knows about is not inside it, so the locator was never asked about it.
Check("a chunk that cannot hold the origin is not even queued", LocateCalls == 1, LocateCalls)

Reset(ConfirmedVillage(160, 32))
local W11 = FreshWorld()
FillFloor(W11, 10, 2, 64)
Run(W11, 10, 2)
Check("a different world gets its own decision", #W11.Spawned == 6, #W11.Spawned)


-- ===========================================================================
-- 6b. E. The two phases
-- ===========================================================================

Section("E. the two phases")

Reset(ConfirmedVillage(160, 32))
local WS = FreshWorld()
FillFloor(WS, 10, 2, 64)
VillageVillagers.OnChunkAvailable(WS, 10, 2)
Check("the chunk hook only queues", #WS.Spawned == 0, #WS.Spawned)
Check("the origin is pending", VillageVillagers.PendingCount() == 1, VillageVillagers.PendingCount())
Check("the locator is not asked from the chunk hook", LocateCalls == 0, LocateCalls)
Check("the cheap pre-filter was used instead", CandidateCalls >= 1, CandidateCalls)
VillageVillagers.OnWorldTick(WS, 0.05)
Check("the tick hook then does the work", #WS.Spawned == 6, #WS.Spawned)
Check("and drains the queue", VillageVillagers.PendingCount() == 0, VillageVillagers.PendingCount())

Reset(ConfirmedVillage(160, 32))
local WZ = FreshWorld()
FillFloor(WZ, 10, 2, 64)
VillageVillagers.OriginsPerTick = 0
VillageVillagers.OnChunkAvailable(WZ, 10, 2)
VillageVillagers.OnWorldTick(WZ, 0.05)
Check("a zero budget defers the work", #WZ.Spawned == 0, #WZ.Spawned)
Check("and keeps it queued", VillageVillagers.PendingCount() == 1, VillageVillagers.PendingCount())

-- The origin chunk must still be loaded when the tick hook gets to it, otherwise the work is
-- dropped and can be retried later rather than being marked done.
Reset(ConfirmedVillage(160, 32))
local WL = FreshWorld()
FillFloor(WL, 10, 2, 64)
WL.UnloadedChunks = { ["10,2"] = true }
VillageVillagers.OnChunkAvailable(WL, 10, 2)
VillageVillagers.OnWorldTick(WL, 0.05)
Check("nothing is spawned once the chunk is gone", #WL.Spawned == 0, #WL.Spawned)
WL.UnloadedChunks = nil
VillageVillagers.OnChunkAvailable(WL, 10, 2)
VillageVillagers.OnWorldTick(WL, 0.05)
Check("and it is retried once the chunk is back", #WL.Spawned == 6, #WL.Spawned)

-- Never spawn into a chunk that is not loaded: a mob detached from a chunk still ticks, and
-- when it is destroyed the engine's VERIFY(RemoveEntity) aborts the whole server.
Reset(ConfirmedVillage(160, 32))
local WU = FreshWorld()
FillFloor(WU, 11, 2, 64)
WU.UnloadedChunks = { ["11,2"] = true }
VillageVillagers.OnChunkAvailable(WU, 10, 2)
VillageVillagers.OnWorldTick(WU, 0.05)
Check("a floor in an unloaded chunk is not used", #WU.Spawned == 0, #WU.Spawned)
-- Having been looked at, the origin is considered done: a village whose origin chunk has no
-- walkable floor and whose neighbours are not loaded is simply left unpopulated rather than
-- retried forever. That is a deliberate, bounded limitation.
WU.UnloadedChunks = nil
VillageVillagers.OnChunkAvailable(WU, 10, 2)
VillageVillagers.OnWorldTick(WU, 0.05)
Check("the origin is only looked at once", #WU.Spawned == 0, #WU.Spawned)

-- The confirmation has to be about the origin that was queued, not some other village.
Reset({ X = 9999, Y = 64, Z = 9999, Distance = 0, Confirmed = true,
	OriginX = 9999, OriginZ = 9999, Kind = StructureLocate.Kinds.Village })
local WM = FreshWorld()
FillFloor(WM, 10, 2, 64)
VillageVillagers.OnChunkAvailable(WM, 10, 2)
VillageVillagers.OnWorldTick(WM, 0.05)
Check("a confirmation for a different origin is not accepted", #WM.Spawned == 0, #WM.Spawned)


-- ===========================================================================
-- 7. D. Where they stand
-- ===========================================================================

Section("D. where they stand")

Reset(ConfirmedVillage(160, 32))
local W12 = FreshWorld()
-- Dirt is not a village floor: villagers must not end up on the surrounding terrain.
for x = 0, 15 do
	for z = 0, 15 do
		W12.Blocks[(160 + x) .. ",64," .. (32 + z)] = E_BLOCK_DIRT
	end
end
Run(W12, 10, 2)
Check("terrain is not a village floor", #W12.Spawned == 0, #W12.Spawned)

Reset(ConfirmedVillage(160, 32))
local W13 = FreshWorld()
for x = 0, 15 do
	for z = 0, 15 do
		-- A plank floor with only one air block above it: too low for a villager.
		W13.Blocks[(160 + x) .. ",64," .. (32 + z)] = E_BLOCK_PLANKS
		W13.Blocks[(160 + x) .. ",65," .. (32 + z)] = E_BLOCK_AIR
		W13.Blocks[(160 + x) .. ",66," .. (32 + z)] = E_BLOCK_STONE
	end
end
Run(W13, 10, 2)
Check("a ceiling one block up is not standing room", #W13.Spawned == 0, #W13.Spawned)

Reset(ConfirmedVillage(160, 32))
local W14 = FreshWorld()
FillFloor(W14, 10, 2, 64)
Run(W14, 10, 2)
local Distinct = {}
for _, S in ipairs(W14.Spawned) do
	Distinct[S.X .. "," .. S.Z] = true
end
local DistinctCount = 0
for _ in pairs(Distinct) do DistinctCount = DistinctCount + 1 end
Check("each villager gets its own column", DistinctCount == #W14.Spawned, DistinctCount)
-- A chunk is only 16 wide, so the spread has to be judged on whichever axis the picks
-- actually vary along rather than on X alone.
local MinX, MaxX, MinZ, MaxZ = 9999, -9999, 9999, -9999
for _, S in ipairs(W14.Spawned) do
	if (S.X < MinX) then MinX = S.X end
	if (S.X > MaxX) then MaxX = S.X end
	if (S.Z < MinZ) then MinZ = S.Z end
	if (S.Z > MaxZ) then MaxZ = S.Z end
end
Check("the batch is spread across the chunk, not piled up",
	math.max(MaxX - MinX, MaxZ - MinZ) >= 10,
	MinX .. ".." .. MaxX .. " / " .. MinZ .. ".." .. MaxZ)

Reset(ConfirmedVillage(160, 32))
local W15 = FreshWorld()
-- Only the neighbouring chunk has a usable floor, so the scan has to move on to it.
FillFloor(W15, 11, 2, 64)
Run(W15, 10, 2)
Check("a neighbouring chunk is scanned when the origin chunk is bare",
	#W15.Spawned == 6, #W15.Spawned)
local AllInNeighbour = true
for _, S in ipairs(W15.Spawned) do
	if (S.X < 176) then AllInNeighbour = false end
end
Check("and the spawns are in that neighbour", AllInNeighbour)


-- ===========================================================================
-- 8. Summary
-- ===========================================================================

print("")
print(string.format("village_villagers_test: %d passed, %d failed", Passed, Failed))
if (Failed > 0) then
	print("")
	print("Failures:")
	for _, F in ipairs(Failures) do
		print("  - " .. F)
	end
end
os.exit(Failed == 0 and 0 or 1)
