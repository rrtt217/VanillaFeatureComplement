-- village_locate.lua
--
-- Locate villages -- and village *candidates* -- without touching the generator.
--
-- Nothing in the bound API describes structures: cChunkDesc has no structure list,
-- the chunk hooks carry only (World, ChunkX, ChunkZ, ChunkDesc), and cPrefab /
-- cPieceGenerator / cNoise are not bound at all. What the engine does give us is a
-- fully deterministic placement algorithm, reimplemented here bit-exactly:
--
--   * cGridStructGen puts at most one structure into each GridSize x GridSize cell.
--     A cell's origin is derived from the cell point with cNoise::IntNoise2DInt
--     (Generating/GridStructGen.cpp, GetStructuresForChunk):
--         OriginX = GridX + (IntNoise2DInt(GridX + 3, GridZ + 5) / 7) % (2 * MaxOffsetX) - MaxOffsetX
--         OriginZ = GridZ + (IntNoise2DInt(GridX + 5, GridZ + 3) / 7) % (2 * MaxOffsetZ) - MaxOffsetZ
--     GridX / GridZ are the cell *points* (multiples of GridSize), not cell indices.
--
--   * cVillageGen turns a cell into a village only if *every* biome column of the
--     origin's chunk is allowed by one of the loaded village pools, and then picks
--     the pool with cNoise(seed + 1000) (Generating/VillageGen.cpp, CreateStructure):
--         Available = pools whose AllowedBiomes accept all 256 biomes of the origin chunk
--         Pool      = Available[(IntNoise2DInt(seed + 1000, OriginX, OriginZ) / 11) % #Available]
--     The starting piece is placed at the origin, so a village always has structure
--     within MaxSize blocks of the coords returned here.
--
-- Villages never apply a cubeset SeedOffset: cGridStructGen::SetGeneratorParams()
-- is the only place that adds SeedOffset to the seed, and it is called by the
-- SinglePieceStructures and PieceStructures generators only. The village grid
-- therefore runs on the plain world seed.
--
-- IntNoise2DInt is declared inline in Noise/Noise.h and is not bound, so it is
-- ported below, 32-bit wraparound included. That is the part a naive Lua port gets
-- wrong: Lua 5.1 has only doubles, and n * n * 15731 overflows the 53-bit
-- exact-integer range, so the multiply has to be split into 16-bit halves.

VillageLocate = {}

local TWO_31   = 2147483648
local TWO_32   = 4294967296
local CHUNK_W  = 16

-- Engine defaults, used when world.ini has no explicit value. The engine writes
-- these out itself (cIniFile::GetValueSetI), so they are normally present.
local DEFAULT_GRID_SIZE   = 384
local DEFAULT_MAX_OFFSET  = 128
local DEFAULT_MAX_SIZE    = 128
local DEFAULT_PREFABS     = "PlainsVillage, SandVillage"


-- ===========================================================================
-- 1. 32-bit arithmetic (Lua 5.1 has no bitwise operators and no integers)
-- ===========================================================================

---Bitwise XOR of two 32-bit unsigned values.
---@param a number
---@param b number
---@return number
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

---Exact low 32 bits of a * b, for unsigned 32-bit a and b.
---The operands are split into 16-bit halves so that every intermediate value stays
---below 2^53 and doubles remain exact.
---@param a number
---@param b number
---@return number
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
---The engine computes grid indices this way (GetStructuresForChunk), and the two
---differ for negative input, which is common: MinBlockX / GridSize with a negative
---MinBlockX.
---@param a number
---@param b number
---@return number
local function DivC(a, b)
	local Quotient = a / b
	if (Quotient >= 0) then
		return math.floor(Quotient)
	end
	return math.ceil(Quotient)
end

---cChunkDef::BlockToChunk for one axis (an arithmetic shift, ie. floor).
---@param a number
---@return number
local function BlockToChunk(a)
	return math.floor(a / CHUNK_W)
end

---Bitwise XOR; exposed for the test suite.
---@param a number
---@param b number
---@return number
VillageLocate.BXor32 = BXor32

---Exact low 32 bits of a * b; exposed for the test suite.
---@param a number
---@param b number
---@return number
VillageLocate.Mul32 = Mul32


-- ===========================================================================
-- 2. cNoise::IntNoise2DInt
-- ===========================================================================

---Exact port of cNoise::IntNoise2DInt() (src/Noise/Noise.h).
---
---    int n = a_X + a_Y * 57 + m_Seed * 57 * 57;
---    n = (n << 13) ^ n;
---    return ((n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff);
---
---Every operation wraps as a 32-bit integer, and the result is the low 31 bits, so
---it is always non-negative.
---@param Seed number    The cNoise seed (m_Seed).
---@param X number
---@param Y number
---@return number
function VillageLocate.IntNoise2DInt(Seed, X, Y)
	-- 57 * 57 = 3249. X + Y * 57 + Seed * 3249 stays well inside 2^53, so this
	-- expression needs no 16-bit split.
	local n = (X + Y * 57 + Seed * 3249) % TWO_32
	n = BXor32(Mul32(n, 8192), n)                              -- n = (n << 13) ^ n
	local Inner = (Mul32(Mul32(n, n), 15731) + 789221) % TWO_32
	return (Mul32(n, Inner) + 1376312589) % TWO_31             -- ... & 0x7fffffff
end


-- ===========================================================================
-- 3. Generator configuration
-- ===========================================================================

---Read the village finisher parameters from a world's world.ini.
---@param World cWorld
---@return table|nil Cfg, string|nil Error
function VillageLocate.GetGeneratorConfig(World)
	local IniPath = World:GetIniFileName()
	local Ini = cIniFile()
	if not Ini:ReadFile(IniPath) then
		return nil, "cannot read " .. tostring(IniPath)
	end

	-- The finisher list is "Name" or "Name: params", comma separated.
	local HasVillages = false
	local Finishers = Ini:GetValue("Generator", "Finishers", "")
	for Entry in Finishers:gmatch("[^,]+") do
		local Name = Entry:match("^%s*(.-)%s*$")
		if (Name:lower() == "villages") then
			HasVillages = true
			break
		end
	end
	if not HasVillages then
		return nil, "the Villages finisher is not enabled in " .. tostring(IniPath)
	end

	local Cfg =
	{
		Seed      = World:GetSeed(),
		IniPath   = IniPath,
		GridSize  = Ini:GetValueI("Generator", "VillageGridSize",   DEFAULT_GRID_SIZE),
		MaxOffset = Ini:GetValueI("Generator", "VillageMaxOffset",  DEFAULT_MAX_OFFSET),
		MaxSize   = Ini:GetValueI("Generator", "VillageMaxSize",    DEFAULT_MAX_SIZE),
	}
	-- The engine silently bumps a zero grid size to 1 (cGridStructGen ctor).
	if (Cfg.GridSize == 0) then
		Cfg.GridSize = 1
	end
	if (Cfg.MaxOffset == 0) then
		Cfg.MaxOffset = 1
	end

	-- Pool names, in the order the generator keeps them: cVillageGen stores one pool
	-- per entry of VillagePrefabs, and CreateStructure indexes that same list.
	Cfg.Prefabs = {}
	local PrefabList = Ini:GetValue("Generator", "VillagePrefabs", DEFAULT_PREFABS)
	for Entry in PrefabList:gmatch("[^,]+") do
		local Name = Entry:match("^%s*(.-)%s*$")
		if (Name ~= "") then
			Cfg.Prefabs[#Cfg.Prefabs + 1] = Name
		end
	end

	-- Per-pool allowed biomes, read from the pool's cubeset (see section 5).
	Cfg.PoolBiomes = {}
	Cfg.PoolError = nil
	for _, Name in ipairs(Cfg.Prefabs) do
		local Allowed, Err = VillageLocate.LoadPoolBiomes(Name)
		if Allowed then
			Cfg.PoolBiomes[Name] = Allowed
		else
			Cfg.PoolError = Err
		end
	end

	return Cfg
end


-- ===========================================================================
-- 4. Cell geometry
-- ===========================================================================

---The origin the engine would use for the given grid cell point.
---@param Seed number
---@param Cfg table
---@param CellX number   GridX, a multiple of Cfg.GridSize
---@param CellZ number   GridZ, a multiple of Cfg.GridSize
---@return number OriginX, number OriginZ
function VillageLocate.GetCellOrigin(Seed, Cfg, CellX, CellZ)
	local OffsetRange = Cfg.MaxOffset * 2
	-- (IntNoise2DInt(a, b) / 7) % (2 * MaxOffset), kept in a local only to stay
	-- inside the line-length budget.
	local OffsetX = math.floor(VillageLocate.IntNoise2DInt(Seed, CellX + 3, CellZ + 5) / 7) % OffsetRange
	local OffsetZ = math.floor(VillageLocate.IntNoise2DInt(Seed, CellX + 5, CellZ + 3) / 7) % OffsetRange
	local OriginX = CellX + OffsetX - Cfg.MaxOffset
	local OriginZ = CellZ + OffsetZ - Cfg.MaxOffset
	return OriginX, OriginZ
end

---Every grid cell whose structure may intersect the given block rectangle.
---Mirrors cGridStructGen::GetStructuresForChunk, generalised from one chunk to an
---arbitrary rectangle. A structure's bounding box is m_MaxStructureSize around the
---cell point; the origin can be m_MaxOffset further out again.
---@param Cfg table
---@param MinX number
---@param MaxX number
---@param MinZ number
---@param MaxZ number
---@return table Array of { CellX, CellZ, OriginX, OriginZ }
function VillageLocate.GetCandidates(Cfg, MinX, MaxX, MinZ, MaxZ)
	local Reach = Cfg.MaxSize + Cfg.MaxOffset
	local MinGridX = DivC(MinX - Reach, Cfg.GridSize)
	local MaxGridX = DivC(MaxX + Reach + Cfg.GridSize - 1, Cfg.GridSize)
	local MinGridZ = DivC(MinZ - Reach, Cfg.GridSize)
	local MaxGridZ = DivC(MaxZ + Reach + Cfg.GridSize - 1, Cfg.GridSize)

	local Result = {}
	for CellXi = MinGridX, MaxGridX - 1 do
		local CellX = CellXi * Cfg.GridSize
		for CellZi = MinGridZ, MaxGridZ - 1 do
			local CellZ = CellZi * Cfg.GridSize
			local OriginX, OriginZ = VillageLocate.GetCellOrigin(Cfg.Seed, Cfg, CellX, CellZ)
			Result[#Result + 1] =
			{
				CellX   = CellX,
				CellZ   = CellZ,
				OriginX = OriginX,
				OriginZ = OriginZ,
			}
		end
	end
	return Result
end

---Village candidates whose origin lies within Radius blocks of (X, Z), nearest first.
---Note the distance is to the *origin*; the village itself extends up to
---Cfg.MaxSize blocks further out in every direction.
---@param Cfg table
---@param X number
---@param Z number
---@param Radius number
---@param MaxCount number
---@return table
function VillageLocate.FindNear(Cfg, X, Z, Radius, MaxCount)
	local Found = {}
	for _, Candidate in ipairs(VillageLocate.GetCandidates(Cfg, X - Radius, X + Radius, Z - Radius, Z + Radius)) do
		local DX = Candidate.OriginX - X
		local DZ = Candidate.OriginZ - Z
		local Distance = math.sqrt(DX * DX + DZ * DZ)
		if (Distance <= Radius) then
			Candidate.Distance = Distance
			Found[#Found + 1] = Candidate
		end
	end
	table.sort(Found, function(a, b) return a.Distance < b.Distance end)
	while (#Found > MaxCount) do
		table.remove(Found)
	end
	return Found
end


-- ===========================================================================
-- 5. Pool resolution (which village, if any)
-- ===========================================================================

---Allowed-biome sets per pool, keyed by pool (cubeset) name. The cubesets are
---static data, so this is cached for the lifetime of the plugin.
local PoolBiomeCache = {}

---Read a village pool's AllowedBiomes from its cubeset.
---
---The cubeset is a Lua chunk and the engine executes it; here only the metadata
---field is read, with a pattern, so that the plugin never runs world data as code.
---Gzipped cubesets (".cubeset.gz") are not supported -- cFile cannot decompress.
---@param PrefabName string
---@return table|nil Allowed, string|nil Error
function VillageLocate.LoadPoolBiomes(PrefabName)
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

	local AllowedStr = Contents:match('%[%s*"AllowedBiomes"%s*%]%s*=%s*"([^"]*)"')
	if (AllowedStr == nil) then
		-- A pool without AllowedBiomes accepts nothing (cVillagePiecePool gets its
		-- biome set from this field alone), so an empty set is the faithful answer.
		AllowedStr = ""
	end

	local Allowed = {}
	for Entry in AllowedStr:gmatch("[^,]+") do
		local BiomeName = Entry:match("^%s*(.-)%s*$")
		if (BiomeName ~= "") then
			local Biome = StringToBiome(BiomeName)
			if (Biome >= 0) then
				Allowed[Biome] = true
			end
		end
	end
	PoolBiomeCache[PrefabName] = Allowed
	return Allowed
end

---Which pool the engine would use for this origin, or nil plus the reason it cannot
---be told.
---
---The pool filter needs all 256 biomes of the origin's chunk, and the engine only
---reports biomes for *loaded* chunks: cChunkMap::GetBiomeAt returns biInvalidBiome
---(-1) for anything else, despite what the APIDoc claims. An unloaded origin chunk
---therefore yields "unknown", never a guess.
---@param World cWorld
---@param Cfg table
---@param OriginX number
---@param OriginZ number
---@return string|nil PoolName, string|nil Error
function VillageLocate.ResolvePool(World, Cfg, OriginX, OriginZ)
	if (Cfg.PoolError ~= nil) then
		return nil, Cfg.PoolError
	end
	if (#Cfg.Prefabs == 0) then
		return nil, "no village prefabs configured"
	end
	for _, Name in ipairs(Cfg.Prefabs) do
		if (Cfg.PoolBiomes[Name] == nil) then
			return nil, "no biome metadata for pool " .. Name
		end
	end

	local ChunkX = BlockToChunk(OriginX)
	local ChunkZ = BlockToChunk(OriginZ)
	local Biomes = {}
	for Z = 0, CHUNK_W - 1 do
		for X = 0, CHUNK_W - 1 do
			local Biome = World:GetBiomeAt(ChunkX * CHUNK_W + X, ChunkZ * CHUNK_W + Z)
			if (Biome < 0) then
				return nil, string.format("chunk (%d, %d) is not loaded", ChunkX, ChunkZ)
			end
			Biomes[#Biomes + 1] = Biome
		end
	end

	-- cVillageGen::CreateStructure drops every pool that does not allow all 256 columns.
	local Available = {}
	for _, Name in ipairs(Cfg.Prefabs) do
		local Allowed = Cfg.PoolBiomes[Name]
		local Ok = true
		for _, Biome in ipairs(Biomes) do
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
		return nil, "no pool accepts every biome of the origin chunk"
	end

	local Rnd = math.floor(VillageLocate.IntNoise2DInt(Cfg.Seed + 1000, OriginX, OriginZ) / 11)
	return Available[Rnd % #Available + 1]
end


-- ===========================================================================
-- 6. Reporting helpers
-- ===========================================================================

---Human-readable one-line description of a candidate, resolving the pool if the
---origin chunk is loaded.
---@param World cWorld
---@param Cfg table
---@param Candidate table
---@return string
function VillageLocate.Describe(World, Cfg, Candidate)
	local Pool, Err = VillageLocate.ResolvePool(World, Cfg, Candidate.OriginX, Candidate.OriginZ)
	if (Pool ~= nil) then
		return string.format("village %s, origin (%d, %d)", Pool, Candidate.OriginX, Candidate.OriginZ)
	end
	if (Err:find("no pool accepts", 1, true)) then
		return string.format("no village, origin (%d, %d)", Candidate.OriginX, Candidate.OriginZ)
	end
	return string.format("candidate, origin (%d, %d) -- %s", Candidate.OriginX, Candidate.OriginZ, Err)
end


-- ===========================================================================
-- 7. Player command
-- ===========================================================================

local DEFAULT_COMMAND_RADIUS = 1024
local MAX_COMMAND_RESULTS   = 5

---Handler for the /villages command.
---@param Split table    Split[1] is the command, Split[2] an optional radius.
---@param Player cPlayer
---@return boolean
function VillageLocate.Command(Split, Player)
	local World = Player:GetWorld()
	local Cfg, Err = VillageLocate.GetGeneratorConfig(World)
	if (Cfg == nil) then
		Player:SendMessageFailure("Village detection: " .. Err)
		return true
	end

	local Radius = tonumber(Split[2]) or DEFAULT_COMMAND_RADIUS
	if (Radius <= 0) then
		Player:SendMessageFailure("Village detection: the radius must be positive.")
		return true
	end

	local X = math.floor(Player:GetPosX())
	local Z = math.floor(Player:GetPosZ())
	local Found = VillageLocate.FindNear(Cfg, X, Z, Radius, MAX_COMMAND_RESULTS)
	if (#Found == 0) then
		Player:SendMessageInfo(string.format("No village grid cell within %d blocks of (%d, %d).",
			Radius, X, Z))
		return true
	end

	-- Candidates are exact; the village type is only known once the origin chunk is
	-- loaded, because that is the only time the engine reports its biomes.
	Player:SendMessageInfo(string.format("Village candidates within %d blocks of (%d, %d), nearest first:",
		Radius, X, Z))
	for _, Candidate in ipairs(Found) do
		Player:SendMessageInfo(string.format("  %d blocks away: %s",
			math.floor(Candidate.Distance + 0.5), VillageLocate.Describe(World, Cfg, Candidate)))
	end
	return true
end


---Handler for the console command "villages":
---    villages <x> <z> [radius] [world]
---Exists mainly so that the detection can be checked from the server console (and so
---from automated verification), without a player to run /villages.
---@param Split table   Split[1] is the command name.
---@return boolean
function VillageLocate.ConsoleCommand(Split)
	local X = tonumber(Split[2])
	local Z = tonumber(Split[3])
	if (X == nil) or (Z == nil) then
		LOG("Usage: villages <x> <z> [radius] [world]")
		return true
	end
	local Radius = tonumber(Split[4]) or DEFAULT_COMMAND_RADIUS

	local World = cRoot:Get():GetDefaultWorld()
	if (Split[5] ~= nil) and (Split[5] ~= "") then
		World = cRoot:Get():GetWorld(Split[5])
	end
	if (World == nil) then
		LOG("villages: no such world")
		return true
	end

	local Cfg, Err = VillageLocate.GetGeneratorConfig(World)
	if (Cfg == nil) then
		LOG("villages: " .. Err)
		return true
	end
	LOG(string.format("villages: world=%s seed=%d grid=%d maxOffset=%d maxSize=%d prefabs=%s",
		World:GetName(), Cfg.Seed, Cfg.GridSize, Cfg.MaxOffset, Cfg.MaxSize, table.concat(Cfg.Prefabs, ",")))
	if (Cfg.PoolError ~= nil) then
		LOG("villages: pool metadata problem -- " .. Cfg.PoolError)
	end

	local Found = VillageLocate.FindNear(Cfg, X, Z, Radius, 20)
	LOG(string.format("villages: %d candidate(s) within %d blocks of (%d, %d)",
		#Found, Radius, X, Z))
	for _, Candidate in ipairs(Found) do
		LOG(string.format("  d=%d cell=(%d,%d) %s", math.floor(Candidate.Distance + 0.5),
			Candidate.CellX, Candidate.CellZ, VillageLocate.Describe(World, Cfg, Candidate)))
	end
	return true
end
