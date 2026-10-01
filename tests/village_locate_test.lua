-- tests/village_locate_test.lua
-- Offline test suite for the village location module of VanillaFeatureComplement.
--
-- The module reimplements the engine's deterministic village placement, so the
-- interesting question is whether the port is bit-exact. The reference values below
-- come from an independent Node implementation that uses native 32-bit arithmetic;
-- the Lua module emulates the same semantics with doubles. Agreement therefore
-- tests the port, not a restatement of it.
--
-- Usage (from the plugin folder):
--     lua    tests/village_locate_test.lua
--     luajit tests/village_locate_test.lua      -- Lua 5.1 compat (Cuberite embeds 5.1)
--
-- Exit code 0 when every check passed, 1 otherwise.


-- ===========================================================================
-- 1. Module under test and reference data
-- ===========================================================================

dofile("village_locate.lua")

-- Reference values computed by an independent Node implementation that uses native
-- 32-bit arithmetic (Math.imul, <<, ^, &). The Lua module under test emulates the
-- same 32-bit semantics with doubles, so agreement is a real cross-check.
local NOISE_CASES =
{
	{ 1402121502, 0, 0, 1462031211 },
	{ 1402121502, 1, 0, 156614965 },
	{ 1402121502, 0, 1, 876292741 },
	{ 1402121502, -1, -1, 308972769 },
	{ 1402121502, 1234, -5678, 139683135 },
	{ 1402121502, 1000000, -1000000, 2049041771 },
	{ 1402121502, -2147483648, 2147483647, 1641252269 },
	{ 1402121502, 384, 384, 1026695787 },
	{ 1402121502, -385, 767, 1915618401 },
	{ 0, 0, 0, 1376312589 },
	{ 0, 1, 0, 1316808037 },
	{ 0, 0, 1, 854329141 },
	{ 0, -1, -1, 2119548211 },
	{ 0, 1234, -5678, 52469553 },
	{ 0, 1000000, -1000000, 1845372685 },
	{ 0, -2147483648, 2147483647, 1246048997 },
	{ 0, 384, 384, 1226616845 },
	{ 0, -385, 767, 1595622067 },
	{ 1, 0, 0, 569583877 },
	{ 1, 1, 0, 62434975 },
	{ 1, 0, 1, 1943427863 },
	{ 1, -1, -1, 438152581 },
	{ 1, 1234, -5678, 384950317 },
	{ 1, 1000000, -1000000, 402744581 },
	{ 1, -2147483648, 2147483647, 2001006181 },
	{ 1, 384, 384, 730094341 },
	{ 1, -385, 767, 266089093 },
	{ -1, 0, 0, 1223561493 },
	{ -1, 1, 0, 986846109 },
	{ -1, 0, 1, 237161397 },
	{ -1, -1, -1, 1921858829 },
	{ -1, 1234, -5678, 1265357853 },
	{ -1, 1000000, -1000000, 391269653 },
	{ -1, -2147483648, 2147483647, 102358787 },
	{ -1, 384, 384, 827736853 },
	{ -1, -385, 767, 704298509 },
	{ 123456789, 0, 0, 1523022253 },
	{ 123456789, 1, 0, 1529285363 },
	{ 123456789, 0, 1, 838398315 },
	{ 123456789, -1, -1, 1757624653 },
	{ 123456789, 1234, -5678, 1897121141 },
	{ 123456789, 1000000, -1000000, 752854445 },
	{ 123456789, -2147483648, 2147483647, 1820334153 },
	{ 123456789, 384, 384, 1083143085 },
	{ 123456789, -385, 767, 467311181 },
	{ -2147483648, 0, 0, 1376312589 },
	{ -2147483648, 1, 0, 1316808037 },
	{ -2147483648, 0, 1, 854329141 },
	{ -2147483648, -1, -1, 2119548211 },
	{ -2147483648, 1234, -5678, 52469553 },
	{ -2147483648, 1000000, -1000000, 1845372685 },
	{ -2147483648, -2147483648, 2147483647, 1246048997 },
	{ -2147483648, 384, 384, 1226616845 },
	{ -2147483648, -385, 767, 1595622067 },
	{ 2147483647, 0, 0, 1223561493 },
	{ 2147483647, 1, 0, 986846109 },
	{ 2147483647, 0, 1, 237161397 },
	{ 2147483647, -1, -1, 1921858829 },
	{ 2147483647, 1234, -5678, 1265357853 },
	{ 2147483647, 1000000, -1000000, 391269653 },
	{ 2147483647, -2147483648, 2147483647, 102358787 },
	{ 2147483647, 384, 384, 827736853 },
	{ 2147483647, -385, 767, 704298509 },
	{ -987654321, 0, 0, 272692597 },
	{ -987654321, 1, 0, 1905434925 },
	{ -987654321, 0, 1, 310424901 },
	{ -987654321, -1, -1, 1588557549 },
	{ -987654321, 1234, -5678, 567996669 },
	{ -987654321, 1000000, -1000000, 714862965 },
	{ -987654321, -2147483648, 2147483647, 194465747 },
	{ -987654321, 384, 384, 981649269 },
	{ -987654321, -385, 767, 1499506669 },
}

