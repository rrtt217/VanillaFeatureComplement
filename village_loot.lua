-- village_loot.lua
--
-- Gives village chests real contents.
--
-- Why this has to exist: a prefab carries only BLOCKTYPE + NIBBLETYPE, so it cannot
-- describe what is inside a container (see docs/village-location.md). The village
-- cubesets do place chests -- PlainsVillage has four, in Forge, WoodenGranary,
-- WoodenChurchMid and WoodenMill5x5 -- but the engine materialises them as empty
-- cChestEntity objects.
--
-- The engine fills its *own* chests (mineshafts, dungeon rooms) from C++ code via
-- cChunkDesc::GetBlockEntity() + cItemGrid::GenerateRandomLootWithBooks(). That
-- function is not bound to Lua -- ItemGrid.h says "Cannot export to Lua due to raw
-- array a_LootProbabs" -- so the roller below reimplements the same shape: a
-- weighted pick per stack, with the stack size drawn from that entry's [min, max].
--
-- Which chests are village chests? Only the ones that are still empty when the chunk
-- is handed to the hook. Mineshaft and dungeon chests are filled by the engine during
-- generation with 3..6 stacks, so an empty chest at HOOK_CHUNK_GENERATED is one a
-- prefab placed. That also means this module never touches the engine's loot.
--
-- LOOT TABLES: adapted from the reference at
--   https://zh.minecraft.wiki/w/箱子战利品（结构索引）
-- which lists the modern (1.14+) village tables. Cuberite is a 1.8-era server, so:
--   * Weaponsmith is the classic blacksmith chest, which is stable across versions
--     and is what the modern village_weaponsmith still resembles;
--   * Farm and House have no 1.8 counterpart -- in 1.8 only the blacksmith had a
--     chest at all -- so they are shaped after the modern village_*_house and farmer
--     tables, reduced to items this build actually has.
-- Treat the numbers as a starting point rather than as copied vanilla data. They are
-- plain data; edit them freely.

-- luacheck: globals VillageLocate

VillageLoot = {}

---Set by Initialize() from settings.ini. The hook is only registered when the feature
---is on; the flag keeps the handler inert if it is ever called anyway.
VillageLoot.Enabled = false

-- ===========================================================================
-- 1. Loot tables
-- ===========================================================================

