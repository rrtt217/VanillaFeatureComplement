-- tests/village_loot_test.lua
-- Offline test suite for the village chest contents of VanillaFeatureComplement.
--
-- Exercises the roller, the table classifier and the HOOK_CHUNK_GENERATED handler
-- against a mock Cuberite API. The point of the handler is that it must fill *only*
-- empty chests -- the engine's mineshaft and dungeon chests are already stocked when
-- the hook runs, and must not be touched.
--
-- Usage (from the plugin folder):
--     lua    tests/village_loot_test.lua
--     luajit tests/village_loot_test.lua      -- Lua 5.1 compat (Cuberite embeds 5.1)
--
-- Exit code 0 when every check passed, 1 otherwise.


-- ===========================================================================
-- 1. Engine nil, item and block constants (synthetic values, identity only)
-- ===========================================================================

local ITEM_NAMES =
{
	"E_ITEM_DIAMOND", "E_ITEM_IRON", "E_ITEM_GOLD", "E_ITEM_BREAD", "E_ITEM_RED_APPLE",
	"E_ITEM_IRON_SWORD", "E_ITEM_IRON_PICKAXE", "E_ITEM_IRON_HELMET", "E_ITEM_IRON_CHESTPLATE",
	"E_ITEM_IRON_LEGGINGS", "E_ITEM_IRON_BOOTS", "E_ITEM_SADDLE", "E_ITEM_IRON_HORSE_ARMOR",
	"E_ITEM_GOLDEN_APPLE", "E_ITEM_WHEAT", "E_ITEM_SEEDS", "E_ITEM_POTATO", "E_ITEM_CARROT",
	"E_ITEM_EMERALD", "E_ITEM_BEETROOT_SEEDS", "E_ITEM_BEETROOT", "E_ITEM_STICK", "E_ITEM_COAL",
	"E_ITEM_BOOK", "E_ITEM_STRING", "E_ITEM_IRON_HOE",
}
local Next = 300
for _, Name in ipairs(ITEM_NAMES) do
	_G[Name] = Next
	Next = Next + 1
end
E_BLOCK_SAPLING = 6
E_BLOCK_OBSIDIAN = 49
E_BLOCK_CHEST = 54
E_BLOCK_FURNACE = 61
E_BLOCK_LIT_FURNACE = 62
E_BLOCK_HOPPER = 154
E_BLOCK_HAY_BALE = 170

-- village_loot casts the block entity that cChunkDesc:GetBlockEntity returns to
-- cBlockEntityWithItems, because tolua resolves methods through the declared class.
-- The object is already the right one, so the cast is a no-op here.
tolua = { cast = function(a_Object) return a_Object end }


-- ===========================================================================
-- 2. Harness
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
-- 3. Module under test
-- ===========================================================================

-- Stub of the sibling module. village_loot only uses it to decide whether a chunk can
-- hold a village at all, so a controllable stub is enough here; the real placement
-- maths is covered by structure_locate_test.lua.
local StubCandidates = { { CellX = 0, CellZ = 0, OriginX = 0, OriginZ = 0 } }
StructureLocate =
{
	Kinds = { Village = { Display = "村庄" } },
	GetConfig = function(World) return World.Cfg end,
	GetCandidates = function() return StubCandidates end,
}

dofile("village_loot.lua")


-- ===========================================================================
-- 4. Mock chunk / block area / item grid
-- ===========================================================================

local function MakeGrid()
	local Slots = {}
	local Grid
	Grid =
	{
		Slots = Slots,
		GetNumSlots = function() return 27 end,
		IsSlotEmpty = function(_, SlotNum) return Slots[SlotNum] == nil end,
		SetSlot = function(_, SlotNum, ItemType, ItemCount, ItemDamage)
			Slots[SlotNum] = { ItemType, ItemCount, ItemDamage or 0 }
		end,
	}
	return Grid
end

cBlockArea = function()
	local A
	A =
	{
		Populate = function() return 0 end,
		CountSpecificBlocks = function(_, BlockType)
			local Count = 0
			for X = 0, 15 do
				for Y = 0, 127 do
					for Z = 0, 15 do
						if (A.Populate(X, Y, Z) == BlockType) then
							Count = Count + 1
						end
					end
				end
			end
			return Count
		end,
		GetRelBlockType = function(_, X, Y, Z) return A.Populate(X, Y, Z) end,
	}
	return A