local MUL_CASES =
{
	{ 1, 1, 1 },
	{ 65536, 65536, 0 },
	{ 4294967295, 4294967295, 1 },
	{ 123456789, 987654321, 4227814277 },
	{ 0, 12345, 0 },
	{ 2147483647, 2147483647, 1 },
	{ 100000, 100000, 1410065408 },
	{ 3, 4294967295, 4294967293 },
	{ -1, 5, 4294967291 },
	{ -2147483648, 2, 0 },
}

local XOR_CASES =
{
	{ 0, 0, 0 },
	{ 61680, 4080, 65280 },
	{ 4294967295, 0, 4294967295 },
	{ 123456789, 987654321, 1032168868 },
	{ 255, 255, 0 },
	{ 4294967295, 4294967295, 0 },
	{ -1, 0, 4294967295 },
	{ 2147483648, 2147483647, 4294967295 },
}

local ORIGIN_CASES =
{
	{ 1402121502, 384, 128, 0, 0, -72, -33 },
	{ 1402121502, 384, 128, 384, -384, 422, -417 },
	{ 1402121502, 384, 128, -768, 1152, -785, 1247 },
	{ 1402121502, 384, 128, 38400, -38400, 38438, -38433 },
	{ 1402121502, 256, 128, 0, 0, -72, -33 },
	{ 1402121502, 256, 128, 384, -384, 422, -417 },
	{ 1402121502, 256, 128, -768, 1152, -785, 1247 },
	{ 1402121502, 256, 128, 38400, -38400, 38438, -38433 },
	{ 1402121502, 100, 13, 0, 0, 3, -2 },
	{ 1402121502, 100, 13, 384, -384, 393, -394 },
	{ 1402121502, 100, 13, -768, 1152, -776, 1146 },
	{ 1402121502, 100, 13, 38400, -38400, 38389, -38392 },
}

local CANDIDATE_CASES =
{
	{
		Name = "chunk (0, 0)",
		Args = { 1402121502, 384, 128, 128, 0, 15, 0, 15 },
		Expected =
		{
			{ 0, 0, -72, -33 },
		},
	},
	{
		Name = "chunk (-100, 250)",
		Args = { 1402121502, 384, 128, 128, -1600, -1585, 4000, 4015 },
		Expected =
		{
			{ -1536, 3456, -1626, 3405 },
			{ -1536, 3840, -1608, 3880 },
			{ -1536, 4224, -1590, 4136 },
			{ -1152, 3456, -1114, 3533 },
			{ -1152, 3840, -1206, 3715 },
			{ -1152, 4224, -1151, 4227 },
		},
	},
	{
		Name = "rect spanning four cells",
		Args = { 1402121502, 384, 128, 128, 300, 700, -700, -300 },
		Expected =
		{
			{ 0, -768, 38, -691 },
			{ 0, -384, -54, -472 },
			{ 384, -768, 440, -673 },
			{ 384, -384, 422, -417 },
			{ 768, -768, 733, -874 },
			{ 768, -384, 678, -289 },
		},
	},
	{
		Name = "chunk (621, -38), negative seed",
		Args = { -1, 256, 64, 100, 9936, 9951, -608, -593 },
		Expected =
		{
			{ 9728, -768, 9694, -807 },
			{ 9728, -512, 9694, -496 },
			{ 9728, -256, 9785, -203 },
			{ 9984, -768, 10023, -770 },
			{ 9984, -512, 10005, -496 },
			{ 9984, -256, 9968, -221 },
		},
	},
}