---Each entry is { Item, Min, Max, Weight }; Weight is relative to the other entries.
VillageLoot.Tables =
{
	-- Forges and blacksmiths. The classic blacksmith chest.
	Weaponsmith =
	{
		{ Item = E_ITEM_DIAMOND,          Min = 1, Max = 3, Weight = 3  },
		{ Item = E_ITEM_IRON,             Min = 1, Max = 5, Weight = 10 },
		{ Item = E_ITEM_GOLD,             Min = 1, Max = 3, Weight = 5  },
		{ Item = E_ITEM_BREAD,            Min = 1, Max = 3, Weight = 15 },
		{ Item = E_ITEM_RED_APPLE,        Min = 1, Max = 3, Weight = 15 },
		{ Item = E_ITEM_IRON_SWORD,       Min = 1, Max = 1, Weight = 5  },
		{ Item = E_ITEM_IRON_PICKAXE,     Min = 1, Max = 1, Weight = 5  },
		{ Item = E_ITEM_IRON_HELMET,      Min = 1, Max = 1, Weight = 5  },
		{ Item = E_ITEM_IRON_CHESTPLATE,  Min = 1, Max = 1, Weight = 5  },
		{ Item = E_ITEM_IRON_LEGGINGS,    Min = 1, Max = 1, Weight = 5  },
		{ Item = E_ITEM_IRON_BOOTS,       Min = 1, Max = 1, Weight = 5  },
		{ Item = E_BLOCK_SAPLING,         Min = 1, Max = 7, Weight = 5  },
		{ Item = E_BLOCK_OBSIDIAN,        Min = 3, Max = 7, Weight = 5  },
		{ Item = E_ITEM_SADDLE,           Min = 1, Max = 1, Weight = 3  },
		{ Item = E_ITEM_IRON_HORSE_ARMOR, Min = 1, Max = 1, Weight = 1  },
		{ Item = E_ITEM_GOLDEN_APPLE,     Min = 1, Max = 1, Weight = 1  },
	},

	-- Granaries and mills.
	Farm =
	{
		{ Item = E_ITEM_WHEAT,            Min = 1, Max = 6, Weight = 10 },
		{ Item = E_ITEM_SEEDS,            Min = 1, Max = 4, Weight = 10 },
		{ Item = E_ITEM_BREAD,            Min = 1, Max = 3, Weight = 8  },
		{ Item = E_ITEM_POTATO,           Min = 1, Max = 4, Weight = 6  },
		{ Item = E_ITEM_CARROT,           Min = 1, Max = 4, Weight = 6  },
		{ Item = E_BLOCK_HAY_BALE,        Min = 1, Max = 2, Weight = 6  },
		{ Item = E_ITEM_BEETROOT_SEEDS,   Min = 1, Max = 4, Weight = 5  },
		{ Item = E_ITEM_BEETROOT,         Min = 1, Max = 3, Weight = 4  },
		{ Item = E_ITEM_RED_APPLE,        Min = 1, Max = 3, Weight = 4  },
		{ Item = E_ITEM_EMERALD,          Min = 1, Max = 2, Weight = 2  },
		{ Item = E_ITEM_IRON_HOE,         Min = 1, Max = 1, Weight = 1  },
	},

	-- Churches and any other village building that ends up with a chest.
	House =
	{
		{ Item = E_ITEM_BREAD,            Min = 1, Max = 3, Weight = 10 },
		{ Item = E_ITEM_WHEAT,            Min = 1, Max = 4, Weight = 8  },
		{ Item = E_ITEM_SEEDS,            Min = 1, Max = 4, Weight = 8  },
		{ Item = E_ITEM_POTATO,           Min = 1, Max = 4, Weight = 6  },
		{ Item = E_ITEM_CARROT,           Min = 1, Max = 4, Weight = 6  },
		{ Item = E_ITEM_STICK,            Min = 1, Max = 4, Weight = 6  },
		{ Item = E_ITEM_COAL,             Min = 1, Max = 4, Weight = 5  },
		{ Item = E_ITEM_RED_APPLE,        Min = 1, Max = 3, Weight = 5  },
		{ Item = E_ITEM_EMERALD,          Min = 1, Max = 2, Weight = 3  },
		{ Item = E_ITEM_IRON,             Min = 1, Max = 2, Weight = 2  },
		{ Item = E_ITEM_BOOK,             Min = 1, Max = 1, Weight = 2  },
		{ Item = E_ITEM_STRING,           Min = 1, Max = 3, Weight = 2  },
	},
}

---How many stacks a chest gets, matching the engine's mineshaft/dungeon range (3..6).
local MIN_STACKS = 3
local MAX_STACKS = 6


-- ===========================================================================
-- 2. Deterministic roller
-- ===========================================================================

---Park-Miller linear congruential generator (Lehmer). Deterministic and exact in
---doubles: 16807 * 2147483646 stays below 2^53.
---@param Seed number
---@return function Next01   Returns a number in [0, 1)
local function MakeRng(Seed)
	local State = math.floor(math.abs(Seed)) % 2147483647
	if (State <= 0) then
		State = State + 2147483646
	end
	return function()
		State = (State * 16807) % 2147483647
		return State / 2147483647
	end
end

