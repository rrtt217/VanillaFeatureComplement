-- structure_locate.lua
--
-- Locates the structures Cuberite generates on a grid, in the style of the pre-1.16
-- Java /locate command (Cuberite targets 1.12.2, where the syntax is
-- "/locate <StructureType>", case sensitive, and the reply is the nearest structure's
-- coordinates plus the distance).
--
-- Cuberite exposes nothing about structures: cChunkDesc has no structure list, the
-- chunk hooks carry only (World, ChunkX, ChunkZ, ChunkDesc), and the whole structure
-- machinery is outside the tolua parse set (AllToLua.pkg takes exactly one header from
-- Generating/, and it is ChunkDesc.h). cPrefab has zero tolua markers and zero
-- tolua_AllToLua_*Prefab* symbols in the binary, against 48 for cBlockArea. So a plugin
-- cannot hold a structure - but it can reimplement the placement, which is deterministic.
--
-- Every structure Cuberite places on a grid is a cGridStructGen descendant, and they all
-- share the same placement maths (Generating/GridStructGen.cpp, GetStructuresForChunk):
--
--   OriginX = GridX + (IntNoise2DInt(GridX + 3, GridZ + 5) / 7) % (2 * MaxOffsetX) - MaxOffsetX
--   OriginZ = GridZ + (IntNoise2DInt(GridX + 5, GridZ + 3) / 7) % (2 * MaxOffsetZ) - MaxOffsetZ
--
-- GridX / GridZ are cell points (multiples of GridSizeX / GridSizeZ), and MinBlockX is
-- negative for negative coordinates, so the cell index uses C integer division, which
-- truncates towards zero and so disagrees with math.floor.
--
-- What differs per kind is the parameters, the eligibility test and the position:
--
--   * Mineshafts (Generating/MineShafts.cpp) take their parameters from world.ini and
--     have NO eligibility test - CreateStructure always returns a system, so every grid
--     cell really does hold one. The grid origin is only an anchor though: the dirt room
--     sits up to MaxOffsetX away from it, so that is what gets reported.
--
--   * Villages (Generating/VillageGen.cpp) need every one of the 256 biome columns of
--     the origin's chunk to be allowed by one of the loaded pools. That is a 256-sample
--     test, and the engine only reports biomes for loaded chunks, so a village can often
--     only be reported as a candidate.
--
--   * Single-piece structures and piece structures
--     (Generating/SinglePieceStructuresGen.cpp) take their parameters from the cubeset
--     metadata instead, including a SeedOffset, and need only the single biome at the
--     origin block to be allowed.
--
-- IntNoise2DInt / IntNoise3DInt are declared inline in Noise/Noise.h and are not bound,
-- so they are ported below, 32-bit wraparound included. That is the part a naive Lua port
-- gets wrong: Lua 5.1 has only doubles, and n * n * 15731 overflows the 53-bit
-- exact-integer range, so the multiply is split into 16-bit halves.

-- luacheck: globals mtInfo
-- The three names below are exported on purpose: CallPlugin reaches them by plain global
-- name, and nothing inside this plugin calls them, so they would otherwise be reported as
-- unused globals.
-- luacheck: ignore StructureLocateAPIVersion StructureLocateKinds
-- luacheck: ignore StructureLocateFindNearest StructureLocateFindAll

StructureLocate = {}

local TWO_31  = 2147483648
local TWO_32  = 4294967296
local CHUNK_W = 16

---Y reported for a structure whose height is not part of its placement. Java shows 64
---for those, so this follows it rather than inventing a number.
local UNKNOWN_Y = 64

---Java searches a 201 x 201 chunk square, ie. 100 chunks in every direction from the
---executor's chunk. The block window is derived from that rather than from a block
---radius, so the searched area is a square whose edges fall on chunk boundaries.
local SEARCH_CHUNKS = 100


-- ===========================================================================
-- 1. 32-bit arithmetic (Lua 5.1 has no bitwise operators and no integers)
-- ===========================================================================

---Bitwise XOR of two 32-bit unsigned values.
local function BXor32(a, b)
	local Result = 0
	local Bit = 1
	for _ = 1, 32 do
		local ABit = a % 2
		local BBit = b % 2
		if (ABit ~= BBit) then
			Result = Result + Bit
		end
		a = (a - ABit) / 2
		b = (b - BBit) / 2
		Bit = Bit * 2
	end
	return Result
end

---Exact low 32 bits of a * b, for unsigned 32-bit a and b. The operands are split into
---16-bit halves so that every intermediate value stays below 2^53.
local function Mul32(a, b)
	a = a % TWO_32
	b = b % TWO_32
	local ALo = a % 65536
	local AHi = (a - ALo) / 65536
	local BLo = b % 65536
	local BHi = (b - BLo) / 65536
	return (ALo * BLo + ((ALo * BHi + AHi * BLo) % 65536) * 65536) % TWO_32
end

---C integer division: truncates towards zero, unlike math.floor.
local function DivC(a, b)
	local Quotient = a / b
	if (Quotient >= 0) then
		return math.floor(Quotient)
	end
	return math.ceil(Quotient)
end

---cChunkDef::BlockToChunk for one axis (an arithmetic shift, ie. floor).
local function BlockToChunk(a)
	return math.floor(a / CHUNK_W)