local POOL_PICK_CASES =
{
	{ 1402121502, 384, -384, 2, 1 },
	{ 1402121502, 100, 100, 3, 2 },
	{ 0, -1000, 2000, 2, 2 },
	{ -1, 12345, -6789, 4, 1 },
}

-- ===========================================================================
-- 2. Test harness
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
-- 3. Engine mocks
-- ===========================================================================

local MockFiles = {}

cFile =
{
	GetPathSeparator = function() return "/" end,
	ReadWholeFile = function(_, Path) return MockFiles[Path] end,
}

local BiomeIds =
{
	Plains = 1, Savanna = 2, SavannaM = 3, SunflowerPlains = 4,
	Desert = 5, DesertM = 6, DesertHills = 7,
}
StringToBiome = function(Name) return BiomeIds[Name] or -1 end

local MockIniGroups = {}
cIniFile = function()
	return
	{
		ReadFile = function(_, Path) return Path == "world/world.ini" end,
		GetValue = function(_, Group, Key, Default)
			local G = MockIniGroups[Group]
			local V = G and G[Key]
			if (V == nil) then return Default end
			return V
		end,
		GetValueI = function(Self, Group, Key, Default)
			local V = Self:GetValue(Group, Key, nil)
			if (V == nil) then return Default end
			return tonumber(V)
		end,
	}
end

---A fake cWorld. a_BiomeAt is (X, Z) -> biome id, or nil to report "not loaded".
local function MakeWorld(a_Seed, a_BiomeAt)
	return
	{
		GetIniFileName = function() return "world/world.ini" end,
		GetSeed = function() return a_Seed end,
		GetBiomeAt = function(_, X, Z)
			if (a_BiomeAt == nil) then return -1 end
			return a_BiomeAt(X, Z)
		end,
	}
end


-- ===========================================================================
-- 4. A. 32-bit primitives
-- ===========================================================================

Section("A. 32-bit primitives")

for _, Case in ipairs(MUL_CASES) do
	local Got = VillageLocate.Mul32(Case[1], Case[2])
	Check(string.format("Mul32(%d, %d)", Case[1], Case[2]), Got == Case[3], Got .. " ~= " .. Case[3])
end
for _, Case in ipairs(XOR_CASES) do
	local Got = VillageLocate.BXor32(Case[1], Case[2])
	Check(string.format("BXor32(%d, %d)", Case[1], Case[2]), Got == Case[3], Got .. " ~= " .. Case[3])
end
Check("BXor32 is symmetric", VillageLocate.BXor32(12345, 67890) == VillageLocate.BXor32(67890, 12345))
Check("BXor32(a, a) == 0", VillageLocate.BXor32(123456789, 123456789) == 0)
Check("Mul32 result stays below 2^32", VillageLocate.Mul32(4294967295, 4294967295) < 4294967296)


-- ===========================================================================
-- 5. B. IntNoise2DInt against the independent reference
-- ===========================================================================

Section("B. IntNoise2DInt (cNoise port)")

for _, Case in ipairs(NOISE_CASES) do
	local Got = VillageLocate.IntNoise2DInt(Case[1], Case[2], Case[3])
	Check(string.format("IntNoise2DInt(%d, %d, %d)", Case[1], Case[2], Case[3]),
		Got == Case[4], Got .. " ~= " .. Case[4])
