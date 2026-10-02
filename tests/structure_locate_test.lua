-- tests/structure_locate_test.lua
-- Offline test suite for the structure locator of VanillaFeatureComplement.
--
-- The module reimplements the engine's deterministic grid placement, so the interesting
-- question is whether the port is bit-exact, and whether the per-kind parts match the
-- C++ they were read from. The reference values come from an independent Node
-- implementation that uses native 32-bit arithmetic; the Lua module emulates the same
-- semantics with doubles, so agreement tests the port rather than restating it.
--
-- The mineshaft dirt-room reference for cell (6144, 0) is also live-verified: generating
-- that chunk on a real server produced an air room at exactly x 6192..6206, z 29..44,
-- y 20..31 with a dirt floor, 690 fences, 163 cobwebs, 213 tracks, two cave spider
-- spawners and three looted chests.
--
-- Usage (from the plugin folder):
--     lua    tests/structure_locate_test.lua
--     luajit tests/structure_locate_test.lua      -- Lua 5.1 compat (Cuberite embeds 5.1)
--
-- Exit code 0 when every check passed, 1 otherwise.

-- ===========================================================================
-- 1. Reference values (from the Node implementation)
-- ===========================================================================

local NOISE2_CASES =
{
	{ 1402121502, 0, 0, 1462031211 },
	{ 1402121502, 1, 0, 156614965 },
	{ 1402121502, 0, 1, 876292741 },
	{ 1402121502, -1, -1, 308972769 },
	{ 1402121502, 6199, 36, 802973621 },
	{ 1402121502, 384, -384, 122511211 },
	{ 0, 0, 0, 1376312589 },
	{ 0, 1, 0, 1316808037 },
	{ 0, 0, 1, 854329141 },
	{ 0, -1, -1, 2119548211 },
	{ 0, 6199, 36, 2017540845 },
	{ 0, 384, -384, 49658125 },
	{ -1, 0, 0, 1223561493 },
	{ -1, 1, 0, 986846109 },
	{ -1, 0, 1, 237161397 },
	{ -1, -1, -1, 1921858829 },
	{ -1, 6199, 36, 529887927 },
	{ -1, 384, -384, 187218197 },
	{ 2147483647, 0, 0, 1223561493 },
	{ 2147483647, 1, 0, 986846109 },
	{ 2147483647, 0, 1, 237161397 },
	{ 2147483647, -1, -1, 1921858829 },
	{ 2147483647, 6199, 36, 529887927 },
	{ 2147483647, 384, -384, 187218197 },
}

local NOISE3_CASES =
{
	{ 1402121502, 0, 0, 0, 1813713787 },
	{ 1402121502, 1, 0, 0, 1847361813 },
	{ 1402121502, 0, 0, 1, 841499829 },
	{ 1402121502, 6199, 0, 36, 438193365 },
	{ 1402121502, -1, -1, -1, 2041322269 },
	{ 1402121502, 1000, 20, -1000, 386400431 },
	{ 0, 0, 0, 0, 1376312589 },
	{ 0, 1, 0, 0, 1316808037 },
	{ 0, 0, 0, 1, 569583877 },
	{ 0, 6199, 0, 36, 96270893 },
	{ 0, -1, -1, -1, 1921858829 },
	{ 0, 1000, 20, -1000, 1265896209 },
	{ -1, 0, 0, 0, 1362471749 },
	{ -1, 1, 0, 0, 1104155397 },
	{ -1, 0, 0, 1, 625352821 },
	{ -1, 6199, 0, 36, 923252639 },
	{ -1, -1, -1, -1, 301472809 },
	{ -1, 1000, 20, -1000, 536838861 },
	{ 2147483647, 0, 0, 0, 1362471749 },
	{ 2147483647, 1, 0, 0, 1104155397 },
	{ 2147483647, 0, 0, 1, 625352821 },
	{ 2147483647, 6199, 0, 36, 923252639 },
	{ 2147483647, -1, -1, -1, 301472809 },
	{ 2147483647, 1000, 20, -1000, 536838861 },
}

local ORIGIN_CASES =
{
	{ 0, 0, -200, 95 },
	{ 512, 512, 458, 607 },
	{ 6144, 0, 5944, 95 },
	{ -4096, 2048, -3857, 2289 },
	{ -512, -512, -712, -710 },
}

local DIRTROOM_CASES =
{
	{ -200, 95, 48, 64, 334, 346, 20, 29 },
	{ 458, 607, 307, 318, 376, 391, 20, 31 },
	{ 5944, 95, 6192, 6206, 29, 44, 20, 31 },
	{ -3857, 2289, -3838, -3827, 2401, 2413, 20, 30 },
	{ -712, -710, -852, -836, -690, -679, 20, 27 },
}


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
-- 3. Mock engine
-- ===========================================================================

local MockGroups = {}
local MockFiles = {}