end

StructureLocate.BXor32 = BXor32
StructureLocate.Mul32 = Mul32


-- ===========================================================================
-- 2. cNoise ports
-- ===========================================================================

---Exact port of cNoise::IntNoise2DInt() (src/Noise/Noise.h). Wraps as 32-bit and returns
---the low 31 bits, so it is always non-negative.
function StructureLocate.IntNoise2DInt(Seed, X, Y)
	local n = (X + Y * 57 + Seed * 3249) % TWO_32
	n = BXor32(Mul32(n, 8192), n)
	local Inner = (Mul32(Mul32(n, n), 15731) + 789221) % TWO_32
	return (Mul32(n, Inner) + 1376312589) % TWO_31
end

---Exact port of cNoise::IntNoise3DInt(). Same shape, with the extra 57 * 57 term.
function StructureLocate.IntNoise3DInt(Seed, X, Y, Z)
	local n = (X + Y * 57 + Z * 3249 + Seed * 185193) % TWO_32
	n = BXor32(Mul32(n, 8192), n)
	local Inner = (Mul32(Mul32(n, n), 15731) + 789221) % TWO_32
	return (Mul32(n, Inner) + 1376312589) % TWO_31
end


-- ===========================================================================
-- 3. Grid geometry
-- ===========================================================================

---The origin cGridStructGen would use for the given cell point.
function StructureLocate.GetCellOrigin(Seed, Cfg, CellX, CellZ)
	local OffsetX = math.floor(StructureLocate.IntNoise2DInt(Seed, CellX + 3, CellZ + 5) / 7)
		% (Cfg.MaxOffsetX * 2)
	local OffsetZ = math.floor(StructureLocate.IntNoise2DInt(Seed, CellX + 5, CellZ + 3) / 7)
		% (Cfg.MaxOffsetZ * 2)
	return CellX + OffsetX - Cfg.MaxOffsetX, CellZ + OffsetZ - Cfg.MaxOffsetZ
end