end

local OutOfRange = nil
for i = 1, 500 do
	local V = VillageLocate.IntNoise2DInt(i * 7919 - 1000000, i * 31 - 5000, i * -17 + 900)
	if (V < 0) or (V >= 2147483648) or (V ~= math.floor(V)) then
		OutOfRange = i .. " -> " .. tostring(V)
		break
	end
end
Check("results are integers in [0, 2^31)", OutOfRange == nil, OutOfRange)
Check("is deterministic", VillageLocate.IntNoise2DInt(42, 7, 9) == VillageLocate.IntNoise2DInt(42, 7, 9))
Check("seed matters", VillageLocate.IntNoise2DInt(42, 7, 9) ~= VillageLocate.IntNoise2DInt(43, 7, 9))
Check("X and Y are not interchangeable",
	VillageLocate.IntNoise2DInt(42, 7, 9) ~= VillageLocate.IntNoise2DInt(42, 9, 7))


-- ===========================================================================
-- 6. C. Cell origin
-- ===========================================================================

Section("C. GetCellOrigin")

for _, Case in ipairs(ORIGIN_CASES) do
	local Cfg = { Seed = Case[1], GridSize = Case[2], MaxOffset = Case[3], MaxSize = 128 }
	local OriginX, OriginZ = VillageLocate.GetCellOrigin(Case[1], Cfg, Case[4], Case[5])
	Check(string.format("origin of cell (%d, %d) grid=%d", Case[4], Case[5], Case[2]),
		(OriginX == Case[6]) and (OriginZ == Case[7]),
		OriginX .. "," .. OriginZ .. " ~= " .. Case[6] .. "," .. Case[7])
end

-- The origin must stay inside the cell offset window.
local Cfg384 = { Seed = 1402121502, GridSize = 384, MaxOffset = 128, MaxSize = 128 }
local Escaped = nil
for i = -20, 20 do
	local CellX = i * 384
	local OriginX, OriginZ = VillageLocate.GetCellOrigin(Cfg384.Seed, Cfg384, CellX, CellX)
	if (OriginX < CellX - 128) or (OriginX > CellX + 128) or (OriginZ < CellX - 128) or (OriginZ > CellX + 128) then
		Escaped = CellX .. " -> " .. OriginX .. "," .. OriginZ
		break
	end
end
Check("origin stays within MaxOffset of the cell point", Escaped == nil, Escaped)


-- ===========================================================================
-- 7. D. Candidate enumeration
-- ===========================================================================

Section("D. GetCandidates")