---Roll a loot table into a cItemGrid.
---@param Contents cItemGrid
---@param Table table       Array of { Item, Min, Max, Weight }
---@param NumStacks number
---@param Seed number
---@return number NumWritten
function VillageLoot.Roll(Contents, Table, NumStacks, Seed)
	local TotalWeight = 0
	for _, Entry in ipairs(Table) do
		TotalWeight = TotalWeight + Entry.Weight
	end
	if (TotalWeight <= 0) then
		return 0
	end

	local Next01 = MakeRng(Seed)
	local Written = 0
	for Slot = 0, NumStacks - 1 do
		local Pick = Next01() * TotalWeight
		local Chosen = nil
		for _, Entry in ipairs(Table) do
			Pick = Pick - Entry.Weight
			if (Pick < 0) then
				Chosen = Entry
				break
			end
		end
		if (Chosen ~= nil) then
			local Count = Chosen.Min
			if (Chosen.Max > Chosen.Min) then
				Count = Chosen.Min + math.floor(Next01() * (Chosen.Max - Chosen.Min + 1))
				if (Count > Chosen.Max) then
					Count = Chosen.Max
				end
			end
			Contents:SetSlot(Slot, Chosen.Item, Count, 0)
			Written = Written + 1
		end
	end
	return Written
end


-- ===========================================================================
-- 3. Which table fits this chest
-- ===========================================================================

---Neighbourhood scan window for the farm markers, and for the forge furnace.
local FARM_RADIUS    = 2
local FURNACE_RADIUS = 8

---Returns true if a block of any of the listed types is within the box.
---@param ChunkDesc cChunkDesc
---@param X number
---@param Y number
---@param Z number
---@param Radius number
---@param RY number
---@param Wanted table
---@return boolean
local function HasNear(ChunkDesc, X, Y, Z, Radius, RY, Wanted)
	for DX = -Radius, Radius do
		local PX = X + DX
		if (PX >= 0) and (PX < 16) then
			for DZ = -Radius, Radius do
				local PZ = Z + DZ
				if (PZ >= 0) and (PZ < 16) then
					for DY = -RY, RY do
						local PY = Y + DY
						if (PY >= 0) and (PY < 128) then
							if Wanted[ChunkDesc:GetBlockType(PX, PY, PZ)] then
								return true
							end
						end
					end
				end
			end
		end
	end
	return false
end

local FARM_MARKERS    = { [E_BLOCK_HAY_BALE] = true, [E_BLOCK_HOPPER] = true }
local FORGE_MARKERS   = { [E_BLOCK_FURNACE] = true, [E_BLOCK_LIT_FURNACE] = true }

---Pick the loot table that fits the chest, from the blocks the prefab left around it.
---
---The cubesets make this unambiguous at generation time:
---   * WoodenGranary has hay bales right next to its chest, WoodenMill5x5 has a hopper;
---   * every forge/blacksmith has a furnace within the same building -- but not always
---     adjacent (JapaneseVillage/Forge has its chest 6 blocks from the nearest one, and
---     AlchemistVillage/BlackSmith has no furnace in the piece at all), which is why the
---     furnace test uses a much wider radius than the farm tests.
---@param ChunkDesc cChunkDesc
---@param X number
---@param Y number
---@param Z number
---@return string
function VillageLoot.Classify(ChunkDesc, X, Y, Z)
	if HasNear(ChunkDesc, X, Y, Z, FARM_RADIUS, 1, FARM_MARKERS) then
		return "Farm"
	end
	if HasNear(ChunkDesc, X, Y, Z, FURNACE_RADIUS, 2, FORGE_MARKERS) then
		return "Weaponsmith"
	end
	return "House"
end


-- ===========================================================================
-- 4. The hook
-- ===========================================================================

---Village generator parameters, cached per world: reading world.ini and the cubesets
---on every generated chunk would be far too slow. A change to world.ini's village
---keys therefore needs a plugin reload.
local ConfigCache = {}

---@param World cWorld
---@return table|nil
local function GetConfig(World)
	local Name = World:GetName()
	local Cached = ConfigCache[Name]
	if (Cached == nil) then
		local Cfg = VillageLocate.GetGeneratorConfig(World)
		if (Cfg == nil) then
			ConfigCache[Name] = false
			return nil
		end
		Cached = { Seed = Cfg.Seed, GridSize = Cfg.GridSize, MaxOffset = Cfg.MaxOffset, MaxSize = Cfg.MaxSize }
		ConfigCache[Name] = Cached
	end
	if (Cached == false) then
		return nil
	end
	return Cached