end

local function MakeChunkDesc()
	local Blocks, Entities = {}, {}
	local Self
	Self =
	{
		Blocks = Blocks,
		Entities = Entities,
		SetBlock = function(_, X, Y, Z, BlockType) Blocks[X .. "," .. Y .. "," .. Z] = BlockType end,
		SetEntity = function(_, X, Y, Z, Entity) Entities[X .. "," .. Y .. "," .. Z] = Entity end,
		GetBlockType = function(_, X, Y, Z) return Blocks[X .. "," .. Y .. "," .. Z] or 0 end,
		GetBlockEntity = function(_, X, Y, Z) return Entities[X .. "," .. Y .. "," .. Z] end,
		ReadBlockArea = function(_, Area, MinX, MaxX, MinY, MaxY, MinZ, MaxZ)
			Area.Populate = function(X, Y, Z) return Self:GetBlockType(X, Y, Z) end
		end,
	}
	return Self
end

local function MakeWorld(Name, Cfg)
	return { GetName = function() return Name end, Cfg = Cfg }
end

local DEFAULT_CFG = { Seed = 1402121502, GridSizeX = 384, GridSizeZ = 384,
	MaxOffsetX = 128, MaxOffsetZ = 128, MaxStructureSizeX = 128, MaxStructureSizeZ = 128 }
local WorldNr = 0
local function FreshWorld()
	WorldNr = WorldNr + 1
	return MakeWorld("testworld" .. WorldNr, DEFAULT_CFG)
end

---A chest at (5, 64, 5) with the given neighbourhood blocks applied.
local function MakeScenario(a_Neighbours, a_ExistingItems)
	local Chunk = MakeChunkDesc()
	Chunk:SetBlock(5, 64, 5, E_BLOCK_CHEST)
	local Grid = MakeGrid()
	if a_ExistingItems then
		for Slot = 0, a_ExistingItems - 1 do
			Grid:SetSlot(Slot, E_ITEM_IRON, 1, 0)
		end
	end
	Chunk:SetEntity(5, 64, 5, {
		GetContents = function() return Grid end,
		GetBlockType = function() return E_BLOCK_CHEST end,
	})
	for _, N in ipairs(a_Neighbours or {}) do
		Chunk:SetBlock(N[1], N[2], N[3], N[4])
	end
	return Chunk, Grid
end


-- ===========================================================================
-- 5. A. Tables
-- ===========================================================================

Section("A. loot tables")

Check("there is a table per classifier result",
	(VillageLoot.Tables.Weaponsmith ~= nil) and (VillageLoot.Tables.Farm ~= nil) and (VillageLoot.Tables.House ~= nil))