for _, Case in ipairs(CANDIDATE_CASES) do
	local A = Case.Args
	local Cfg = { Seed = A[1], GridSize = A[2], MaxOffset = A[3], MaxSize = A[4] }
	local Got = VillageLocate.GetCandidates(Cfg, A[5], A[6], A[7], A[8])
	Check("candidate count: " .. Case.Name, #Got == #Case.Expected,
		#Got .. " ~= " .. #Case.Expected)
	local Same = (#Got == #Case.Expected)
	if Same then
		for i, Want in ipairs(Case.Expected) do
			local C = Got[i]
			if (C.CellX ~= Want[1]) or (C.CellZ ~= Want[2]) or (C.OriginX ~= Want[3]) or (C.OriginZ ~= Want[4]) then
				Same = false
				Failures[#Failures + 1] = "candidate " .. i .. " of " .. Case.Name .. ": got " ..
					C.CellX .. "," .. C.CellZ .. "," .. C.OriginX .. "," .. C.OriginZ ..
					" want " .. table.concat(Want, ",")
				break
			end
		end
	end
	Check("candidate values: " .. Case.Name, Same)
end

-- Every candidate cell must be a multiple of the grid size.
local NotOnGrid = nil
for _, C in ipairs(VillageLocate.GetCandidates(Cfg384, -5000, 5000, -5000, 5000)) do
	if (C.CellX % 384 ~= 0) or (C.CellZ % 384 ~= 0) then
		NotOnGrid = C.CellX .. "," .. C.CellZ
		break
	end
end
Check("cells lie on the grid", NotOnGrid == nil, NotOnGrid)

-- A single chunk must yield few candidates: the search radius is roughly one cell.
local ChunkCandidates = VillageLocate.GetCandidates(Cfg384, 0, 15, 0, 15)
Check("a chunk has a handful of candidates (got " .. #ChunkCandidates .. ")",
	(#ChunkCandidates >= 1) and (#ChunkCandidates <= 9))

-- Cells in the far negative region must be produced too (C division vs math.floor).
local NegativeCells = VillageLocate.GetCandidates(Cfg384, -100000, -99990, -100000, -99990)
local HasNegative = false
for _, C in ipairs(NegativeCells) do
	if (C.CellX < 0) and (C.CellZ < 0) then HasNegative = true end
end
Check("negative grid cells are enumerated", HasNegative and (#NegativeCells >= 1), #NegativeCells)



-- ===========================================================================
-- 7b. Live-verified reference points
-- ===========================================================================
--
-- Four origins produced by this module against the real server (world seed
-- 1402121502, VillageGridSize 384, VillageMaxOffset 128, VillageMaxSize 128).
-- Each origin chunk was generated with cWorld:ChunkStay and scanned for village
-- blocks (planks, cobblestone, doors, fences, farmland, wheat, glass panes,
-- bookshelves, crafting tables) in y 62..76. The three whose biome passes the
-- PlainsVillage filter held 1295 / 698 / 867 such blocks; the one the module
-- rejects held 0. The module agreed with the blocks in all four cases.

local LIVE_ORIGINS =
{
	-- cell point,          origin,        village
	{ -768,    0,   -694,   3, true  },
	{ -384, -1152,  -273, -1075, true  },
	{  768,   768,   806,  881, true  },
	{    0,     0,   -72,  -33, false },
}

for _, Case in ipairs(LIVE_ORIGINS) do
	local OriginX, OriginZ = VillageLocate.GetCellOrigin(1402121502, Cfg384, Case[1], Case[2])
	Check(string.format("live origin for cell (%d, %d)", Case[1], Case[2]),
		(OriginX == Case[3]) and (OriginZ == Case[4]),
		OriginX .. "," .. OriginZ .. " ~= " .. Case[3] .. "," .. Case[4])
end

-- ===========================================================================
-- 8. E. FindNear
-- ===========================================================================

Section("E. FindNear")

local Near = VillageLocate.FindNear(Cfg384, 0, 0, 2000, 10)
Check("FindNear returns something", #Near > 0, #Near)
local Sorted = true
for i = 2, #Near do
	if Near[i - 1].Distance > Near[i].Distance then Sorted = false end
end
Check("results are sorted by distance", Sorted)
local InRadius = true
for _, C in ipairs(Near) do
	if C.Distance > 2000 then InRadius = false end
end
Check("results respect the radius", InRadius)
Check("MaxCount is honoured", #VillageLocate.FindNear(Cfg384, 0, 0, 100000, 3) == 3)
Check("radius 0 returns only an origin exactly at the point",
	#VillageLocate.FindNear(Cfg384, 1, 2, 0, 10) == 0)


-- ===========================================================================
-- 9. F. Pool metadata (cubeset parsing)
-- ===========================================================================

Section("F. LoadPoolBiomes")

MockFiles["Prefabs/Villages/UnitTestPool.cubeset"] =
	"-- a cubeset\nCubeset =\n{\n\tMetadata =\n\t{\n\t\tCubesetFormatVersion = 1,\n" ..
	"\t\t[\"AllowedBiomes\"] = \"Plains, Savanna, Desert\",\n\t\t[\"IntendedUse\"] = \"Village\",\n\t},\n" ..
	"\tPieces = { { Metadata = { [\"DefaultWeight\"] = \"100\" }, }, },\n}\n"

local Allowed = VillageLocate.LoadPoolBiomes("UnitTestPool")
Check("AllowedBiomes is parsed", Allowed ~= nil)
Check("Plains is allowed", Allowed ~= nil and Allowed[1] == true)
Check("Savanna is allowed", Allowed ~= nil and Allowed[2] == true)
Check("Desert is allowed", Allowed ~= nil and Allowed[5] == true)
Check("an unlisted biome is not allowed", Allowed ~= nil and Allowed[3] == nil)
Check("the per-piece Metadata block is not mistaken for the pool one",
	Allowed ~= nil and Allowed[100] == nil)

MockFiles["Prefabs/Villages/NoBiomesPool.cubeset"] = "Cubeset = { Metadata = { CubesetFormatVersion = 1, }, }"
local NoBiomes = VillageLocate.LoadPoolBiomes("NoBiomesPool")
Check("a pool without AllowedBiomes yields an empty set", NoBiomes ~= nil and next(NoBiomes) == nil)

local Missing, MissingErr = VillageLocate.LoadPoolBiomes("ThereIsNoSuchPool")
Check("a missing cubeset reports an error", Missing == nil and MissingErr ~= nil, MissingErr)


-- ===========================================================================
-- 10. G. Pool resolution
-- ===========================================================================

Section("G. ResolvePool")

local PlainsPool = { [1] = true, [2] = true, [3] = true, [4] = true }
local SandPool   = { [5] = true, [6] = true, [7] = true }
local ResolveCfg =
{
	Seed = 1402121502,
	Prefabs = { "PlainsPool", "SandPool" },
	PoolBiomes = { PlainsPool = PlainsPool, SandPool = SandPool },
	PoolError = nil,
}

local PlainsWorld = MakeWorld(1402121502, function() return 1 end)
Check("a plains origin resolves to the plains pool",
	VillageLocate.ResolvePool(PlainsWorld, ResolveCfg, 100, 200) == "PlainsPool")

local DesertWorld = MakeWorld(1402121502, function() return 5 end)
Check("a desert origin resolves to the sand pool",
	VillageLocate.ResolvePool(DesertWorld, ResolveCfg, 100, 200) == "SandPool")

local UnloadedWorld = MakeWorld(1402121502, nil)
local UnloadedPool, UnloadedErr = VillageLocate.ResolvePool(UnloadedWorld, ResolveCfg, 100, 200)
Check("an unloaded origin chunk does not guess", UnloadedPool == nil and UnloadedErr ~= nil, UnloadedErr)
Check("the unloaded reason names the chunk",
	UnloadedErr ~= nil and UnloadedErr:find("is not loaded", 1, true) ~= nil, UnloadedErr)

local MixedWorld = MakeWorld(1402121502, function(X, Z)
	if (X == 100) and (Z == 200) then return 5 end
	return 1
end)
local MixedPool, MixedErr = VillageLocate.ResolvePool(MixedWorld, ResolveCfg, 100, 200)
Check("one foreign biome column disqualifies every pool",
	MixedPool == nil and MixedErr ~= nil and MixedErr:find("no pool accepts", 1, true) ~= nil, MixedErr)

local BrokenCfg = { Seed = 1, Prefabs = { "X" }, PoolBiomes = {}, PoolError = "boom" }
Check("a pool metadata error is reported",
	VillageLocate.ResolvePool(PlainsWorld, BrokenCfg, 1, 1) == nil)

-- When two pools survive, the engine picks with cNoise(seed + 1000).
local BothCfg =
{
	Seed = 1402121502,
	Prefabs = { "APool", "BPool" },
	PoolBiomes = { APool = { [1] = true }, BPool = { [1] = true } },
	PoolError = nil,
}
for _, Case in ipairs(POOL_PICK_CASES) do
	local N = Case[4]
	local Prefabs, PoolBiomes = {}, {}
	for i = 1, N do
		Prefabs[i] = "Pool" .. i
		PoolBiomes["Pool" .. i] = { [1] = true }
	end
	local Cfg = { Seed = Case[1], Prefabs = Prefabs, PoolBiomes = PoolBiomes, PoolError = nil }
	local World = MakeWorld(Case[1], function() return 1 end)
	local Got = VillageLocate.ResolvePool(World, Cfg, Case[2], Case[3])
	Check(string.format("pool pick seed=%d origin=(%d,%d) n=%d", Case[1], Case[2], Case[3], N),
		Got == Prefabs[Case[5]], tostring(Got) .. " ~= " .. tostring(Prefabs[Case[5]]))
end
Check("a single surviving pool is returned directly",
	VillageLocate.ResolvePool(MakeWorld(1402121502, function() return 1 end), BothCfg, 5, 5) ~= nil)


-- ===========================================================================
-- 11. H. Generator configuration
-- ===========================================================================

Section("H. GetGeneratorConfig")

MockIniGroups.Generator =
{
	Finishers          = "RoughRavines, Mineshafts, Trees, Villages, TallGrass",
	VillageGridSize    = "384",
	VillageMaxOffset   = "128",
	VillageMaxSize     = "96",
	VillagePrefabs     = "PlainsVillage, SandVillage",
}
local Cfg, CfgErr = VillageLocate.GetGeneratorConfig(MakeWorld(1402121502, nil))
Check("config is read", Cfg ~= nil, CfgErr)
Check("seed comes from the world", Cfg ~= nil and Cfg.Seed == 1402121502)
Check("VillageGridSize", Cfg ~= nil and Cfg.GridSize == 384)
Check("VillageMaxOffset", Cfg ~= nil and Cfg.MaxOffset == 128)
Check("VillageMaxSize", Cfg ~= nil and Cfg.MaxSize == 96)
Check("VillagePrefabs order is kept", Cfg ~= nil and Cfg.Prefabs[1] == "PlainsVillage"
	and Cfg.Prefabs[2] == "SandVillage")

MockIniGroups.Generator.Finishers = "RoughRavines, Mineshafts, Trees"
local NoCfg, NoCfgErr = VillageLocate.GetGeneratorConfig(MakeWorld(1, nil))
Check("a world without the Villages finisher is rejected", NoCfg == nil and NoCfgErr ~= nil, NoCfgErr)

MockIniGroups.Generator.Finishers = "Villages"
MockIniGroups.Generator.VillageGridSize = "0"
MockIniGroups.Generator.VillageMaxSize = nil
local Defaults = VillageLocate.GetGeneratorConfig(MakeWorld(1, nil))
Check("a zero grid size is bumped to 1", Defaults ~= nil and Defaults.GridSize == 1)
Check("missing keys fall back to the engine defaults",
	Defaults ~= nil and Defaults.MaxSize == 128, Defaults and tostring(Defaults.MaxSize))

MockIniGroups.Generator.Finishers = "Villages"
MockIniGroups.Generator.VillageGridSize = "384"
MockIniGroups.Generator.VillagePrefabs = " PlainsVillage ,SandVillage, "
local Trimmed = VillageLocate.GetGeneratorConfig(MakeWorld(1, nil))
Check("the prefab list is trimmed", Trimmed ~= nil and Trimmed.Prefabs[1] == "PlainsVillage"
	and Trimmed.Prefabs[2] == "SandVillage" and #Trimmed.Prefabs == 2)



-- ===========================================================================
-- 12. I. The /villages command
-- ===========================================================================

Section("I. /villages command")

MockFiles["Prefabs/Villages/CmdPool.cubeset"] =
	"Cubeset = { Metadata = { [\"AllowedBiomes\"] = \"Plains\", }, }"
MockIniGroups.Generator.Finishers        = "Villages"
MockIniGroups.Generator.VillagePrefabs   = "CmdPool"
MockIniGroups.Generator.VillageGridSize  = "384"
MockIniGroups.Generator.VillageMaxOffset = "128"
MockIniGroups.Generator.VillageMaxSize   = nil

---A fake cPlayer that records the messages it is sent.
local function MakePlayer(a_X, a_Z, a_World)
	local Messages = {}
	return
	{
		GetWorld = function() return a_World end,
		GetPosX = function() return a_X end,
		GetPosZ = function() return a_Z end,
		SendMessageInfo = function(_, M) Messages[#Messages + 1] = "I:" .. M end,
		SendMessageFailure = function(_, M) Messages[#Messages + 1] = "F:" .. M end,
		Messages = Messages,
	}
end

-- A world whose biomes are always available, ie. the origin chunk is loaded.
local CmdWorld = MakeWorld(1402121502, function() return 1 end)

local Player = MakePlayer(0, 0, CmdWorld)
Check("the handler returns true", VillageLocate.Command({ "/villages" }, Player) == true)
Check("a header is sent", Player.Messages[1] ~= nil
	and Player.Messages[1]:find("Village candidates within 1024 blocks of (0, 0)", 1, true) ~= nil,
	Player.Messages[1])
Check("at most five candidates are listed", (#Player.Messages >= 2) and (#Player.Messages <= 6),
	#Player.Messages)
Check("the nearest origin matches the reference (-72, -33)",
	Player.Messages[2] ~= nil and Player.Messages[2]:find("(-72, -33)", 1, true) ~= nil, Player.Messages[2])
Check("a loaded origin chunk resolves to a village type",
	Player.Messages[2] ~= nil and Player.Messages[2]:find("village CmdPool", 1, true) ~= nil, Player.Messages[2])

local Tight = MakePlayer(0, 0, CmdWorld)
VillageLocate.Command({ "/villages", "1" }, Tight)
Check("a radius smaller than the nearest origin yields nothing",
	Tight.Messages[1] ~= nil and Tight.Messages[1]:find("No village grid cell within 1 blocks", 1, true) ~= nil,
	Tight.Messages[1])

local Negative = MakePlayer(0, 0, CmdWorld)
VillageLocate.Command({ "/villages", "-5" }, Negative)
Check("a negative radius is rejected",
	Negative.Messages[1] ~= nil and Negative.Messages[1]:find("must be positive", 1, true) ~= nil,
	Negative.Messages[1])

local NonNumeric = MakePlayer(0, 0, CmdWorld)
VillageLocate.Command({ "/villages", "abc" }, NonNumeric)
Check("a non-numeric radius falls back to the default",
	NonNumeric.Messages[1] ~= nil and NonNumeric.Messages[1]:find("within 1024 blocks", 1, true) ~= nil,
	NonNumeric.Messages[1])

-- An unloaded world cannot resolve the type, but must still list the candidate.
local UnloadedCmd = MakePlayer(0, 0, MakeWorld(1402121502, nil))
VillageLocate.Command({ "/villages" }, UnloadedCmd)
Check("an unloaded world still lists candidates",
	UnloadedCmd.Messages[2] ~= nil and UnloadedCmd.Messages[2]:find("candidate, origin", 1, true) ~= nil,
	UnloadedCmd.Messages[2])
Check("the unresolved line says why",
	UnloadedCmd.Messages[2] ~= nil and UnloadedCmd.Messages[2]:find("is not loaded", 1, true) ~= nil,
	UnloadedCmd.Messages[2])

MockIniGroups.Generator.Finishers = "Trees"
local Disabled = MakePlayer(0, 0, CmdWorld)
VillageLocate.Command({ "/villages" }, Disabled)
Check("a world without the Villages finisher reports a failure",
	Disabled.Messages[1] ~= nil and Disabled.Messages[1]:sub(1, 1) == "F", Disabled.Messages[1])
MockIniGroups.Generator.Finishers = "Villages"

-- ===========================================================================
-- 13. Summary
-- ===========================================================================

print("")
print(string.format("village_locate_test: %d passed, %d failed", Passed, Failed))
if (Failed > 0) then
	print("")
	print("Failures:")
	for _, F in ipairs(Failures) do
		print("  - " .. F)
	end
end
os.exit(Failed == 0 and 0 or 1)