end

---True if some village's pieces can reach this chunk at all. Pure geometry: a cell's
---pieces stay within MaxSize of the origin, and the origin is within MaxOffset of the
---cell point, so a chunk no such box touches cannot hold a village chest.
---@param World cWorld
---@param ChunkX number
---@param ChunkZ number
---@return boolean
local function MayContainVillage(World, ChunkX, ChunkZ)
	local Cfg = GetConfig(World)
	if (Cfg == nil) then
		return false
	end
	local MinX, MaxX = ChunkX * 16, ChunkX * 16 + 15
	local MinZ, MaxZ = ChunkZ * 16, ChunkZ * 16 + 15
	for _, Candidate in ipairs(VillageLocate.GetCandidates(Cfg, MinX, MaxX, MinZ, MaxZ)) do
		if
			(Candidate.OriginX + Cfg.MaxSize >= MinX) and (Candidate.OriginX - Cfg.MaxSize <= MaxX) and
			(Candidate.OriginZ + Cfg.MaxSize >= MinZ) and (Candidate.OriginZ - Cfg.MaxSize <= MaxZ)
		then
			return true
		end
	end
	return false
end

---HOOK_CHUNK_GENERATED: fill the chests a village prefab placed but could not stock.
---@param World cWorld
---@param ChunkX number
---@param ChunkZ number
---@param ChunkDesc cChunkDesc
---@return boolean
function VillageLoot.OnChunkGenerated(World, ChunkX, ChunkZ, ChunkDesc)
	if not VillageLoot.Enabled then
		return false
	end
	if not MayContainVillage(World, ChunkX, ChunkZ) then
		return false
	end

	-- Finding chests through a cBlockArea keeps the per-chunk cost in C: counting
	-- 32k blocks from Lua would add milliseconds to every single chunk.
	local Area = cBlockArea()
	ChunkDesc:ReadBlockArea(Area, 0, 15, 0, 127, 0, 15)
	if (Area:CountSpecificBlocks(E_BLOCK_CHEST) == 0) then
		return false
	end

	for X = 0, 15 do
		for Z = 0, 15 do
			for Y = 0, 127 do
				if (Area:GetRelBlockType(X, Y, Z) == E_BLOCK_CHEST) then
					local Entity = ChunkDesc:GetBlockEntity(X, Y, Z)
					local Chest = nil
					if (Entity ~= nil) and (Entity:GetBlockType() == E_BLOCK_CHEST) then
						-- cChunkDesc:GetBlockEntity is declared as returning cBlockEntity, and
						-- tolua resolves methods through the *declared* class, which has no
						-- GetContents. The block type check proves the object really is a chest,
						-- so casting to the class that declares GetContents is sound (tolua.cast
						-- itself does not check the type).
						Chest = tolua.cast(Entity, "cBlockEntityWithItems")
					end
					if (Chest ~= nil) then
						local Contents = Chest:GetContents()
						if VillageLoot.IsEmpty(Contents) then
							local Table = VillageLoot.Tables[VillageLoot.Classify(ChunkDesc, X, Y, Z)]
							if (Table ~= nil) then
								local Seed = (ChunkX * 31 + ChunkZ * 17) * 65536 + (X * 16 + Z) * 256 + Y
								local Stacks = MIN_STACKS +
									(math.floor(math.abs(Seed) / 7) % (MAX_STACKS - MIN_STACKS + 1))
								VillageLoot.Roll(Contents, Table, Stacks, Seed)
							end
						end
					end
				end
			end
		end
	end
	return false
end

---A chest grid counts as empty when every slot is empty. The engine's own chests hold
---3..6 stacks by this point, so this is what separates a village chest from a
---mineshaft or dungeon one.
---@param Contents cItemGrid
---@return boolean
function VillageLoot.IsEmpty(Contents)
	for Slot = 0, Contents:GetNumSlots() - 1 do
		if not Contents:IsSlotEmpty(Slot) then
			return false
		end
	end
	return true
end