for _, Name in ipairs({ "Weaponsmith", "Farm", "House" }) do
	local Table = VillageLoot.Tables[Name]
	local Ok, Why = true, nil
	for Index, Entry in ipairs(Table) do
		if (type(Entry.Item) ~= "number") or (type(Entry.Min) ~= "number") or (type(Entry.Max) ~= "number")
			or (type(Entry.Weight) ~= "number") then
			Ok, Why = false, "entry " .. Index .. " is malformed"
		elseif (Entry.Min < 1) or (Entry.Max < Entry.Min) or (Entry.Weight < 1) then
			Ok, Why = false, "entry " .. Index .. " has bad range/weight"
		end
	end
	if (Name == "Weaponsmith") then
		Check("the weaponsmith table is the classic blacksmith chest", #Table == 16, #Table)
		Check("it contains the diamond entry", Table[1].Item == E_ITEM_DIAMOND and Table[1].Min == 1 and Table[1].Max == 3)
		Check("bread outweighs the diamond", Table[4].Weight == 15 and Table[1].Weight == 3)
	end
	Check("table " .. Name .. " is well formed", Ok, Why)
end


-- ===========================================================================
-- 6. B. Roller
-- ===========================================================================

Section("B. Roll")

local Table = VillageLoot.Tables.House

local GridA, GridB = MakeGrid(), MakeGrid()
local WrittenA = VillageLoot.Roll(GridA, Table, 4, 12345)
local WrittenB = VillageLoot.Roll(GridB, Table, 4, 12345)
Check("roll returns the number of stacks", WrittenA == 4, WrittenA)
Check("the same seed writes the same number of stacks", WrittenA == WrittenB, WrittenA .. " vs " .. WrittenB)
local Same = true
for Slot = 0, 26 do
	local A, B = GridA.Slots[Slot], GridB.Slots[Slot]
	if (A == nil) ~= (B == nil) then
		Same = false
	elseif A and ((A[1] ~= B[1]) or (A[2] ~= B[2])) then
		Same = false
	end
end
Check("the same seed gives the same loot", Same)

local GridC = MakeGrid()
VillageLoot.Roll(GridC, Table, 4, 999)
local Differs = false
for Slot = 0, 26 do
	local A, C = GridA.Slots[Slot], GridC.Slots[Slot]
	if (A == nil) ~= (C == nil) then
		Differs = true
	elseif A and C and ((A[1] ~= C[1]) or (A[2] ~= C[2])) then
		Differs = true
	end
end
Check("a different seed gives different loot", Differs)

-- Every written stack must be a table entry with a count inside its range, and must
-- land in one of the first NumStacks slots.
local Allowed = {}
for _, Entry in ipairs(Table) do
	Allowed[Entry.Item] = Entry
end
local BadItem, BadCount, BadSlot = nil, nil, nil
for Seed = 1, 200 do
	local Grid = MakeGrid()
	VillageLoot.Roll(Grid, Table, 5, Seed)
	for Slot = 0, 26 do
		local Stack = Grid.Slots[Slot]
		if Stack then
			if (Slot >= 5) then BadSlot = Slot end
			local Entry = Allowed[Stack[1]]
			if (Entry == nil) then
				BadItem = Stack[1]
			elseif (Stack[2] < Entry.Min) or (Stack[2] > Entry.Max) then
				BadCount = Stack[1] .. "x" .. Stack[2]
			end
		end
	end
end
Check("every stack comes from the table", BadItem == nil, BadItem)
Check("every stack size is inside its range", BadCount == nil, BadCount)
Check("stacks only occupy the first NumStacks slots", BadSlot == nil, BadSlot)

Check("Roll with a zero-weight table writes nothing",
	VillageLoot.Roll(MakeGrid(), { { Item = E_ITEM_BREAD, Min = 1, Max = 1, Weight = 0 } }, 3, 1) == 0)
Check("Roll with no stacks writes nothing", VillageLoot.Roll(MakeGrid(), Table, 0, 1) == 0)

-- The weights have to matter: over many seeds, a weight-10 entry must win more often
-- than a weight-2 one.
local Heavy, Light = 0, 0
for Seed = 1, 400 do
	local Grid = MakeGrid()
	VillageLoot.Roll(Grid, Table, 1, Seed)
	local Stack = Grid.Slots[0]
	if Stack then
		if (Stack[1] == E_ITEM_BREAD) then
			Heavy = Heavy + 1
		elseif (Stack[1] == E_ITEM_BOOK) then
			Light = Light + 1
		end
	end
end
Check("weighting is respected (bread " .. Heavy .. " vs book " .. Light .. ")", Heavy > Light)


-- ===========================================================================
-- 7. C. Emptiness
-- ===========================================================================

Section("C. IsEmpty")

Check("a fresh grid is empty", VillageLoot.IsEmpty(MakeGrid()) == true)
local Stocked = MakeGrid()
Stocked:SetSlot(7, E_ITEM_IRON, 1, 0)
Check("a grid with one item is not empty", VillageLoot.IsEmpty(Stocked) == false)


-- ===========================================================================
-- 8. D. Classifier
-- ===========================================================================

Section("D. Classify")

local function ClassifyWith(a_Neighbours)
	local Chunk = MakeScenario(a_Neighbours)
	return VillageLoot.Classify(Chunk, 5, 64, 5)
end

Check("a chest next to a furnace is a Weaponsmith", ClassifyWith({ { 6, 64, 5, E_BLOCK_FURNACE } }) == "Weaponsmith")
Check("a lit furnace counts too", ClassifyWith({ { 3, 64, 5, E_BLOCK_LIT_FURNACE } }) == "Weaponsmith")
Check("a furnace up to 8 blocks away counts", ClassifyWith({ { 13, 65, 5, E_BLOCK_FURNACE } }) == "Weaponsmith")
Check("a chest next to hay is a Farm", ClassifyWith({ { 4, 64, 5, E_BLOCK_HAY_BALE } }) == "Farm")
Check("a chest next to a hopper is a Farm", ClassifyWith({ { 6, 64, 5, E_BLOCK_HOPPER } }) == "Farm")
Check("hay wins over a distant furnace",
	ClassifyWith({ { 4, 64, 5, E_BLOCK_HAY_BALE }, { 13, 64, 5, E_BLOCK_FURNACE } }) == "Farm")
Check("a plain chest is a House", ClassifyWith({}) == "House")
Check("the scan stays inside the chunk (no error at the edge)",
	VillageLoot.Classify(MakeScenario({}), 0, 64, 0) == "House")


-- ===========================================================================
-- 9. E. The hook
-- ===========================================================================

Section("E. OnChunkGenerated")

local function CountItems(Grid)
	local Count = 0
	for Slot = 0, 26 do
		if Grid.Slots[Slot] then
			Count = Count + 1
		end
	end
	return Count
end

-- An empty chest is a village chest: it gets loot.
local Chunk, Grid = MakeScenario({})
VillageLoot.Enabled = true
local Ret = VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, Chunk)
local Written = CountItems(Grid)
Check("the handler returns false so other plugins still run", Ret == false)
Check("an empty chest gets filled with 3..6 stacks", (Written >= 3) and (Written <= 6), Written)
Check("the handler is deterministic", (function()
	local Chunk2, Grid2 = MakeScenario({})
	VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, Chunk2)
	for Slot = 0, 26 do
		local A, B = Grid.Slots[Slot], Grid2.Slots[Slot]
		if (A == nil) ~= (B == nil) then return false end
		if A and ((A[1] ~= B[1]) or (A[2] ~= B[2])) then return false end
	end
	return true
end)())