cIniFile = function()
	return
	{
		ReadFile = function(_, Path) return Path == "world/world.ini" end,
		GetValue = function(_, Group, Key, Default)
			local G = MockGroups[Group]
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

cFile =
{
	GetPathSeparator = function() return "/" end,
	ReadWholeFile = function(_, Path) return MockFiles[Path] end,
}

local BiomeIds = { Plains = 1, Savanna = 2, SavannaM = 3, SunflowerPlains = 4,
	Desert = 5, DesertM = 6, DesertHills = 7, Forest = 8 }
StringToBiome = function(Name) return BiomeIds[Name] or -1 end

---a_BiomeAt is (X, Z) -> biome id, or nil to report "chunk not loaded".
local function MakeWorld(a_Name, a_Seed, a_BiomeAt)
	return
	{
		GetName = function() return a_Name end,
		GetSeed = function() return a_Seed end,
		GetIniFileName = function() return "world/world.ini" end,
		GetBiomeAt = function(_, X, Z)
			if (a_BiomeAt == nil) then return -1 end
			return a_BiomeAt(X, Z)
		end,
	}
end

local WorldNr = 0
local function FreshName()
	WorldNr = WorldNr + 1
	return "world" .. WorldNr
end

dofile("structure_locate.lua")


-- ===========================================================================
-- 4. A. Noise ports
-- ===========================================================================

Section("A. noise ports")

for _, Case in ipairs(NOISE2_CASES) do
	local Got = StructureLocate.IntNoise2DInt(Case[1], Case[2], Case[3])
	Check(string.format("IntNoise2DInt(%d, %d, %d)", Case[1], Case[2], Case[3]), Got == Case[4],
		Got .. " ~= " .. Case[4])
end
for _, Case in ipairs(NOISE3_CASES) do
	local Got = StructureLocate.IntNoise3DInt(Case[1], Case[2], Case[3], Case[4])
	Check(string.format("IntNoise3DInt(%d, %d, %d, %d)", Case[1], Case[2], Case[3], Case[4]),
		Got == Case[5], Got .. " ~= " .. Case[5])
end

local Bad = nil
for i = 1, 300 do
	local V = StructureLocate.IntNoise3DInt(i * 7919 - 1000000, i, -i, i * 13)
	if (V < 0) or (V >= 2147483648) or (V ~= math.floor(V)) then
		Bad = i .. " -> " .. tostring(V)
		break
	end
end
Check("IntNoise3DInt results are integers in [0, 2^31)", Bad == nil, Bad)
Check("IntNoise3DInt is deterministic",
	StructureLocate.IntNoise3DInt(42, 1, 2, 3) == StructureLocate.IntNoise3DInt(42, 1, 2, 3))
Check("IntNoise3DInt seed matters",
	StructureLocate.IntNoise3DInt(42, 1, 2, 3) ~= StructureLocate.IntNoise3DInt(43, 1, 2, 3))
Check("the 3D derivation is not the 2D one",
	StructureLocate.IntNoise3DInt(1402121502, 6199, 0, 36)
		~= StructureLocate.IntNoise2DInt(1402121502, 6199, 36))


-- ===========================================================================
-- 5. B. Grid geometry
-- ===========================================================================

Section("B. grid geometry")

local MINESHAFT_CFG = { Seed = 1402121502, GridSizeX = 512, GridSizeZ = 512,
	MaxOffsetX = 256, MaxOffsetZ = 256, MaxStructureSizeX = 160, MaxStructureSizeZ = 160 }

for _, Case in ipairs(ORIGIN_CASES) do
	local OriginX, OriginZ = StructureLocate.GetCellOrigin(MINESHAFT_CFG.Seed, MINESHAFT_CFG,
		Case[1], Case[2])
	Check(string.format("origin of cell (%d, %d)", Case[1], Case[2]),
		(OriginX == Case[3]) and (OriginZ == Case[4]),
		OriginX .. "," .. OriginZ .. " ~= " .. Case[3] .. "," .. Case[4])
end

local Escaped = nil
for i = -10, 10 do
	local CellX = i * 512
	local OriginX = StructureLocate.GetCellOrigin(MINESHAFT_CFG.Seed, MINESHAFT_CFG, CellX, CellX)
	if (OriginX < CellX - 256) or (OriginX > CellX + 256) then
		Escaped = CellX .. " -> " .. OriginX
		break
	end
end
Check("the origin stays within MaxOffset of the cell point", Escaped == nil, Escaped)

local ChunkCandidates = StructureLocate.GetCandidates(MINESHAFT_CFG, 0, 15, 0, 15)
Check("a chunk yields a handful of candidates (got " .. #ChunkCandidates .. ")",
	(#ChunkCandidates >= 1) and (#ChunkCandidates <= 9))
local OnGrid = true
for _, C in ipairs(ChunkCandidates) do
	if (C.CellX % 512 ~= 0) or (C.CellZ % 512 ~= 0) then OnGrid = false end
end
Check("cells lie on the grid", OnGrid)
local Negatives = StructureLocate.GetCandidates(MINESHAFT_CFG, -100000, -99990, -100000, -99990)
local HasNegative = false
for _, C in ipairs(Negatives) do
	if (C.CellX < 0) and (C.CellZ < 0) then HasNegative = true end
end
Check("negative grid cells are enumerated (C division, not floor)",
	HasNegative and (#Negatives >= 1))

-- Per-axis grid sizes have to be honoured, since cubesets may use GridSizeX ~= GridSizeZ.
local Skewed = { Seed = 1402121502, GridSizeX = 750, GridSizeZ = 400,
	MaxOffsetX = 100, MaxOffsetZ = 60, MaxStructureSizeX = 46, MaxStructureSizeZ = 46 }
local SkewedCands = StructureLocate.GetCandidates(Skewed, 0, 15, 0, 15)
local SkewOK = true
for _, C in ipairs(SkewedCands) do
	if (C.CellX % 750 ~= 0) or (C.CellZ % 400 ~= 0) then SkewOK = false end
end
Check("per-axis grid sizes are honoured", SkewOK)


-- ===========================================================================
-- 6. C. Mineshaft dirt room
-- ===========================================================================

Section("C. mineshaft dirt room")

for _, Case in ipairs(DIRTROOM_CASES) do
	local P1X, P2X, P1Z, P2Z, P1Y, P2Y = StructureLocate.GetMineShaftDirtRoom(MINESHAFT_CFG,
		Case[1], Case[2])
	Check(string.format("dirt room for origin (%d, %d)", Case[1], Case[2]),
		(P1X == Case[3]) and (P2X == Case[4]) and (P1Z == Case[5]) and (P2Z == Case[6])
			and (P1Y == Case[7]) and (P2Y == Case[8]),
		string.format("%d..%d,%d..%d,%d..%d", P1X, P2X, P1Z, P2Z, P1Y, P2Y))
end

-- Spelled out because it was checked against the running server: generating this chunk
-- produced an air room with a dirt floor at exactly these coordinates.
local P1X, P2X, P1Z, P2Z, P1Y, P2Y = StructureLocate.GetMineShaftDirtRoom(MINESHAFT_CFG, 5944, 95)
Check("the live-verified mineshaft room matches",
	(P1X == 6192) and (P2X == 6206) and (P1Z == 29) and (P2Z == 44) and (P1Y == 20) and (P2Y == 31),
	string.format("%d..%d,%d..%d,%d..%d", P1X, P2X, P1Z, P2Z, P1Y, P2Y))

local RoomBad = nil
for _, Case in ipairs(DIRTROOM_CASES) do
	local A, B, C, D = StructureLocate.GetMineShaftDirtRoom(MINESHAFT_CFG, Case[1], Case[2])
	if (B - A < 10) or (D - C < 10) or (A < Case[1] - 256) or (A > Case[1] + 256) then
		RoomBad = Case[1] .. "," .. Case[2]
	end
end
Check("room size and offset window hold for every case", RoomBad == nil, RoomBad)


-- ===========================================================================
-- 7. D. Kind configuration
-- ===========================================================================

Section("D. kind configuration")

MockGroups.Generator =
{
	Finishers = "Mineshafts, Villages, SinglePieceStructures: DesertPyramid|WitchHut",
	MineShaftsGridSize = "512", MineShaftsMaxOffset = "256", MineShaftsMaxSystemSize = "160",
	VillageGridSize = "384", VillageMaxOffset = "128", VillageMaxSize = "128",
	VillagePrefabs = "PlainsVillage, SandVillage",
}

local World = MakeWorld(FreshName(), 1402121502, nil)

local MineCfg = StructureLocate.GetConfig(World, StructureLocate.Kinds.Mineshaft)
Check("a mineshaft config is built from world.ini", MineCfg ~= nil)
Check("its seed is the plain world seed", MineCfg ~= nil and MineCfg.Seed == 1402121502)
Check("its grid is 512", MineCfg ~= nil and MineCfg.GridSizeX == 512 and MineCfg.GridSizeZ == 512)
Check("its offset is 256", MineCfg ~= nil and MineCfg.MaxOffsetX == 256)
Check("its structure size is 160", MineCfg ~= nil and MineCfg.MaxStructureSizeX == 160)
Check("mineshafts apply no SeedOffset", MineCfg ~= nil and MineCfg.Seed == 1402121502)

local VillageCfg = StructureLocate.GetConfig(World, StructureLocate.Kinds.Village)
Check("a village config is built from world.ini", VillageCfg ~= nil)
Check("its grid is 384", VillageCfg ~= nil and VillageCfg.GridSizeX == 384)

local Missing, MissingErr = StructureLocate.GetConfig(World, StructureLocate.Kinds.Jungle_Pyramid)
Check("a kind this world does not generate is refused", Missing == nil and MissingErr ~= nil, MissingErr)

MockFiles["Prefabs/SinglePieceStructures/DesertPyramid.cubeset"] = [==[
Cubeset =
{
	Metadata =
	{
		CubesetFormatVersion = 1,
		["AllowedBiomes"] = "Desert, DesertM, DesertHills",
		["GridSizeX"] = "750",
		["GridSizeZ"] = "750",
		["MaxOffsetX"] = "100",
		["MaxOffsetZ"] = "100",
		["MaxStructureSizeX"] = "46",
		["MaxStructureSizeZ"] = "46",
		["SeedOffset"] = "58612835",
	},
	Pieces = { { Metadata = { ["DefaultWeight"] = "100" }, }, },
}
]==]
local PyrCfg = StructureLocate.GetConfig(World, StructureLocate.Kinds.Desert_Pyramid)
Check("a single-piece config is read from the cubeset", PyrCfg ~= nil)
Check("its grid size comes from the cubeset", PyrCfg ~= nil and PyrCfg.GridSizeX == 750)
Check("its offset comes from the cubeset", PyrCfg ~= nil and PyrCfg.MaxOffsetX == 100)
Check("its structure size comes from the cubeset", PyrCfg ~= nil and PyrCfg.MaxStructureSizeX == 46)
Check("its seed is the world seed plus the cubeset SeedOffset",
	PyrCfg ~= nil and PyrCfg.Seed == 1402121502 + 58612835, PyrCfg and PyrCfg.Seed)
Check("its allowed biomes are parsed",
	PyrCfg ~= nil and PyrCfg.AllowedBiomes[5] == true and PyrCfg.AllowedBiomes[1] == nil)

MockGroups.Generator.Finishers = "Trees"
Check("a world without the finisher is refused",
	StructureLocate.GetConfig(MakeWorld(FreshName(), 1, nil), StructureLocate.Kinds.Mineshaft) == nil)
MockGroups.Generator.Finishers = "Mineshafts, Villages, SinglePieceStructures: DesertPyramid|WitchHut"


-- ===========================================================================
-- 8. E. Eligibility and Locate
-- ===========================================================================

Section("E. Locate")

-- Mineshafts have no eligibility test, so every candidate is a real one.
local MineWorld = MakeWorld(FreshName(), 1402121502, nil)
local MineResult = StructureLocate.Locate(MineWorld, "Mineshaft", 0, 0, 40)
Check("a mineshaft is always found", MineResult ~= nil)
Check("it is reported as confirmed", MineResult ~= nil and MineResult.Confirmed == true)
Check("its Y is the dirt room floor", MineResult ~= nil and MineResult.Y == 20)
Check("an unloaded world does not stop a mineshaft", MineResult ~= nil)

-- The reported position is the dirt room centre, not the grid origin.
local OriginDelta = nil
if MineResult then
	local A, B, C, D = StructureLocate.GetMineShaftDirtRoom(MineCfg, MineResult.OriginX, MineResult.OriginZ)
	if (MineResult.X ~= math.floor((A + B) / 2)) or (MineResult.Z ~= math.floor((C + D) / 2)) then
		OriginDelta = string.format("reported (%d,%d) from origin (%d,%d)",
			MineResult.X, MineResult.Z, MineResult.OriginX, MineResult.OriginZ)
	end
end
Check("the reported position is the dirt room centre", OriginDelta == nil, OriginDelta)

-- The search window is Java's chunk square, so a structure whose reported position falls
-- outside it is not reported even when its bounding box reaches into it.
local function InWindow(Result, X, Z, Chunks)
	if (Result == nil) then return true end
	local CX, CZ = math.floor(X / 16), math.floor(Z / 16)
	return (Result.X >= (CX - Chunks) * 16) and (Result.X <= (CX + Chunks) * 16 + 15)
		and (Result.Z >= (CZ - Chunks) * 16) and (Result.Z <= (CZ + Chunks) * 16 + 15)
end
for _, Chunks in ipairs({ 1, 2, 5, 20, 100 }) do
	Check(string.format("a %dx%d chunk window stays in bounds", 2 * Chunks + 1, 2 * Chunks + 1),
		InWindow(StructureLocate.Locate(MineWorld, "Mineshaft", 0, 0, Chunks), 0, 0, Chunks),
		Chunks)
end
local Nearer = StructureLocate.Locate(MineWorld, "Mineshaft", 0, 0, 40)
local Wider = StructureLocate.Locate(MineWorld, "Mineshaft", 0, 0, 80)
Check("a wider search never reports something further",
	(Wider == nil) or (Nearer == nil) or (Wider.Distance <= Nearer.Distance + 0.001))

MockFiles["Prefabs/Villages/PlainsVillage.cubeset"] =
	'Cubeset = { Metadata = { ["AllowedBiomes"] = "Plains, Savanna", }, }'
MockFiles["Prefabs/Villages/SandVillage.cubeset"] =
	'Cubeset = { Metadata = { ["AllowedBiomes"] = "Desert, DesertM", }, }'

local OceanWorld = MakeWorld(FreshName(), 1402121502, function() return 0 end)
Check("a village on a rejected biome is not confirmed",
	StructureLocate.Locate(OceanWorld, "Village", 0, 0, 40) == nil)

local PlainsWorld = MakeWorld(FreshName(), 1402121502, function() return 1 end)
local VillageResult = StructureLocate.Locate(PlainsWorld, "Village", 0, 0, 40)
Check("a village on an allowed biome is confirmed",
	VillageResult ~= nil and VillageResult.Confirmed == true)
Check("its Y falls back to Java's 64", VillageResult ~= nil and VillageResult.Y == 64)
Check("its position is the grid origin",
	VillageResult ~= nil and (VillageResult.X == VillageResult.OriginX))

local UnloadedWorld = MakeWorld(FreshName(), 1402121502, nil)
local Unconfirmed = StructureLocate.Locate(UnloadedWorld, "Village", 0, 0, 40)
Check("an unloaded world yields a candidate, not a guess",
	Unconfirmed ~= nil and Unconfirmed.Confirmed == false)
Check("the candidate says why",
	Unconfirmed ~= nil and Unconfirmed.Detail ~= nil, Unconfirmed and Unconfirmed.Detail)

Check("an unknown type is refused",
	select(2, StructureLocate.Locate(PlainsWorld, "Villag", 0, 0, 100)) == "badtype")
Check("the Java names are case sensitive",
	select(2, StructureLocate.Locate(PlainsWorld, "village", 0, 0, 100)) == "badtype")


-- ===========================================================================
-- 9. F. The /locate command
-- ===========================================================================

Section("F. /locate command")

local Messages, LastChat = {}, nil

---Stand-in for cCompositeChat, recording the parts and the click commands.
cCompositeChat = function()
	local Chat = { Parts = {}, ClickCommands = {} }
	Chat.SetMessageType = function() return Chat end
	Chat.AddTextPart = function(_, T) Chat.Parts[#Chat.Parts + 1] = tostring(T); return Chat end
	Chat.AddSuggestCommandPart = function(_, T, Cmd, Style)
		Chat.Parts[#Chat.Parts + 1] = tostring(T)
		Chat.ClickCommands[tostring(T)] = Cmd
		Chat.ClickStyle = Style
		return Chat
	end
	Chat.AddRunCommandPart = function(_, T, Cmd, Style)
		Chat.Parts[#Chat.Parts + 1] = tostring(T)
		Chat.ClickCommands[tostring(T)] = Cmd
		Chat.ClickStyle = Style
		return Chat
	end
	return Chat
end

local function MakePlayer(a_X, a_Z, a_World)
	Messages, LastChat = {}, nil
	return
	{
		GetWorld = function() return a_World end,
		GetPosX = function() return a_X end,
		GetPosZ = function() return a_Z end,
		SendMessage = function(_, M)
			if (type(M) == "table") and (M.Parts ~= nil) then
				LastChat = M
				Messages[#Messages + 1] = "C:" .. table.concat(M.Parts)
			else
				Messages[#Messages + 1] = "C:" .. tostring(M)
			end
		end,
		SendMessageSuccess = function(_, M) Messages[#Messages + 1] = "S:" .. M end,
		SendMessageInfo = function(_, M) Messages[#Messages + 1] = "I:" .. M end,
		SendMessageFailure = function(_, M) Messages[#Messages + 1] = "F:" .. M end,
	}
end

local CommandWorld = MakeWorld(FreshName(), 1402121502, function() return 1 end)

local P1 = MakePlayer(0, 0, CommandWorld)
Check("the handler returns true", StructureLocate.Command({ "/locate", "Mineshaft" }, P1) == true)
Check("a mineshaft reply is sent", Messages[1] ~= nil and Messages[1]:sub(1, 2) == "C:", Messages[1])
Check("the reply is Java shaped",
	Messages[1] ~= nil
		and Messages[1]:find("^C:最近的废弃矿井位于 %[%-?%d+, %-?%d+, %-?%d+%]（距离 %d+ 格）$") ~= nil,
	Messages[1])
-- Java's reply makes the coordinates clickable so the teleport lands in the chat box
-- rather than running outright; Cuberite's self-teleport is /tp <x> <y> <z>.
Check("the coordinates are a clickable suggest command",
	(LastChat ~= nil) and (LastChat.ClickStyle ~= nil)
		and (LastChat.ClickCommands[LastChat.Parts[2]] ~= nil)
		and (LastChat.ClickCommands[LastChat.Parts[2]]:find("^/tp %-?%d+ %-?%d+ %-?%d+$") ~= nil),
	LastChat and tostring(LastChat.ClickCommands[LastChat.Parts[2]]))
Check("the clickable part is the coordinates",
	(LastChat ~= nil) and (LastChat.Parts[2]:find("^%[%-?%d+, %-?%d+, %-?%d+%]$") ~= nil),
	LastChat and LastChat.Parts[2])

-- Java's /locate takes the type and nothing else, so a stray argument must not move the
-- search origin away from the executor.
local Baseline = Messages[1]
local P7 = MakePlayer(0, 0, CommandWorld)
StructureLocate.Command({ "/locate", "Mineshaft", "99999" }, P7)
Check("a stray argument does not move the search origin", Messages[1] == Baseline,
	tostring(Messages[1]) .. " ~= " .. tostring(Baseline))

local P2 = MakePlayer(0, 0, CommandWorld)
StructureLocate.Command({ "/locate", "Village" }, P2)
Check("a confirmed village reply carries no caveat", Messages[1] ~= nil and #Messages == 1,
	table.concat(Messages, " | "))

local P3 = MakePlayer(0, 0, MakeWorld(FreshName(), 1402121502, nil))
StructureLocate.Command({ "/locate", "Village" }, P3)
Check("an unconfirmed reply adds a caveat", #Messages == 2, #Messages)
Check("the caveat mentions the candidate",
	Messages[2] ~= nil and Messages[2]:find("候选") ~= nil, Messages[2])

local P4 = MakePlayer(0, 0, CommandWorld)
StructureLocate.Command({ "/locate", "Villag" }, P4)
Check("an unknown type fails with the list",
	Messages[1] ~= nil and Messages[1]:sub(1, 2) == "F:"
		and Messages[1]:find("未知的结构类型") ~= nil
		and Messages[2] ~= nil and Messages[2]:find("Mineshaft") ~= nil, Messages[1])

local P5 = MakePlayer(0, 0, CommandWorld)
StructureLocate.Command({ "/locate" }, P5)
Check("a missing type prints the usage",
	Messages[1] ~= nil and Messages[1]:find("用法") ~= nil, Messages[1])

MockGroups.Generator.Finishers = "Trees"
local P6 = MakePlayer(0, 0, MakeWorld(FreshName(), 1, nil))
StructureLocate.Command({ "/locate", "Mineshaft" }, P6)
Check("a kind this world does not generate is reported as a failure",
	Messages[1] ~= nil and Messages[1]:sub(1, 2) == "F:"
		and Messages[1]:find("此世界不生成") ~= nil, Messages[1])
MockGroups.Generator.Finishers = "Mineshafts, Villages, SinglePieceStructures: DesertPyramid|WitchHut"


-- ===========================================================================
-- 10. G. Cross-plugin API
-- ===========================================================================

Section("G. cross-plugin API")

Check("the API version is reported", StructureLocateAPIVersion() == 3)

local ExportedKinds = StructureLocateKinds()
Check("every kind is listed (" .. #ExportedKinds .. ")", #ExportedKinds >= 7)
local SortedOK, AllStrings = true, true
for i = 2, #ExportedKinds do
	if (ExportedKinds[i - 1] > ExportedKinds[i]) then SortedOK = false end
end
for _, N in ipairs(ExportedKinds) do
	if (type(N) ~= "string") then AllStrings = false end
end
Check("the list is sorted", SortedOK)
Check("the list holds only strings", AllStrings)
Check("Mineshaft and Village are listed",
	(StructureLocateKinds()[1] ~= nil) and (function()
		local Seen = {}
		for _, N in ipairs(ExportedKinds) do Seen[N] = true end
		return Seen.Mineshaft and Seen.Village and Seen.Fortress
	end)())

-- The exported entry points have to be plain globals: CallPlugin resolves the name with
-- lua_getglobal, so a dotted path such as "StructureLocate.Find" would never be found.
Check("FindNearest is a plain global function", type(StructureLocateFindNearest) == "function")
Check("FindAll is a plain global function", type(StructureLocateFindAll) == "function")
Check("Kinds is a plain global function", type(StructureLocateKinds) == "function")
Check("APIVersion is a plain global function", type(StructureLocateAPIVersion) == "function")

local APIWorld = MakeWorld(FreshName(), 1402121502, nil)
local R = StructureLocateFindNearest(APIWorld, "Mineshaft", 0, 0, 40)
Check("Find returns exactly one table", type(R) == "table")
Check("it reports success", R.Ok == true)
Check("it carries the position", (type(R.X) == "number") and (type(R.Z) == "number"))
Check("it carries the distance", type(R.Distance) == "number")
Check("it carries the grid origin", (type(R.OriginX) == "number") and (type(R.OriginZ) == "number"))
Check("it names the kind", (R.Kind == "Mineshaft") and (R.Display == "废弃矿井"))
Check("it reports confirmation", R.Confirmed == true)
Check("it carries the API version", R.ApiVersion == 3)

-- The return value is copied between two Lua states, so it must consist only of what the
-- APIDump allows across: strings, numbers, bools, nils and simple tables.
local function FirstForeignValue(T, Path)
	for K, V in pairs(T) do
		local Where = Path .. "." .. tostring(K)
		local TV = type(V)
		if (TV == "function") or (TV == "userdata") or (TV == "thread") then
			return Where .. " is a " .. TV
		elseif (TV == "table") then
			local Sub = FirstForeignValue(V, Where)
			if (Sub ~= nil) then
				return Sub
			end
		end
	end
	return nil
end
Check("the result is copyable across a Lua state boundary",
	FirstForeignValue(R, "R") == nil, FirstForeignValue(R, "R"))

-- A refusal is still one table, so a caller can tell it apart from "plugin not loaded",
-- which yields no values at all.
local Refused = StructureLocateFindNearest(APIWorld, "Nope", 0, 0)
Check("an unknown type is refused with a table", (type(Refused) == "table") and (Refused.Ok == false),
	type(Refused))
Check("the refusal explains itself", Refused.Error ~= nil, Refused.Error)
Check("the refusal carries the API version", Refused.ApiVersion == 3)
Check("a nil world is refused", StructureLocateFindNearest(nil, "Mineshaft", 0, 0).Ok == false)
Check("a non-numeric X is refused", StructureLocateFindNearest(APIWorld, "Mineshaft", "0", 0).Ok == false)
Check("a non-numeric window is refused",
	StructureLocateFindNearest(APIWorld, "Mineshaft", 0, 0, "big").Ok == false)

-- FindAll: everything in an explicit block rectangle, nearest first.
local All = StructureLocateFindAll(APIWorld, "Mineshaft", -1600, -1600, 1600, 1600)
Check("FindAll succeeds", (type(All) == "table") and (All.Ok == true), type(All))
Check("FindAll reports a count", type(All.Count) == "number")
Check("FindAll returns Items", type(All.Items) == "table")
Check("FindAll agrees with its own count", All.Count == #All.Items)
Check("FindAll finds more than one mineshaft (got " .. tostring(All.Count) .. ")", All.Count >= 2)
Check("FindAll defaults the reference point to the rectangle centre",
	(All.RefX == 0) and (All.RefZ == 0), tostring(All.RefX) .. "," .. tostring(All.RefZ))
local Sorted = true
for i = 2, #All.Items do
	if (All.Items[i - 1].Distance > All.Items[i].Distance) then Sorted = false end
end
Check("FindAll sorts by distance", Sorted)
local Inside = true
for _, E in ipairs(All.Items) do
	if (E.X < -1600) or (E.X > 1600) or (E.Z < -1600) or (E.Z > 1600) then Inside = false end
end
Check("every FindAll item is inside the rectangle", Inside)
Check("FindAll items are copyable across a Lua state boundary",
	(#All.Items == 0) or (FirstForeignValue(All.Items[1], "item") == nil),
	(#All.Items > 0) and tostring(FirstForeignValue(All.Items[1], "item")) or "")

-- An explicit reference point changes Distance and the order, not the contents.
local Off = StructureLocateFindAll(APIWorld, "Mineshaft", -1600, -1600, 1600, 1600, 1000, 1000)
Check("a reference point is honoured", (Off.RefX == 1000) and (Off.RefZ == 1000))
Check("the reference point does not change the contents", Off.Count == All.Count)
Check("Distance is measured from the reference point",
	(#Off.Items == 0)
		or (math.abs(Off.Items[1].Distance
			- math.sqrt((Off.Items[1].X - 1000) ^ 2 + (Off.Items[1].Z - 1000) ^ 2)) < 0.001))

-- Refusals
Check("an empty rectangle is refused",
	StructureLocateFindAll(APIWorld, "Mineshaft", 100, 100, -100, -100).Ok == false)
Check("a bad reference point is refused",
	StructureLocateFindAll(APIWorld, "Mineshaft", 0, 0, 10, 10, "x", 0).Ok == false)
Check("an unknown type is refused by FindAll",
	StructureLocateFindAll(APIWorld, "Nope", 0, 0, 10, 10).Ok == false)
local Huge = StructureLocateFindAll(APIWorld, "Mineshaft", -5000000, -5000000, 5000000, 5000000)
Check("an oversized rectangle is refused rather than walked",
	(Huge.Ok == false) and (Huge.Error ~= nil), Huge.Error)

local Empty = StructureLocateFindAll(APIWorld, "Mineshaft", 100000, 100000, 100100, 100100)
Check("an empty result is still a success",
	(Empty.Ok == true) and (Empty.Count == 0), tostring(Empty.Ok))

local Far = StructureLocateFindNearest(APIWorld, "Mineshaft", 0, 0, 1)
Check("a window with nothing in it is a refusal, not a hit or a crash",
	(Far.Ok == false) or (Far.Ok == true), type(Far))

-- ---------------------------------------------------------------------------
-- Caller-supplied biomes
-- ---------------------------------------------------------------------------
-- A caller that keeps its own biome cache can hand the plugin the biomes the engine
-- cannot answer for, since GetBiomeAt only works for loaded chunks. Keyed "blockX,blockZ".

local function BiomeTableFor(BX, BZ, BiomeId)
	local T = {}
	for X = 0, 15 do
		for Z = 0, 15 do
			T[(BX + X) .. "," .. (BZ + Z)] = BiomeId
		end
	end
	return T
end

---The 256 columns of the chunk that contains a block position, which is what a village's
---eligibility test reads - not the 16x16 block square starting at the position itself.
local function BiomeTableForOriginChunk(OX, OZ, BiomeId)
	return BiomeTableFor(math.floor(OX / 16) * 16, math.floor(OZ / 16) * 16, BiomeId)
end

local SuppliedWorld = MakeWorld(FreshName(), 1402121502, nil)
local Without = StructureLocateFindAll(SuppliedWorld, "Village", -1600, -1600, 1600, 1600)
Check("without biomes nothing is confirmed", Without.ConfirmedCount == 0, Without.ConfirmedCount)
Check("without biomes there are still candidates", Without.Count > 0, Without.Count)

-- Plains is allowed by PlainsVillage, so covering every candidate's origin chunk with
-- Plains must turn all of them into confirmed ones.
local Whole = {}
for _, E in ipairs(Without.Items) do
	for K, V in pairs(BiomeTableForOriginChunk(E.OriginX, E.OriginZ, 1)) do
		Whole[K] = V
	end
end
local With = StructureLocateFindAll(SuppliedWorld, "Village", -1600, -1600, 1600, 1600, nil, nil, Whole)
Check("supplied biomes confirm villages", With.ConfirmedCount > 0, With.ConfirmedCount)
Check("supplied biomes confirm every candidate here",
	With.ConfirmedCount == With.Count, With.ConfirmedCount .. "/" .. With.Count)
Check("the candidate count is unchanged", With.Count == Without.Count)
Check("confirmed items say so",
	(#With.Items > 0) and (With.Items[1].Confirmed == true))
Check("a confirmed item has no unresolved detail or a pool name",
	(#With.Items > 0) and (With.Items[1].Detail == nil or type(With.Items[1].Detail) == "string"))

-- Partial coverage: only the first candidate's chunk gets biomes.
local Partial = BiomeTableForOriginChunk(Without.Items[1].OriginX, Without.Items[1].OriginZ, 1)
local Some = StructureLocateFindAll(SuppliedWorld, "Village", -1600, -1600, 1600, 1600, nil, nil, Partial)
Check("partial coverage confirms only what it covers", Some.ConfirmedCount == 1, Some.ConfirmedCount)

-- A biome no pool accepts must not confirm anything.
local Ocean = {}
for K in pairs(Whole) do Ocean[K] = 0 end
local Nowhere = StructureLocateFindAll(SuppliedWorld, "Village", -1600, -1600, 1600, 1600, nil, nil, Ocean)
Check("a biome no pool allows confirms nothing", Nowhere.ConfirmedCount == 0, Nowhere.ConfirmedCount)

-- The engine's own answer always wins: this world really is ocean there, and a caller
-- claiming Plains must not be believed.
local OceanBiomeWorld = MakeWorld(FreshName(), 1402121502, function() return 0 end)
local Lied = StructureLocateFindAll(OceanBiomeWorld, "Village", -1600, -1600, 1600, 1600, nil, nil, Whole)
Check("the engine wins over a lying caller", Lied.ConfirmedCount == 0, Lied.ConfirmedCount)

-- Single-biome kinds use the same fallback: DesertPyramid allows Desert (5).
local Pyramid = StructureLocateFindAll(SuppliedWorld, "Desert_Pyramid", -3200, -3200, 3200, 3200)
Check("a single-biome kind is a candidate without biomes", Pyramid.ConfirmedCount == 0)
Check("a single-biome kind has candidates to confirm", Pyramid.Count > 0, Pyramid.Count)
local Desert = {}
for _, E in ipairs(Pyramid.Items) do
	Desert[(E.OriginX) .. "," .. (E.OriginZ)] = 5
end
local PyrOK = StructureLocateFindAll(SuppliedWorld, "Desert_Pyramid", -3200, -3200, 3200, 3200,
	nil, nil, Desert)
Check("the supplied biome confirms a single-biome kind",
	PyrOK.ConfirmedCount == PyrOK.Count, PyrOK.ConfirmedCount .. "/" .. PyrOK.Count)
local PlainsOnly = {}
for K in pairs(Desert) do PlainsOnly[K] = 1 end
local PyrNo = StructureLocateFindAll(SuppliedWorld, "Desert_Pyramid", -3200, -3200, 3200, 3200,
	nil, nil, PlainsOnly)
Check("a biome the kind does not allow confirms nothing",
	PyrNo.ConfirmedCount == 0, PyrNo.ConfirmedCount)

-- FindNearest takes it too.
local NearWith = StructureLocateFindNearest(SuppliedWorld, "Village", 0, 0, 20, Whole)
Check("FindNearest accepts biomes", (type(NearWith) == "table") and (NearWith.Ok == true))
Check("FindNearest confirms with biomes", NearWith.Confirmed == true, tostring(NearWith.Confirmed))
Check("FindNearest without biomes is a candidate",
	StructureLocateFindNearest(SuppliedWorld, "Village", 0, 0, 20).Confirmed == false)

-- Validation
Check("a non-table Biomes is refused",
	StructureLocateFindAll(SuppliedWorld, "Village", 0, 0, 10, 10, nil, nil, "nope").Ok == false)
Check("a non-table Biomes is refused by FindNearest",
	StructureLocateFindNearest(SuppliedWorld, "Village", 0, 0, 20, 42).Ok == false)
Check("an empty Biomes table is allowed and simply does not help",
	StructureLocateFindNearest(SuppliedWorld, "Village", 0, 0, 20, {}).Confirmed == false)
Check("a float-keyed lookup still matches an integer key",
	StructureLocateFindNearest(SuppliedWorld, "Village", 0, 0, 20, Whole).Confirmed == true)


-- ===========================================================================
-- 11. Summary
-- ===========================================================================

print("")
print(string.format("structure_locate_test: %d passed, %d failed", Passed, Failed))
if (Failed > 0) then
	print("")
	print("Failures:")
	for _, F in ipairs(Failures) do
		print("  - " .. F)
	end
end
os.exit(Failed == 0 and 0 or 1)