---Every grid cell whose structure may intersect the given block rectangle. Mirrors
---cGridStructGen::GetStructuresForChunk, generalised from one chunk to an arbitrary
---rectangle, and per-axis like the engine.
function StructureLocate.GetCandidates(Cfg, MinX, MaxX, MinZ, MaxZ)
	local ReachX = Cfg.MaxStructureSizeX + Cfg.MaxOffsetX
	local ReachZ = Cfg.MaxStructureSizeZ + Cfg.MaxOffsetZ
	local MinGridX = DivC(MinX - ReachX, Cfg.GridSizeX)
	local MaxGridX = DivC(MaxX + ReachX + Cfg.GridSizeX - 1, Cfg.GridSizeX)
	local MinGridZ = DivC(MinZ - ReachZ, Cfg.GridSizeZ)
	local MaxGridZ = DivC(MaxZ + ReachZ + Cfg.GridSizeZ - 1, Cfg.GridSizeZ)

	local Result = {}
	for CellXi = MinGridX, MaxGridX - 1 do
		local CellX = CellXi * Cfg.GridSizeX
		for CellZi = MinGridZ, MaxGridZ - 1 do
			local CellZ = CellZi * Cfg.GridSizeZ
			local OriginX, OriginZ = StructureLocate.GetCellOrigin(Cfg.Seed, Cfg, CellX, CellZ)
			Result[#Result + 1] = { CellX = CellX, CellZ = CellZ, OriginX = OriginX, OriginZ = OriginZ }
		end
	end
	return Result
end

---Where a mineshaft actually is: cMineShaftDirtRoom's constructor offsets the room from
---the grid origin and sizes it. Returns p1x, p2x, p1z, p2z, p1y, p2y.
function StructureLocate.GetMineShaftDirtRoom(Cfg, OriginX, OriginZ)
	local Seed = Cfg.Seed
	local Rnd = math.floor(StructureLocate.IntNoise3DInt(Seed, OriginX, 0, OriginZ) / 7)
	local OfsX = (Rnd % Cfg.GridSizeX) - math.floor(Cfg.GridSizeX / 2)
	Rnd = math.floor(Rnd / 4096)
	local OfsZ = (Rnd % Cfg.GridSizeZ) - math.floor(Cfg.GridSizeZ / 2)
	Rnd = math.floor(StructureLocate.IntNoise3DInt(Seed, OriginX, 1000, OriginZ) / 11)
	local P1X = OriginX + OfsX
	local P2X = P1X + 10 + (Rnd % 8)
	Rnd = math.floor(Rnd / 16)
	local P1Z = OriginZ + OfsZ
	local P2Z = P1Z + 10 + (Rnd % 8)
	Rnd = math.floor(Rnd / 16)
	return P1X, P2X, P1Z, P2Z, 20, 24 + (Rnd % 8)
end


-- ===========================================================================
-- 4. Per-kind parameters
-- ===========================================================================

---The structures /locate knows about, keyed by the Java name (case sensitive, as Java).
---
---  Source    "ini"    parameters from world.ini, seed is the plain world seed
---            "single" parameters from a Prefabs/SinglePieceStructures cubeset
---            "piece"  parameters from a Prefabs/PieceStructures cubeset
---  Biome     "none"   no eligibility test at all (mineshafts)
---            "origin" the single biome at the origin must be allowed
---            "village" all 256 biome columns of the origin chunk must be allowed
---  Position  "origin"   the grid origin is the structure
---            "dirtroom" the structure is the mineshaft dirt room
StructureLocate.Kinds =
{
	Mineshaft =
	{
		Source = "ini", Display = "废弃矿井", Biome = "none", Position = "dirtroom",
		Finisher = "MineShafts",
		IniKeys = { "MineShaftsGridSize", "MineShaftsMaxOffset", "MineShaftsMaxSystemSize" },
		IniDefaults = { 512, 256, 160 },
	},
	Village =
	{
		Source = "ini", Display = "村庄", Biome = "village", Position = "origin",
		Finisher = "Villages",
		IniKeys = { "VillageGridSize", "VillageMaxOffset", "VillageMaxSize" },
		IniDefaults = { 384, 128, 128 },
	},
	Desert_Pyramid = { Source = "single", Display = "沙漠神殿", Biome = "origin",
		Position = "origin", Cubeset = "DesertPyramid" },
	Jungle_Pyramid = { Source = "single", Display = "丛林神庙", Biome = "origin",
		Position = "origin", Cubeset = "JungleTemple" },
	Swamp_Hut = { Source = "single", Display = "女巫小屋", Biome = "origin",
		Position = "origin", Cubeset = "WitchHut" },
	Desert_Well = { Source = "single", Display = "沙漠水井", Biome = "origin",
		Position = "origin", Cubeset = "DesertWell" },
	Fortress = { Source = "piece", Display = "下界要塞", Biome = "origin",
		Position = "origin", Cubeset = "NetherFort" },
}

---Cubeset metadata keys that feed cGridStructGen::SetGeneratorParams.
local CUBESET_KEYS = { "GridSizeX", "GridSizeZ", "MaxOffsetX", "MaxOffsetZ",
	"MaxStructureSizeX", "MaxStructureSizeZ" }

---The Finishers list of a world, as a map from lowercased finisher name to its
---parameter string ("SinglePieceStructures" -> "JungleTemple|WitchHut|...").
---@return table|nil List, string|nil Error
local function ReadFinishers(World)
	local Ini = cIniFile()
	if not Ini:ReadFile(World:GetIniFileName()) then
		return nil, "cannot read " .. tostring(World:GetIniFileName())
	end
	local List = {}
	for Entry in Ini:GetValue("Generator", "Finishers", ""):gmatch("[^,]+") do
		local Name, Params = Entry:match("^%s*([^:]+):%s*(.*)$")
		if (Name == nil) then
			Name, Params = Entry:match("^%s*(.-)%s*$"), ""
		else
			Name = Name:match("^%s*(.-)%s*$")
		end
		List[Name:lower()] = { Name = Name, Params = Params }
	end
	return List
end

---First value of a '["Key"] = "Value"' pair in a cubeset. The pool-level Metadata block
---comes first in the file, and the per-piece blocks do not repeat these keys.
local function ReadCubesetValue(Contents, Key)
	return Contents:match('%[%s*"' .. Key .. '"%s*%]%s*=%s*"([^"]*)"')
end

---Reads a cubeset referenced by a SinglePieceStructures / PieceStructures finisher.
---@return table|nil Cfg, string|nil Error
local function BuildCubesetCfg(World, Kind, SubDir)
	local Separator = cFile:GetPathSeparator()
	local Path = "Prefabs" .. Separator .. SubDir .. Separator .. Kind.Cubeset .. ".cubeset"
	local Contents = cFile:ReadWholeFile(Path)
	if ((Contents == nil) or (Contents == "")) then
		return nil, "cannot read " .. Path
	end

	-- cGridStructGen's own defaults, used for any key the cubeset omits:
	local Cfg =
	{
		Seed = World:GetSeed(),
		GridSizeX = 256, GridSizeZ = 256,
		MaxOffsetX = 128, MaxOffsetZ = 128,
		MaxStructureSizeX = 128, MaxStructureSizeZ = 128,
	}
	for _, Key in ipairs(CUBESET_KEYS) do
		local Value = tonumber(ReadCubesetValue(Contents, Key))
		if (Value ~= nil) then
			Cfg[Key] = Value
		end
	end
	-- Only cSinglePieceStructuresGen / cPieceStructuresGen call SetGeneratorParams,
	-- which is the only place a SeedOffset is applied:
	Cfg.Seed = Cfg.Seed + (tonumber(ReadCubesetValue(Contents, "SeedOffset")) or 0)

	Cfg.Path = Path
	local Allowed = ReadCubesetValue(Contents, "AllowedBiomes") or ""
	Cfg.AllowedBiomes = {}
	for Entry in Allowed:gmatch("[^,]+") do
		local Biome = StringToBiome(Entry:match("^%s*(.-)%s*$"))
		if (Biome >= 0) then
			Cfg.AllowedBiomes[Biome] = true
		end
	end
	return Cfg
end

---Builds the placement parameters for a kind in a world, or explains why it cannot.
---@return table|nil Cfg, string|nil Error
function StructureLocate.GetConfig(World, Kind)
	local List, Err = ReadFinishers(World)
	if (List == nil) then
		return nil, Err
	end

	if (Kind.Source == "ini") then
		if (List[Kind.Finisher:lower()] == nil) then
			return nil, "此世界不生成" .. Kind.Display
		end
		local Ini = cIniFile()
		Ini:ReadFile(World:GetIniFileName())
		local Grid = Ini:GetValueI("Generator", Kind.IniKeys[1], Kind.IniDefaults[1])
		local Offset = Ini:GetValueI("Generator", Kind.IniKeys[2], Kind.IniDefaults[2])
		local Size = Ini:GetValueI("Generator", Kind.IniKeys[3], Kind.IniDefaults[3])
		-- The engine silently bumps a zero grid size and a zero offset to 1:
		if (Grid == 0) then Grid = 1 end
		if (Offset == 0) then Offset = 1 end
		return
		{
			Seed = World:GetSeed(),
			GridSizeX = Grid, GridSizeZ = Grid,
			MaxOffsetX = Offset, MaxOffsetZ = Offset,
			MaxStructureSizeX = Size, MaxStructureSizeZ = Size,
		}
	end

	local SubDir = (Kind.Source == "single") and "SinglePieceStructures" or "PieceStructures"
	local Finisher = List[SubDir:lower()]
	if (Finisher == nil) then
		return nil, "此世界不生成" .. Kind.Display
	end
	local Wanted = false
	for Entry in Finisher.Params:gmatch("[^|]+") do
		if (Entry:match("^%s*(.-)%s*$"):lower() == Kind.Cubeset:lower()) then
			Wanted = true
		end
	end
	if not Wanted then
		return nil, "此世界不生成" .. Kind.Display
	end
	return BuildCubesetCfg(World, Kind, SubDir)
end


-- ===========================================================================
-- 5. Village pool eligibility
-- ===========================================================================

local PoolBiomeCache = {}

---The key a caller's biome table uses for a block position. Floored, so a caller that
---passes 9648.0 and one that passes 9648 agree on the same entry.
local function BiomeKey(X, Z)
	return math.floor(X) .. "," .. math.floor(Z)
end

---The biome at a block position: what the engine knows first, then what the caller
---supplied. The engine only reports biomes for chunks that are loaded, which is exactly the
---gap a caller with its own biome cache can fill. Returns nil when neither knows.
---
---The engine wins on purpose. A caller cannot override a chunk the server has actually
---generated, so a wrong table can only ever be ignored, never believed.
local function BiomeAt(World, Supplied, X, Z)
	local Biome = World:GetBiomeAt(X, Z)
	if (Biome >= 0) then
		return Biome
	end
	if (Supplied ~= nil) then
		local Given = Supplied[BiomeKey(X, Z)]
		if (type(Given) == "number") and (Given >= 0) then
			return Given
		end
	end
	return nil
end

---Read a village pool's AllowedBiomes from its cubeset. The cubeset is a Lua chunk and
---the engine executes it; here only the metadata field is read, with a pattern, so the
---plugin never runs world data as code.
function StructureLocate.LoadPoolBiomes(PrefabName)
	local Cached = PoolBiomeCache[PrefabName]
	if (Cached == "error") then
		return nil, "cannot read the cubeset of pool " .. PrefabName
	end
	if Cached then
		return Cached
	end
	local Separator = cFile:GetPathSeparator()
	local Path = "Prefabs" .. Separator .. "Villages" .. Separator .. PrefabName .. ".cubeset"
	local Contents = cFile:ReadWholeFile(Path)
	if ((Contents == nil) or (Contents == "")) then
		PoolBiomeCache[PrefabName] = "error"
		return nil, "cannot read " .. Path
	end
	-- A pool without AllowedBiomes accepts nothing, which is what cVillagePiecePool does:
	local AllowedStr = ReadCubesetValue(Contents, "AllowedBiomes") or ""
	local Allowed = {}
	for Entry in AllowedStr:gmatch("[^,]+") do
		local Biome = StringToBiome(Entry:match("^%s*(.-)%s*$"))
		if (Biome >= 0) then
			Allowed[Biome] = true
		end
	end
	PoolBiomeCache[PrefabName] = Allowed
	return Allowed
end

---Which village pool the engine would use, or nil plus the reason. Returns "rejected"
---when the biomes are known and no pool accepts them, which is a definite "no village".
---cVillageGen::CreateStructure keeps a pool only if ALL 256 biome columns of the origin
---chunk are allowed, then picks with cNoise(seed + 1000).
local function ResolveVillagePool(World, Cfg, OriginX, OriginZ, Supplied)
	local Ini = cIniFile()
	if not Ini:ReadFile(World:GetIniFileName()) then
		return nil, "cannot read world.ini"
	end
	local Prefabs = {}
	for Entry in Ini:GetValue("Generator", "VillagePrefabs", "PlainsVillage, SandVillage"):gmatch("[^,]+") do
		local Name = Entry:match("^%s*(.-)%s*$")
		if (Name ~= "") then
			Prefabs[#Prefabs + 1] = Name
		end
	end
	for _, Name in ipairs(Prefabs) do
		if (StructureLocate.LoadPoolBiomes(Name) == nil) then
			return nil, "没有 " .. Name .. " 的生态群系元数据"
		end
	end

	local ChunkX, ChunkZ = BlockToChunk(OriginX), BlockToChunk(OriginZ)
	local Columns = {}
	for Z = 0, CHUNK_W - 1 do
		for X = 0, CHUNK_W - 1 do
			local Biome = BiomeAt(World, Supplied, ChunkX * CHUNK_W + X, ChunkZ * CHUNK_W + Z)
			if (Biome == nil) then
				return nil, string.format("区块 (%d, %d) 的生态群系未知", ChunkX, ChunkZ)
			end
			Columns[#Columns + 1] = Biome
		end
	end

	local Available = {}
	for _, Name in ipairs(Prefabs) do
		local Allowed = PoolBiomeCache[Name]
		local Ok = true
		for _, Biome in ipairs(Columns) do
			if not Allowed[Biome] then
				Ok = false
				break
			end
		end
		if Ok then
			Available[#Available + 1] = Name
		end
	end
	if (#Available == 0) then
		return nil, "rejected"
	end
	local Rnd = math.floor(StructureLocate.IntNoise2DInt(Cfg.Seed + 1000, OriginX, OriginZ) / 11)
	return Available[Rnd % #Available + 1]
end


-- ===========================================================================
-- 6. Eligibility and position
-- ===========================================================================

---"yes", "no" or "unknown". Unknown means the engine cannot tell us, not that there is
---no structure - a village's 256 samples need the origin chunk loaded.
local function Eligibility(World, Kind, Cfg, OriginX, OriginZ, Supplied)
	if (Kind.Biome == "none") then
		return "yes", nil
	end
	if (Kind.Biome == "origin") then
		local Biome = BiomeAt(World, Supplied, OriginX, OriginZ)
		if (Biome == nil) then
			return "unknown", "原点区块的生态群系未知"
		end
		if Cfg.AllowedBiomes and Cfg.AllowedBiomes[Biome] then
			return "yes", nil
		end
		return "no", nil
	end
	local Pool, Err = ResolveVillagePool(World, Cfg, OriginX, OriginZ, Supplied)
	if (Pool ~= nil) then
		return "yes", Pool
	end
	if (Err == "rejected") then
		return "no", nil
	end
	return "unknown", Err
end

---The coordinates to report for a candidate.
local function Position(Kind, Cfg, OriginX, OriginZ)
	if (Kind.Position == "dirtroom") then
		local P1X, P2X, P1Z, P2Z, P1Y = StructureLocate.GetMineShaftDirtRoom(Cfg, OriginX, OriginZ)
		return math.floor((P1X + P2X) / 2), P1Y, math.floor((P1Z + P2Z) / 2)
	end
	return OriginX, UNKNOWN_Y, OriginZ
end


-- ===========================================================================
-- 7. Locate
-- ===========================================================================

---The block rectangle covered by a Java-style chunk window centred on a point.
local function ChunkWindow(X, Z, RadiusChunks)
	local ChunkX, ChunkZ = BlockToChunk(X), BlockToChunk(Z)
	return (ChunkX - RadiusChunks) * CHUNK_W,
		(ChunkZ - RadiusChunks) * CHUNK_W,
		(ChunkX + RadiusChunks) * CHUNK_W + CHUNK_W - 1,
		(ChunkZ + RadiusChunks) * CHUNK_W + CHUNK_W - 1
end

---A rectangle that would take too long to walk is refused rather than walked. Every grid
---cell costs two IntNoise2DInt calls plus the per-kind eligibility test, and both the
---noise and the village biome lookup are expensive, so this bounds a call rather than
---letting a caller ask for a rectangle the size of the world.
local MAX_CELLS = 20000

---Every instance of a kind whose reported position falls inside a block rectangle.
---Confirmed and unconfirmed instances come back separately so a caller can prefer the
---ones the engine can vouch for.
---@return table|nil Confirmed, table|nil Unconfirmed, table|nil Kind, string|nil Error
local function Collect(World, KindName, MinX, MinZ, MaxX, MaxZ, Supplied)
	local Kind = StructureLocate.Kinds[KindName]
	if (Kind == nil) then
		return nil, nil, nil, "badtype"
	end
	local Cfg, Err = StructureLocate.GetConfig(World, Kind)
	if (Cfg == nil) then
		return nil, nil, nil, Err
	end
	local CellsX = math.floor((MaxX - MinX) / Cfg.GridSizeX) + 3
	local CellsZ = math.floor((MaxZ - MinZ) / Cfg.GridSizeZ) + 3
	if (CellsX * CellsZ > MAX_CELLS) then
		return nil, nil, nil, string.format("范围过大：约 %d 个网格单元，上限 %d",
			CellsX * CellsZ, MAX_CELLS)
	end

	local Confirmed, Unconfirmed = {}, {}
	for _, Candidate in ipairs(StructureLocate.GetCandidates(Cfg, MinX, MaxX, MinZ, MaxZ)) do
		local PosX, PosY, PosZ = Position(Kind, Cfg, Candidate.OriginX, Candidate.OriginZ)
		if (PosX >= MinX) and (PosX <= MaxX) and (PosZ >= MinZ) and (PosZ <= MaxZ) then
			local Verdict, Detail =
				Eligibility(World, Kind, Cfg, Candidate.OriginX, Candidate.OriginZ, Supplied)
			if (Verdict ~= "no") then
				local Entry = { X = PosX, Y = PosY, Z = PosZ,
					OriginX = Candidate.OriginX, OriginZ = Candidate.OriginZ,
					Confirmed = (Verdict == "yes"), Detail = Detail }
				if (Entry.Confirmed) then
					Confirmed[#Confirmed + 1] = Entry
				else
					Unconfirmed[#Unconfirmed + 1] = Entry
				end
			end
		end
	end
	return Confirmed, Unconfirmed, Kind, nil
end

---The entry closest to (X, Z), with Distance filled in.
local function Closest(List, X, Z)
	local Best = nil
	for _, Entry in ipairs(List) do
		local DX, DZ = Entry.X - X, Entry.Z - Z
		Entry.Distance = math.sqrt(DX * DX + DZ * DZ)
		if (Best == nil) or (Entry.Distance < Best.Distance) then
			Best = Entry
		end
	end
	return Best
end

---Nearest instance of a kind, searched the way Java searches: a square of
---2 * SEARCH_CHUNKS + 1 chunks (201 x 201 with the default) centred on the chunk the
---caller is in. Only a structure whose reported position falls inside that square counts.
---
---A confirmed instance always wins over a closer unconfirmed one; an unconfirmed one is
---only returned when nothing confirmed turned up, with Confirmed = false and Detail
---explaining why the engine could not be asked.
---@param RadiusChunks number|nil   Defaults to SEARCH_CHUNKS.
---@return table|nil Result, string|nil Error
function StructureLocate.Locate(World, KindName, X, Z, RadiusChunks, Supplied)
	local MinX, MinZ, MaxX, MaxZ = ChunkWindow(X, Z, RadiusChunks or SEARCH_CHUNKS)
	local Confirmed, Unconfirmed, Kind, Err =
		Collect(World, KindName, MinX, MinZ, MaxX, MaxZ, Supplied)
	if (Err ~= nil) then
		return nil, Err
	end
	local Best = Closest(Confirmed, X, Z) or Closest(Unconfirmed, X, Z)
	if (Best ~= nil) then
		Best.Kind = Kind
	end
	return Best
end


-- ===========================================================================
-- 8. Cross-plugin API
-- ===========================================================================
--
-- Plugins do not share a Lua state - cPluginLua owns its own cLuaState - so another
-- plugin cannot reach StructureLocate directly. The only channel is
-- cPluginManager:CallPlugin(PluginName, FunctionName, ...), and it resolves FunctionName
-- with lua_getglobal, ie. as a plain global with no dotted path. That is why the exported
-- entry points below are top-level globals rather than fields of a table, and why they
-- carry the plugin's name as a prefix.
--
-- Cross-plugin values are copied between the two Lua states, which the APIDump limits to
-- "strings, numbers, bools, nils, API classes and simple tables ... functions cannot be
-- copied across plugins". A cWorld may be passed straight through; a callback may not.
--
-- A call to a plugin that is not loaded, or to a name that is not a function, returns no
-- values at all and logs "Function '<name>' not found". So a caller gets nil for both
-- "plugin missing" and "function missing", while a plugin that answers a refusal returns
-- one table with Ok = false. That difference is the point of the shape below: the API
-- always returns exactly one table when it was reached at all.

local API_VERSION = 3

---Version of this API. Callers can use it to tell a refusal from a capability gap.
---@return number
function StructureLocateAPIVersion()
	return API_VERSION
end

---Every structure type this plugin can locate, in a stable order.
---@return table Array of type names, as /locate spells them.
function StructureLocateKinds()
	local Names = {}
	for Name in pairs(StructureLocate.Kinds) do
		Names[#Names + 1] = Name
	end
	table.sort(Names)
	return Names
end

local function ApiRefuse(Message)
	return { Ok = false, Error = Message, ApiVersion = API_VERSION }
end

---Shared argument checks for the two finders. Returns a refusal, or nil when the
---arguments are usable.
local function ValidateFinder(World, KindName, X, Z)
	if (World == nil) or (World.GetSeed == nil) then
		return ApiRefuse("World must be a cWorld")
	end
	if (type(KindName) ~= "string") then
		return ApiRefuse("KindName must be a string naming a structure type")
	end
	if (type(X) ~= "number") or (type(Z) ~= "number") then
		return ApiRefuse("the coordinates must be numbers")
	end
	return nil
end

---Checks a caller-supplied biome table, if one was given.
local function ValidateBiomes(Biomes)
	if (Biomes == nil) then
		return nil
	end
	if (type(Biomes) ~= "table") then
		return ApiRefuse("Biomes must be a table keyed \"blockX,blockZ\", or nil")
	end
	return nil
end

---Turns an internal entry into the flat table the API hands out.
local function ToApiEntry(Entry, KindName, Display, RefX, RefZ)
	local DX, DZ = Entry.X - RefX, Entry.Z - RefZ
	return
	{
		Kind = KindName,
		Display = Display,
		X = Entry.X, Y = Entry.Y, Z = Entry.Z,
		Distance = math.sqrt(DX * DX + DZ * DZ),
		Confirmed = Entry.Confirmed,
		Detail = Entry.Detail,
		OriginX = Entry.OriginX, OriginZ = Entry.OriginZ,
	}
end

---Turns a Collect error into a refusal, so both finders report the same way.
local function RefuseCollectError(KindName, Err)
	if (Err == "badtype") then
		return ApiRefuse("Unknown structure type: " .. KindName)
	end
	return ApiRefuse(Err)
end

---Nearest structure of a kind, for another plugin.
---
---    local R = cPluginManager:CallPlugin("VanillaFeatureComplement", "StructureLocateFindNearest",
---        World, "Mineshaft", X, Z)
---    if (R == nil) then
---        -- the plugin, or the function, is not loaded
---    elseif (R.Ok) then
---        -- R.Kind, R.Display, R.X, R.Y, R.Z, R.Distance, R.Confirmed, R.OriginX, R.OriginZ
---    else
---        -- R.Error explains it: unknown type, not generated here, or nothing in range
---    end
---
---@param World cWorld
---@param KindName string   As /locate spells it; case sensitive.
---@param X number
---@param Z number
---@param RadiusChunks number|nil   Search window in chunks, defaulting to Java's 100.
---@param Biomes table|nil   Optional {["blockX,blockZ"] = biomeId} the plugin falls back
---                          to when the engine cannot answer for an unloaded chunk. The
---                          engine's own answer always wins.
---@return table Always exactly one table: {Ok = true, ...} or {Ok = false, Error = ...}.
function StructureLocateFindNearest(World, KindName, X, Z, RadiusChunks, Biomes)
	local Refusal = ValidateFinder(World, KindName, X, Z) or ValidateBiomes(Biomes)
	if (Refusal ~= nil) then
		return Refusal
	end
	if (RadiusChunks ~= nil) and (type(RadiusChunks) ~= "number") then
		return ApiRefuse("RadiusChunks must be a number of chunks, or nil")
	end

	local Result, Err = StructureLocate.Locate(World, KindName, X, Z, RadiusChunks, Biomes)
	if (Result == nil) then
		return RefuseCollectError(KindName, Err or ("Nothing found for " .. KindName))
	end

	local Out = ToApiEntry(Result, KindName, Result.Kind.Display, X, Z)
	Out.Ok = true
	Out.ApiVersion = API_VERSION
	return Out
end

---Every structure of a kind inside a block rectangle, nearest first.
---
---The rectangle is in blocks and inclusive. Distance is measured from (RefX, RefZ), which
---defaults to the centre of the rectangle, and that is also the sort order.
---
---Confirmation matters more here than for a nearest query: a large rectangle can reach
---structures whose origin chunk is not loaded, and those come back with Confirmed = false
---rather than being dropped, so the caller can decide. ConfirmedCount says how many of
---Count are confirmed, and the confirmed ones are not necessarily the first ones in
---Items once sorting by distance is applied.
---
---@param World cWorld
---@param KindName string
---@param MinX number
---@param MinZ number
---@param MaxX number
---@param MaxZ number
---@param RefX number|nil
---@param RefZ number|nil
---@param Biomes table|nil   Optional {["blockX,blockZ"] = biomeId} of caller-known biomes,
---                          used only where the engine cannot answer. The engine's own
---                          answer always wins, so a wrong table is ignored, never believed.
---@return table Always exactly one table: {Ok = true, Count, ConfirmedCount, Items, ...}
---              or {Ok = false, Error = ...}.
function StructureLocateFindAll(World, KindName, MinX, MinZ, MaxX, MaxZ, RefX, RefZ, Biomes)
	local Refusal = ValidateFinder(World, KindName, MinX, MinZ) or ValidateBiomes(Biomes)
	if (Refusal ~= nil) then
		return Refusal
	end
	if (type(MaxX) ~= "number") or (type(MaxZ) ~= "number") then
		return ApiRefuse("MaxX and MaxZ must be numbers")
	end
	if (MaxX < MinX) or (MaxZ < MinZ) then
		return ApiRefuse("the rectangle is empty: MaxX and MaxZ must not be below MinX and MinZ")
	end
	if (RefX == nil) then RefX = (MinX + MaxX) / 2 end
	if (RefZ == nil) then RefZ = (MinZ + MaxZ) / 2 end
	if (type(RefX) ~= "number") or (type(RefZ) ~= "number") then
		return ApiRefuse("RefX and RefZ must be numbers, or nil")
	end

	local Confirmed, Unconfirmed, Kind, Err =
		Collect(World, KindName, MinX, MinZ, MaxX, MaxZ, Biomes)
	if (Err ~= nil) then
		return RefuseCollectError(KindName, Err)
	end

	local Items = {}
	for _, Entry in ipairs(Confirmed) do
		Items[#Items + 1] = ToApiEntry(Entry, KindName, Kind.Display, RefX, RefZ)
	end
	for _, Entry in ipairs(Unconfirmed) do
		Items[#Items + 1] = ToApiEntry(Entry, KindName, Kind.Display, RefX, RefZ)
	end
	table.sort(Items, function(A, B) return A.Distance < B.Distance end)

	return
	{
		Ok = true,
		ApiVersion = API_VERSION,
		Kind = KindName,
		Display = Kind.Display,
		Count = #Items,
		ConfirmedCount = #Confirmed,
		RefX = RefX, RefZ = RefZ,
		MinX = MinX, MinZ = MinZ, MaxX = MaxX, MaxZ = MaxZ,
		Items = Items,
	}
end

-- 9. The /locate command
-- ===========================================================================

---The valid type names, in a stable order, for the usage message.
local function KindNames()
	local Names = {}
	for Name in pairs(StructureLocate.Kinds) do
		Names[#Names + 1] = Name
	end
	table.sort(Names)
	return Names
end

---The /locate reply as plain text, used by the console command and by the tests.
---    最近的废弃矿井位于 [6199, 20, 36]（距离 412 格）
local function FormatResult(Result)
	return string.format("最近的%s位于 [%d, %d, %d]（距离 %d 格）", Result.Kind.Display,
		Result.X, Result.Y, Result.Z, math.floor(Result.Distance + 0.5))
end

---Sends the /locate reply to a player. Java makes the coordinates clickable so that the
---teleport command lands in the chat box rather than being run outright, so the part is a
---suggest_command; Cuberite's self-teleport is /tp <x> <y> <z> (Core, core.teleport),
---where Java uses /teleport @s <x> <y> <z>.
local function SendResult(Player, Result)
	local Chat = cCompositeChat()
	if (mtInfo ~= nil) then
		Chat:SetMessageType(mtInfo)
	end
	Chat:AddTextPart(string.format("最近的%s位于 ", Result.Kind.Display))
	Chat:AddSuggestCommandPart(string.format("[%d, %d, %d]", Result.X, Result.Y, Result.Z),
		string.format("/tp %d %d %d", Result.X, Result.Y, Result.Z), "an")
	Chat:AddTextPart(string.format("（距离 %d 格）", math.floor(Result.Distance + 0.5)))
	Player:SendMessage(Chat)
end

---Handler for /locate <StructureType>.
---
---Like Java, the command takes the type and nothing else: the search starts at the
---executor's position, and there is no radius argument.
---@param Split table   Split[1] is the command, Split[2] the structure type.
---@param Player cPlayer
---@return boolean
function StructureLocate.Command(Split, Player)
	local TypeName = Split[2]
	if (TypeName == nil) then
		Player:SendMessageFailure("用法：/locate <结构类型>")
		Player:SendMessageInfo("结构类型：" .. table.concat(KindNames(), "、"))
		return true
	end
	-- Java's type names are case sensitive, and so is this:
	if (StructureLocate.Kinds[TypeName] == nil) then
		Player:SendMessageFailure("未知的结构类型：" .. TypeName)
		Player:SendMessageInfo("结构类型：" .. table.concat(KindNames(), "、"))
		return true
	end

	local World = Player:GetWorld()
	local Result, Err = StructureLocate.Locate(World, TypeName,
		math.floor(Player:GetPosX()), math.floor(Player:GetPosZ()))
	if (Result == nil) then
		if (Err ~= nil) then
			Player:SendMessageFailure(Err)
		else
			Player:SendMessageFailure(string.format("在 %d 个区块（%d x %d）内无法找到%s",
				SEARCH_CHUNKS, 2 * SEARCH_CHUNKS + 1, 2 * SEARCH_CHUNKS + 1,
				StructureLocate.Kinds[TypeName].Display))
		end
		return true
	end
	SendResult(Player, Result)
	if (not Result.Confirmed) then
		Player:SendMessageInfo("这是一处候选位置（" .. tostring(Result.Detail)
			.. "）。走到附近再试一次即可确认。")
	end
	return true
end

---Handler for the console command
---"locate <StructureType> <x> <z> [radius-in-chunks] [world]".
---@param Split table
---@return boolean
function StructureLocate.ConsoleCommand(Split)
	local TypeName = Split[2]
	local X, Z = tonumber(Split[3]), tonumber(Split[4])
	if (TypeName ~= nil) and (StructureLocate.Kinds[TypeName] == nil) then
		LOG("locate: 未知的结构类型 " .. TypeName)
	end
	if (StructureLocate.Kinds[TypeName] == nil) or (X == nil) or (Z == nil) then
		LOG("用法：locate <结构类型> <x> <z> [radius] [world]")
		LOG("结构类型：" .. table.concat(KindNames(), " "))
		return true
	end

	local World = cRoot:Get():GetDefaultWorld()
	if (Split[6] ~= nil) and (Split[6] ~= "") then
		World = cRoot:Get():GetWorld(Split[6])
	end
	if (World == nil) then
		LOG("locate: no such world")
		return true
	end

	local Result, Err = StructureLocate.Locate(World, TypeName, X, Z, tonumber(Split[5]))
	if (Result == nil) then
		LOG("locate: " .. tostring(Err
			or ("在 " .. SEARCH_CHUNKS .. " 个区块内无法找到"
				.. StructureLocate.Kinds[TypeName].Display)))
		return true
	end
	LOG("locate: world=" .. World:GetName() .. " " .. FormatResult(Result))
	LOG(string.format("locate: grid origin (%d, %d), confirmed=%s%s", Result.OriginX,
		Result.OriginZ, tostring(Result.Confirmed),
		Result.Detail and (" (" .. tostring(Result.Detail) .. ")") or ""))
	return true
end