-- A chest the engine already stocked must be left alone.
local StockedChunk, StockedGrid = MakeScenario({}, 4)
VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, StockedChunk)
Check("an already-stocked chest keeps exactly its own items", CountItems(StockedGrid) == 4, CountItems(StockedGrid))
Check("and its items are untouched", StockedGrid.Slots[0] ~= nil and StockedGrid.Slots[0][1] == E_ITEM_IRON)

-- A forge chest gets the weaponsmith table.
local ForgeChunk, ForgeGrid = MakeScenario({ { 6, 64, 5, E_BLOCK_FURNACE } })
VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, ForgeChunk)
local WeaponsmithItems = {}
for _, Entry in ipairs(VillageLoot.Tables.Weaponsmith) do WeaponsmithItems[Entry.Item] = true end
local Foreign = nil
for Slot = 0, 26 do
	if ForgeGrid.Slots[Slot] and not WeaponsmithItems[ForgeGrid.Slots[Slot][1]] then
		Foreign = ForgeGrid.Slots[Slot][1]
	end
end
Check("a forge chest gets weaponsmith loot", (CountItems(ForgeGrid) >= 3) and (Foreign == nil), Foreign)

-- Disabled: nothing happens.
VillageLoot.Enabled = false
local OffChunk, OffGrid = MakeScenario({})
VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, OffChunk)
Check("a disabled plugin leaves the chest alone", CountItems(OffGrid) == 0)
VillageLoot.Enabled = true

-- No village near this chunk: nothing happens.
local SavedCandidates = StubCandidates
StubCandidates = { { CellX = 100000, CellZ = 100000, OriginX = 100000 * 384, OriginZ = 100000 * 384 } }
local FarChunk, FarGrid = MakeScenario({})
VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, FarChunk)
Check("a chunk outside every village box is skipped", CountItems(FarGrid) == 0)
StubCandidates = SavedCandidates

-- A chunk with no chest at all is a fast no-op.
local EmptyChunk = MakeChunkDesc()
Check("a chunk without chests is a no-op",
	VillageLoot.OnChunkGenerated(FreshWorld(), 0, 0, EmptyChunk) == false)


-- ===========================================================================
-- 10. Summary
-- ===========================================================================

print("")
print(string.format("village_loot_test: %d passed, %d failed", Passed, Failed))
if (Failed > 0) then
	print("")
	print("Failures:")
	for _, F in ipairs(Failures) do
		print("  - " .. F)
	end
end
os.exit(Failed == 0 and 0 or 1)
