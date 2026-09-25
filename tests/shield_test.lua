-- tests/shield_test.lua
-- Offline robustness test for the shield state machine of VanillaFeatureComplement.
--
-- The shield support has no dedicated engine hook: it reconstructs "the offhand
-- shield is raised" from the generic item-use hooks.  This suite drives the shipped
-- handlers (CheckUseShieldOnUsingItem / OnRightClick / OnShooting / OnTossingItem /
-- OnTick / OnTakeDamage / OnProjectileHitEntity) against a mock Cuberite API and
-- checks two things for every item the engine can put in a hand:
--
--   1. robustness  - the handler must never raise a Lua error (pcall)
--   2. correctness - the offhand shield must raise exactly when the right-click was
--                    *not* consumed by the main-hand item
--
-- The expected consumption per item comes from the engine, not from intuition:
--   * src/ClientHandle.cpp HandleRightClick / HandleUseItem  (when the hooks fire)
--   * src/Items/ItemHandler.cpp                              (handler per itemtype)
--   * the individual src/Items/Item*.h handlers              (consumption rules)
-- A copy of those dispatch rules is summarised in comments at each section.
--
-- Usage (from the plugin folder):
--     lua    tests/shield_test.lua
--     luajit tests/shield_test.lua      -- Lua 5.1 compat (Cuberite embeds 5.1)
--
-- Exit code 0 when every check passed, 1 otherwise.

-- ===========================================================================
-- 1. Engine globals (mock)
-- ===========================================================================

-- Every E_ITEM_ constant of the installed Cuberite build, taken from the server
-- binary.  Only identity matters for the state machine, so the values are synthetic.
-- The item name list is generated data; its long lines are not interesting.
-- luacheck: push ignore 631
local ITEM_NAMES = [[
	E_ITEM_11_DISC E_ITEM_13_DISC E_ITEM_ACACIA_BOAT E_ITEM_ACACIA_DOOR E_ITEM_ARMOR_STAND E_ITEM_ARROW
	E_ITEM_BAKED_POTATO E_ITEM_BANNER E_ITEM_BED E_ITEM_BEETROOT E_ITEM_BEETROOT_SEEDS E_ITEM_BEETROOT_SOUP
	E_ITEM_BIRCH_BOAT E_ITEM_BIRCH_DOOR E_ITEM_BLAZE_POWDER E_ITEM_BLAZE_ROD E_ITEM_BLOCKS_DISC E_ITEM_BOAT
	E_ITEM_BONE E_ITEM_BOOK E_ITEM_BOOK_AND_QUILL E_ITEM_BOTTLE_O_ENCHANTING E_ITEM_BOW E_ITEM_BOWL
	E_ITEM_BREAD E_ITEM_BREWING_STAND E_ITEM_BUCKET E_ITEM_CAKE E_ITEM_CARROT E_ITEM_CARROT_ON_STICK
	E_ITEM_CAT_DISC E_ITEM_CAULDRON E_ITEM_CHAIN_BOOTS E_ITEM_CHAIN_CHESTPLATE E_ITEM_CHAIN_HELMET E_ITEM_CHAIN_LEGGINGS
	E_ITEM_CHEST_MINECART E_ITEM_CHIRP_DISC E_ITEM_CHORUS_FRUIT E_ITEM_CLAY E_ITEM_CLAY_BRICK E_ITEM_CLOCK
	E_ITEM_COAL E_ITEM_COMPARATOR E_ITEM_COMPASS E_ITEM_COOKED_CHICKEN E_ITEM_COOKED_FISH E_ITEM_COOKED_MUTTON
	E_ITEM_COOKED_PORKCHOP E_ITEM_COOKED_RABBIT E_ITEM_COOKIE E_ITEM_DARK_OAK_BOAT E_ITEM_DARK_OAK_DOOR E_ITEM_DIAMOND
	E_ITEM_DIAMOND_AXE E_ITEM_DIAMOND_BOOTS E_ITEM_DIAMOND_CHESTPLATE E_ITEM_DIAMOND_HELMET E_ITEM_DIAMOND_HOE E_ITEM_DIAMOND_HORSE_ARMOR
	E_ITEM_DIAMOND_LEGGINGS E_ITEM_DIAMOND_PICKAXE E_ITEM_DIAMOND_SHOVEL E_ITEM_DIAMOND_SWORD E_ITEM_DRAGON_BREATH E_ITEM_DYE
	E_ITEM_EGG E_ITEM_ELYTRA E_ITEM_EMERALD E_ITEM_EMPTY E_ITEM_EMPTY_MAP E_ITEM_ENCHANTED_BOOK
	E_ITEM_END_CRYSTAL E_ITEM_ENDER_PEARL E_ITEM_EYE_OF_ENDER E_ITEM_FAR_DISC E_ITEM_FEATHER E_ITEM_FERMENTED_SPIDER_EYE
	E_ITEM_FIRE_CHARGE E_ITEM_FIREWORK_ROCKET E_ITEM_FIREWORK_STAR E_ITEM_FIRST E_ITEM_FIRST_DISC E_ITEM_FISHING_ROD
	E_ITEM_FLINT E_ITEM_FLINT_AND_STEEL E_ITEM_FLOWER_POT E_ITEM_FURNACE_MINECART E_ITEM_GHAST_TEAR E_ITEM_GLASS_BOTTLE
	E_ITEM_GLISTERING_MELON E_ITEM_GLOWSTONE_DUST E_ITEM_GOLD E_ITEM_GOLD_AXE E_ITEM_GOLD_BOOTS E_ITEM_GOLD_CHESTPLATE
	E_ITEM_GOLDEN_APPLE E_ITEM_GOLDEN_CARROT E_ITEM_GOLD_HELMET E_ITEM_GOLD_HOE E_ITEM_GOLD_HORSE_ARMOR E_ITEM_GOLD_LEGGINGS
	E_ITEM_GOLD_NUGGET E_ITEM_GOLD_PICKAXE E_ITEM_GOLD_SHOVEL E_ITEM_GOLD_SWORD E_ITEM_GUNPOWDER E_ITEM_HEAD
	E_ITEM_IRON E_ITEM_IRON_AXE E_ITEM_IRON_BOOTS E_ITEM_IRON_CHESTPLATE E_ITEM_IRON_DOOR E_ITEM_IRON_HELMET
	E_ITEM_IRON_HOE E_ITEM_IRON_HORSE_ARMOR E_ITEM_IRON_LEGGINGS E_ITEM_IRON_NUGGET E_ITEM_IRON_PICKAXE E_ITEM_IRON_SHOVEL
	E_ITEM_IRON_SWORD E_ITEM_ITEM_FRAME E_ITEM_JUNGLE_BOAT E_ITEM_JUNGLE_DOOR E_ITEM_LAST E_ITEM_LAST_DISC
	E_ITEM_LAST_DISC_PLUS_ONE E_ITEM_LAVA_BUCKET E_ITEM_LEAD E_ITEM_LEASH E_ITEM_LEATHER E_ITEM_LEATHER_BOOTS
	E_ITEM_LEATHER_CAP E_ITEM_LEATHER_PANTS E_ITEM_LEATHER_TUNIC E_ITEM_LINGERING_POTION E_ITEM_MAGMA_CREAM E_ITEM_MALL_DISC
	E_ITEM_MAP E_ITEM_MAX_CONSECUTIVE_TYPE_ID E_ITEM_MELLOHI_DISC E_ITEM_MELON_SEEDS E_ITEM_MELON_SLICE E_ITEM_MILK
	E_ITEM_MINECART E_ITEM_MINECART_WITH_COMMAND_BLOCK E_ITEM_MINECART_WITH_HOPPER E_ITEM_MINECART_WITH_TNT E_ITEM_MUSHROOM_SOUP E_ITEM_NAME_TAG
	E_ITEM_NETHER_BRICK E_ITEM_NETHER_QUARTZ E_ITEM_NETHER_STAR E_ITEM_NETHER_WART E_ITEM_NUMBER_OF_CONSECUTIVE_TYPES E_ITEM_PAINTING
	E_ITEM_PAPER E_ITEM_POISONOUS_POTATO E_ITEM_POPPED_CHORUS_FRUIT E_ITEM_POTATO E_ITEM_POTION E_ITEM_POTIONS
	E_ITEM_PRISMARINE_CRYSTALS E_ITEM_PRISMARINE_SHARD E_ITEM_PUMPKIN_PIE E_ITEM_PUMPKIN_SEEDS E_ITEM_RABBIT_HIDE E_ITEM_RABBITS_FOOT
	E_ITEM_RABBIT_STEW E_ITEM_RAW_BEEF E_ITEM_RAW_CHICKEN E_ITEM_RAW_FISH E_ITEM_RAW_MUTTON E_ITEM_RAW_PORKCHOP
	E_ITEM_RAW_RABBIT E_ITEM_RED_APPLE E_ITEM_REDSTONE_DUST E_ITEM_REDSTONE_REPEATER E_ITEM_ROTTEN_FLESH E_ITEM_SADDLE
	E_ITEM_SEEDS E_ITEM_SHEARS E_ITEM_SHIELD E_ITEM_SHULKER_SHELL E_ITEM_SIGN E_ITEM_SLIMEBALL
	E_ITEM_SNOWBALL E_ITEM_SPAWN_EGG E_ITEM_SPECTRAL_ARROW E_ITEM_SPIDER_EYE E_ITEM_SPLASH_POTION E_ITEM_SPRUCE_BOAT
	E_ITEM_SPRUCE_DOOR E_ITEM_STAL_DISC E_ITEM_STEAK E_ITEM_STICK E_ITEM_STONE_AXE E_ITEM_STONE_HOE
	E_ITEM_STONE_PICKAXE E_ITEM_STONE_SHOVEL E_ITEM_STONE_SWORD E_ITEM_STRAD_DISC E_ITEM_STRING E_ITEM_SUGAR
	E_ITEM_SUGAR_CANE E_ITEM_SUGARCANE E_ITEM_TIPPED_ARROW E_ITEM_TOTEM_OF_UNDYING E_ITEM_WAIT_DISC E_ITEM_WARD_DISC
	E_ITEM_WATER_BUCKET E_ITEM_WHEAT E_ITEM_WOODEN_AXE E_ITEM_WOODEN_DOOR E_ITEM_WOODEN_HOE E_ITEM_WOODEN_PICKAXE
	E_ITEM_WOODEN_SHOVEL E_ITEM_WOODEN_SWORD E_ITEM_WRITTEN_BOOK
]]
-- luacheck: pop
local NextItemId = 1000
for Name in ITEM_NAMES:gmatch("%S+") do
	NextItemId = NextItemId + 1
	_G[Name] = NextItemId
end

-- Block types used by the shield logic (a subset, with distinct values).
E_BLOCK_AIR              = 0
E_BLOCK_STONE            = 1
E_BLOCK_GRASS            = 2
E_BLOCK_DIRT             = 3
E_BLOCK_BEDROCK          = 7
E_BLOCK_WATER            = 8
E_BLOCK_STATIONARY_WATER = 9
E_BLOCK_LAVA             = 10
E_BLOCK_STATIONARY_LAVA  = 11
E_BLOCK_POWERED_RAIL     = 27
E_BLOCK_DETECTOR_RAIL    = 28
E_BLOCK_OBSIDIAN         = 49
E_BLOCK_RAIL             = 66
E_BLOCK_ACTIVATOR_RAIL   = 157

BLOCK_FACE_NONE = -1

dtAttack       = 1
dtRangedAttack = 2
dtExplosion    = 3
dtFall         = 4

cProjectileEntity =
{
	pkArrow        = 1,
	pkGhastFireball = 2,
	pkSplashPotion = 3,
	pkSnowball     = 4,
}

cEnchantments = { enchUnbreaking = 17 }

-- --- vectors ---------------------------------------------------------------

local VecMT = {}
VecMT.__index = VecMT

local function NewVec(a_X, a_Y, a_Z)
	return setmetatable({ x = a_X or 0, y = a_Y or 0, z = a_Z or 0 }, VecMT)
end

VecMT.__add = function(a, b) return NewVec(a.x + b.x, a.y + b.y, a.z + b.z) end
VecMT.__sub = function(a, b) return NewVec(a.x - b.x, a.y - b.y, a.z - b.z) end
VecMT.__mul = function(a, b)
	if (type(a) == "number") then return NewVec(a * b.x, a * b.y, a * b.z) end
	if (type(b) == "number") then return NewVec(a.x * b, a.y * b, a.z * b) end
	return (a.x * b.x) + (a.y * b.y) + (a.z * b.z)
end
function VecMT:Normalize()
	local L = math.sqrt((self.x * self.x) + (self.y * self.y) + (self.z * self.z))
	if (L > 0) then
		self.x, self.y, self.z = self.x / L, self.y / L, self.z / L
	end
	return self
end
function VecMT:SqrLength() return (self.x * self.x) + (self.y * self.y) + (self.z * self.z) end
function VecMT:Dot(a_Other) return (self.x * a_Other.x) + (self.y * a_Other.y) + (self.z * a_Other.z) end

local function Conv(a_V) return NewVec(a_V.x or a_V.X, a_V.y or a_V.Y, a_V.z or a_V.Z) end
function Vector3d(a_X, a_Y, a_Z)
	if (type(a_X) == "table") then return Conv(a_X) end
	return NewVec(a_X, a_Y, a_Z)
end
function Vector3i(a_X, a_Y, a_Z)
	if (type(a_X) == "table") then return Conv(a_X) end
	return NewVec(a_X, a_Y, a_Z)
end

-- --- items -----------------------------------------------------------------

local EmptyItemType = -1

local function NewEnch(a_Levels)
	return { GetLevel = function(_, a_Ench) return a_Levels[a_Ench] or 0 end }
end

local ItemMT = {}
ItemMT.__index = ItemMT

local function NewItem(a_Type, a_Count, a_Damage, a_Lore, a_Ench)
	return setmetatable({
		m_ItemType     = a_Type,
		m_ItemCount    = a_Count or 0,
		m_ItemDamage   = a_Damage or 0,
		m_LoreTable    = a_Lore,
		m_Enchantments = a_Ench or NewEnch({}),
	}, ItemMT)
end

function ItemMT:IsEmpty()
	return (self.m_ItemType == nil) or (self.m_ItemType == EmptyItemType) or (self.m_ItemType <= 0)
end
function ItemMT:IsSameType(a_Other)
	return (a_Other ~= nil) and (a_Other.m_ItemType == self.m_ItemType)
end
function ItemMT:IsCustomNameEmpty() return true end
function ItemMT:GetMaxStackSize() return 64 end

local function EmptyItem() return NewItem(EmptyItemType, 0) end

function cItem(a_Type, a_Count, a_Damage, a_Ench)
	if (a_Type == nil) then
		return EmptyItem()
	end
	if (type(a_Type) == "table") then
		-- Copy constructor: unlike the engine userdata this is a plain table, so the
		-- lore table must be copied explicitly (the plugin relies on that: it edits the
		-- copy and writes it back with SetShieldSlot / SetEquippedItem).
		local Lore = nil
		if (a_Type.m_LoreTable ~= nil) then
			Lore = {}
			for i, Line in ipairs(a_Type.m_LoreTable) do
				Lore[i] = Line
			end
		end
		return NewItem(a_Type.m_ItemType, a_Type.m_ItemCount, a_Type.m_ItemDamage, Lore, a_Type.m_Enchantments)
	end
	-- a_Ench used to be dropped here, which silently discarded the enchantments of
	-- every item built with the 4-argument form (the real cItem constructor keeps
	-- them).
	return NewItem(a_Type, a_Count or 1, a_Damage or 0, nil, a_Ench or NewEnch({}))
end

-- --- world / tracer --------------------------------------------------------

local Blocks    = {}    -- "x,y,z" -> block type
local RayHits   = {}    -- blocks the eye ray passes through, near to far
local SolidHit  = false -- what FirstSolidHitTrace() reports
local Sounds    = {}    -- broadcast sound names

local function BlockKey(a_X, a_Y, a_Z) return a_X .. "," .. a_Y .. "," .. a_Z end

World = { Players = {} }

function World:GetBlock(a_Pos)
	return Blocks[BlockKey(a_Pos.x, a_Pos.y, a_Pos.z)] or E_BLOCK_AIR
end
function World:BroadcastSoundEffect(a_Name)
	Sounds[#Sounds + 1] = a_Name
	return true
end
function World:ForEachPlayer(a_Callback)
	for _, P in ipairs(World.Players) do
		a_Callback(P)
	end
end

cLineBlockTracer =
{
	-- Called with colon syntax: (self, world, callbacks, start, end).
	Trace = function(_, _a_World, a_Callbacks, _a_Start, _a_End)
		for _, Hit in ipairs(RayHits) do
			if (a_Callbacks.OnNextBlock(Vector3i(Hit.X, Hit.Y, Hit.Z), Hit.Type, 0, 0)) then
				return
			end
		end
	end,
	FirstSolidHitTrace = function() return SolidHit end,
}

LOG = function() end

-- --- players ---------------------------------------------------------------

local PlayerCount = 0

-- a_Options:
--   main/off        cItem in the main / off hand (nil = engine returns nothing)
--   creative        gamemode
--   satiated       IsSatiated()
--   elytra          IsElytraFlying()
--   helmet/chest/legs/boots   equipped armour (nil = empty)
--   arrows          inventory has an arrow
local function NewPlayer(a_Options)
	a_Options = a_Options or {}
	PlayerCount = PlayerCount + 1

	local S =
	{
		main     = a_Options.main,
		off      = a_Options.off,
		creative = a_Options.creative or false,
		satiated = a_Options.satiated or false,
		elytra   = a_Options.elytra or false,
		helmet   = a_Options.helmet,
		chest    = a_Options.chest,
		legs     = a_Options.legs,
		boots    = a_Options.boots,
		arrows   = a_Options.arrows or false,
		uuid     = "00000000-0000-0000-0000-" .. string.format("%012d", PlayerCount),
		name     = "Tester" .. PlayerCount,
	}

	local P = { State = S }

	function P:GetUUID() return S.uuid end
	function P:GetName() return S.name end
	function P:IsPlayer() return true end
	function P:GetHealth() return 20 end
	function P:GetMain() return S.main end
	function P:GetOff() return S.off end

	function P:GetEquippedItem() return S.main end
	function P:GetOffHandEquipedItem() return S.off end
	function P:GetEquippedHelmet() return S.helmet or EmptyItem() end
	function P:GetEquippedChestplate() return S.chest or EmptyItem() end
	function P:GetEquippedLeggings() return S.legs or EmptyItem() end
	function P:GetEquippedBoots() return S.boots or EmptyItem() end

	function P:IsGameModeCreative() return S.creative end
	function P:IsGameModeAdventure() return false end
	function P:IsGameModeSpectator() return false end
	function P:IsSatiated() return S.satiated end
	function P:IsElytraFlying() return S.elytra end
	function P:IsCrouched() return false end

	function P:GetWorld() return World end
	function P:GetPosition() return Vector3d(0, 0, 0) end
	function P:GetEyePosition() return Vector3d(0, 1.6, 0) end
	function P:GetLookVector() return Vector3d(0, 0, 1) end
	function P:GetPosX() return 0 end
	function P:GetPosY() return 0 end
	function P:GetPosZ() return 0 end

	local Inventory = {}
	Inventory.m_Player = P
	function Inventory:HasItems(a_Item)
		return S.arrows and (a_Item.m_ItemType == E_ITEM_ARROW)
	end
	function Inventory:SetEquippedItem(a_Item) S.main = a_Item end
	function Inventory:SetShieldSlot(a_Item) S.off = a_Item end
	function Inventory:RemoveOneEquippedItem()
		if (S.main ~= nil) and not S.main:IsEmpty() then S.main.m_ItemCount = S.main.m_ItemCount - 1 end
	end
	function P:GetInventory() return Inventory end

	return P
end

-- ===========================================================================
-- 2. Load the plugin under test
-- ===========================================================================

local ScriptPath = (arg and arg[0]) or "tests/shield_test.lua"
local ScriptDir = ScriptPath:match("^(.*)[/\\][^/\\]*$") or "."
local PluginDir = ScriptDir .. "/.."

dofile(PluginDir .. "/main.lua")
dofile(PluginDir .. "/shield.lua")

-- ===========================================================================
-- 3. Assertions and scenario helpers
-- ===========================================================================

local Passed = 0
local Failed = 0
local Failures = {}

local function Check(a_Name, a_Ok, a_Detail)
	if a_Ok then
		Passed = Passed + 1
	else
		Failed = Failed + 1
		Failures[#Failures + 1] = a_Name .. (a_Detail and (" (" .. a_Detail .. ")") or "")
		print(string.format("FAIL: %s%s", a_Name, a_Detail and (" (" .. a_Detail .. ")") or ""))
	end
end

local function IsRaised(a_Player)
	local State = GetPlayerState(a_Player)
	return State.IsUsingShield == true
end

local function Const(a_Name) return _G[a_Name] end

-- Fire one HOOK_PLAYER_USING_ITEM event.
--   a_Scene.air      true  -> reported coords are the (-1,255,-1) sentinel (HandleUseItem)
--                    false -> a real block click at (0,0,1)
--   a_Scene.target   block type the player is aiming at (world block for a block click,
--                    eye-ray hit for an air use).  nil = aiming at nothing.
--   a_Scene.solidHit what FirstSolidHitTrace reports (bucket placement)
-- Returns the pcall result.
local function FireUsingItem(a_Player, a_Scene)
	a_Scene = a_Scene or {}
	Blocks = {}
	RayHits = {}
	SolidHit = a_Scene.solidHit or false

	local X, Y, Z, Face
	if a_Scene.air then
		X, Y, Z, Face = -1, 255, -1, BLOCK_FACE_NONE
	else
		X, Y, Z, Face = 0, 0, 1, 1
		Blocks[BlockKey(0, 0, 1)] = a_Scene.target or E_BLOCK_AIR
	end
	if (a_Scene.target ~= nil) and a_Scene.air then
		RayHits[1] = { X = 0, Y = 0, Z = 1, Type = a_Scene.target }
	end
	return pcall(CheckUseShieldOnUsingItem, a_Player, X, Y, Z, Face, 0, 0, 0)
end

-- Offhand-shield scenario: main hand holds a_Name, off hand a shield.
-- a_Expected is the desired IsUsingShield value after the event.
local function OffhandCase(a_Name, a_ItemName, a_Scene, a_Expected, a_PlayerOptions)
	a_PlayerOptions = a_PlayerOptions or {}
	a_PlayerOptions.main = cItem(Const(a_ItemName))
	a_PlayerOptions.off = cItem(E_ITEM_SHIELD)
	local P = NewPlayer(a_PlayerOptions)
	local Ok, Err = FireUsingItem(P, a_Scene)
	Check(a_Name .. ": no Lua error", Ok, tostring(Err))
	if Ok then
		Check(a_Name, IsRaised(P) == a_Expected,
			"raised=" .. tostring(IsRaised(P)) .. " wanted=" .. tostring(a_Expected))
	end
	return P
end

local function Loop(a_Names, a_Fn)
	for _, N in ipairs(a_Names) do
		a_Fn(N)
	end
end

-- ===========================================================================
-- 4. Right-click a block / air WITH the offhand shield up
-- ===========================================================================
-- Engine dispatch (ClientHandle.cpp HandleRightClick, face >= 0):
--   usable block            -> block interaction, no USING_ITEM
--   placeable main item     -> placement,        no USING_ITEM
--   otherwise               -> USING_ITEM + OnItemUse
-- HandleUseItem (right-click air, face == BLOCK_FACE_NONE):
--   IsFood() || IsDrinkable() -> HOOK_PLAYER_EATING only, no USING_ITEM
--   otherwise                 -> USING_ITEM + OnItemUse
-- In both cases HOOK_PLAYER_RIGHT_CLICK fires first.

local ProjectileNames =
{
	"E_ITEM_SNOWBALL", "E_ITEM_EGG", "E_ITEM_ENDER_PEARL", "E_ITEM_EYE_OF_ENDER",
	"E_ITEM_SPLASH_POTION", "E_ITEM_BOTTLE_O_ENCHANTING", "E_ITEM_LINGERING_POTION",
}

local BoatNames =
{
	"E_ITEM_BOAT", "E_ITEM_SPRUCE_BOAT", "E_ITEM_BIRCH_BOAT", "E_ITEM_JUNGLE_BOAT",
	"E_ITEM_ACACIA_BOAT", "E_ITEM_DARK_OAK_BOAT",
}

local MinecartNames =
{
	"E_ITEM_MINECART", "E_ITEM_CHEST_MINECART", "E_ITEM_FURNACE_MINECART",
	"E_ITEM_MINECART_WITH_TNT", "E_ITEM_MINECART_WITH_HOPPER",
}

local HoeNames =
{
	"E_ITEM_WOODEN_HOE", "E_ITEM_STONE_HOE", "E_ITEM_IRON_HOE",
	"E_ITEM_GOLD_HOE", "E_ITEM_DIAMOND_HOE",
}

local ShovelNames =
{
	"E_ITEM_WOODEN_SHOVEL", "E_ITEM_STONE_SHOVEL", "E_ITEM_IRON_SHOVEL",
	"E_ITEM_GOLD_SHOVEL", "E_ITEM_DIAMOND_SHOVEL",
}

local HelmetNames =
{
	"E_ITEM_LEATHER_CAP", "E_ITEM_GOLD_HELMET", "E_ITEM_CHAIN_HELMET",
	"E_ITEM_IRON_HELMET", "E_ITEM_DIAMOND_HELMET",
}

local ChestplateNames =
{
	"E_ITEM_LEATHER_TUNIC", "E_ITEM_GOLD_CHESTPLATE", "E_ITEM_CHAIN_CHESTPLATE",
	"E_ITEM_IRON_CHESTPLATE", "E_ITEM_DIAMOND_CHESTPLATE", "E_ITEM_ELYTRA",
}

local LeggingsNames =
{
	"E_ITEM_LEATHER_PANTS", "E_ITEM_GOLD_LEGGINGS", "E_ITEM_CHAIN_LEGGINGS",
	"E_ITEM_IRON_LEGGINGS", "E_ITEM_DIAMOND_LEGGINGS",
}

local BootsNames =
{
	"E_ITEM_LEATHER_BOOTS", "E_ITEM_GOLD_BOOTS", "E_ITEM_CHAIN_BOOTS",
	"E_ITEM_IRON_BOOTS", "E_ITEM_DIAMOND_BOOTS",
}

-- Ordinary armour: cItemArmorHandler, consumed only when the slot is empty.
local ArmorBySlot =
{
	{ Items = HelmetNames,     Slot = "helmet" },
	{ Items = ChestplateNames, Slot = "chest"  },
	{ Items = LeggingsNames,   Slot = "legs"   },
	{ Items = BootsNames,      Slot = "boots"  },
}

-- Foods recognised by the engine as IsFood() (src/Items/ItemHandler.cpp):
-- cItemSimpleFoodHandler + cItemSoupHandler + cItemFoodSeedsHandler + the
-- per-item food handlers.  Golden apple / chorus fruit are handled separately
-- below because the engine exempts them from the creative/satiated guard.
local EngineFoodNames =
{
	"E_ITEM_RED_APPLE", "E_ITEM_BREAD", "E_ITEM_RAW_PORKCHOP", "E_ITEM_COOKED_PORKCHOP",
	"E_ITEM_RAW_FISH", "E_ITEM_COOKED_FISH", "E_ITEM_RAW_BEEF", "E_ITEM_STEAK",
	"E_ITEM_RAW_CHICKEN", "E_ITEM_COOKED_CHICKEN", "E_ITEM_ROTTEN_FLESH",
	"E_ITEM_RAW_MUTTON", "E_ITEM_COOKED_MUTTON", "E_ITEM_RAW_RABBIT", "E_ITEM_COOKED_RABBIT",
	"E_ITEM_RABBIT_STEW", "E_ITEM_BEETROOT", "E_ITEM_BEETROOT_SOUP", "E_ITEM_MUSHROOM_SOUP",
	"E_ITEM_CARROT", "E_ITEM_POTATO", "E_ITEM_BAKED_POTATO", "E_ITEM_POISONOUS_POTATO",
	"E_ITEM_GOLDEN_CARROT", "E_ITEM_PUMPKIN_PIE", "E_ITEM_MELON_SLICE", "E_ITEM_SPIDER_EYE",
	"E_ITEM_COOKIE",
}

-- Items the plugin is not expected to know: they are usable in no way at all
-- (cDefaultItemHandler), so a right-click is never consumed.
local InertNames =
{
	"E_ITEM_WOODEN_SWORD", "E_ITEM_STONE_SWORD", "E_ITEM_DIAMOND_SWORD",
	"E_ITEM_WOODEN_PICKAXE", "E_ITEM_DIAMOND_PICKAXE", "E_ITEM_IRON_AXE",
	"E_ITEM_STICK", "E_ITEM_BONE", "E_ITEM_FEATHER", "E_ITEM_IRON",
	"E_ITEM_DIAMOND", "E_ITEM_COAL", "E_ITEM_STRING", "E_ITEM_PAPER",
	"E_ITEM_SHULKER_SHELL", "E_ITEM_TOTEM_OF_UNDYING", "E_ITEM_SUGAR",
}

print("== A. offhand shield: always-consumed throwables ==")
Loop(ProjectileNames, function(N)
	OffhandCase(N .. " air use", N, { air = true }, false)
	OffhandCase(N .. " block use", N, { target = E_BLOCK_STONE }, false)
end)
OffhandCase("fishing rod air use", "E_ITEM_FISHING_ROD", { air = true }, false)
OffhandCase("fishing rod block use", "E_ITEM_FISHING_ROD", { target = E_BLOCK_STONE }, false)
OffhandCase("golden apple (special food)", "E_ITEM_GOLDEN_APPLE", { target = E_BLOCK_STONE }, false)
OffhandCase("chorus fruit (special food)", "E_ITEM_CHORUS_FRUIT", { target = E_BLOCK_STONE }, false)
OffhandCase("milk (drinkable)", "E_ITEM_MILK", { target = E_BLOCK_STONE }, false)
OffhandCase("potion (drinkable)", "E_ITEM_POTION", { target = E_BLOCK_STONE }, false)
OffhandCase("empty map (creates a map)", "E_ITEM_EMPTY_MAP", { air = true }, false)
OffhandCase("empty map aimed at a block", "E_ITEM_EMPTY_MAP", { target = E_BLOCK_STONE }, false)

print("== B. offhand shield: bow ==")
OffhandCase("bow + arrows", "E_ITEM_BOW", { air = true }, false, { arrows = true })
OffhandCase("bow in creative", "E_ITEM_BOW", { air = true }, false, { creative = true })
OffhandCase("bow without arrows", "E_ITEM_BOW", { air = true }, true)
OffhandCase("bow without arrows, block use", "E_ITEM_BOW", { target = E_BLOCK_STONE }, true)

print("== C. offhand shield: buckets ==")
OffhandCase("empty bucket on water", "E_ITEM_BUCKET", { target = E_BLOCK_STATIONARY_WATER }, false)
OffhandCase("empty bucket on flowing water", "E_ITEM_BUCKET", { target = E_BLOCK_WATER }, false)
OffhandCase("empty bucket on lava", "E_ITEM_BUCKET", { target = E_BLOCK_LAVA }, false)
OffhandCase("empty bucket on stone", "E_ITEM_BUCKET", { target = E_BLOCK_STONE }, true)
OffhandCase("empty bucket on nothing", "E_ITEM_BUCKET", { air = true }, true)
OffhandCase("water bucket onto a solid", "E_ITEM_WATER_BUCKET", { air = true, solidHit = true }, false)
OffhandCase("water bucket onto nothing", "E_ITEM_WATER_BUCKET", { air = true, solidHit = false }, true)
OffhandCase("lava bucket onto a solid", "E_ITEM_LAVA_BUCKET", { air = true, solidHit = true }, false)
OffhandCase("lava bucket onto nothing", "E_ITEM_LAVA_BUCKET", { air = true, solidHit = false }, true)

print("== D. offhand shield: boats / minecarts ==")
Loop(BoatNames, function(N)
	OffhandCase(N .. " on water", N, { target = E_BLOCK_STATIONARY_WATER }, false)
	OffhandCase(N .. " on stone", N, { target = E_BLOCK_STONE }, true)
	OffhandCase(N .. " on nothing", N, { air = true }, true)
end)
Loop(MinecartNames, function(N)
	OffhandCase(N .. " on a rail", N, { target = E_BLOCK_RAIL }, false)
	OffhandCase(N .. " on a powered rail", N, { target = E_BLOCK_POWERED_RAIL }, false)
	OffhandCase(N .. " on stone", N, { target = E_BLOCK_STONE }, true)
	OffhandCase(N .. " on nothing", N, { air = true }, true)
end)

print("== E. offhand shield: hoe / shovel ==")
Loop(HoeNames, function(N)
	OffhandCase(N .. " on grass", N, { target = E_BLOCK_GRASS }, false)
	OffhandCase(N .. " on dirt", N, { target = E_BLOCK_DIRT }, false)
	OffhandCase(N .. " on stone", N, { target = E_BLOCK_STONE }, true)
end)
Loop(ShovelNames, function(N)
	OffhandCase(N .. " on grass", N, { target = E_BLOCK_GRASS }, false)
	OffhandCase(N .. " on dirt", N, { target = E_BLOCK_DIRT }, false)
	OffhandCase(N .. " on stone", N, { target = E_BLOCK_STONE }, true)
end)

print("== F. offhand shield: armour ==")
for _, Group in ipairs(ArmorBySlot) do
	Loop(Group.Items, function(N)
		local Empty = {}
		OffhandCase(N .. " with an empty slot", N, { air = true }, false, Empty)
		local Worn = {}
		Worn[Group.Slot] = cItem(E_ITEM_DIAMOND_HELMET)
		OffhandCase(N .. " with the slot occupied", N, { air = true }, true, Worn)
	end)
end

print("== G. offhand shield: food ==")
Loop(EngineFoodNames, function(N)
	OffhandCase(N .. " while hungry", N, { target = E_BLOCK_STONE }, false, { satiated = false })
	OffhandCase(N .. " while satiated", N, { target = E_BLOCK_STONE }, true, { satiated = true })
end)

print("== H. offhand shield: flint and steel / fire charge / firework ==")
OffhandCase("flint and steel on stone", "E_ITEM_FLINT_AND_STEEL", { target = E_BLOCK_STONE }, false)
OffhandCase("flint and steel on water", "E_ITEM_FLINT_AND_STEEL", { target = E_BLOCK_WATER }, true)
OffhandCase("flint and steel on nothing", "E_ITEM_FLINT_AND_STEEL", { air = true }, true)
-- src/Items/ItemLighter.h is used for BOTH E_ITEM_FLINT_AND_STEEL and E_ITEM_FIRE_CHARGE
-- and only acts on a real block face (a_ClickedBlockFace < 0 -> return false).
OffhandCase("fire charge on stone", "E_ITEM_FIRE_CHARGE", { target = E_BLOCK_STONE }, false)
OffhandCase("fire charge on water", "E_ITEM_FIRE_CHARGE", { target = E_BLOCK_WATER }, true)
OffhandCase("fire charge on nothing", "E_ITEM_FIRE_CHARGE", { air = true }, true)
OffhandCase("firework, elytra flying", "E_ITEM_FIREWORK_ROCKET", { air = true }, false, { elytra = true })
OffhandCase("firework on stone", "E_ITEM_FIREWORK_ROCKET", { target = E_BLOCK_STONE }, false)
OffhandCase("firework on nothing", "E_ITEM_FIREWORK_ROCKET", { air = true }, true)

print("== I. offhand shield: spawn egg / glass bottle / end crystal ==")
OffhandCase("spawn egg on stone", "E_ITEM_SPAWN_EGG", { target = E_BLOCK_STONE }, false)
OffhandCase("spawn egg on water", "E_ITEM_SPAWN_EGG", { target = E_BLOCK_WATER }, false)
OffhandCase("spawn egg on nothing", "E_ITEM_SPAWN_EGG", { air = true }, true)
-- src/Items/ItemBottle.h: fills only from a water source along the look ray.
OffhandCase("glass bottle at water", "E_ITEM_GLASS_BOTTLE", { air = true, target = E_BLOCK_STATIONARY_WATER }, false)
OffhandCase("glass bottle at stone", "E_ITEM_GLASS_BOTTLE", { air = true, target = E_BLOCK_STONE }, true)
OffhandCase("glass bottle at nothing", "E_ITEM_GLASS_BOTTLE", { air = true }, true)
-- src/Items/ItemEndCrystal.h: places only on obsidian / bedrock.
OffhandCase("end crystal on obsidian", "E_ITEM_END_CRYSTAL", { target = E_BLOCK_OBSIDIAN }, false)
OffhandCase("end crystal on bedrock", "E_ITEM_END_CRYSTAL", { target = E_BLOCK_BEDROCK }, false)
OffhandCase("end crystal on stone", "E_ITEM_END_CRYSTAL", { target = E_BLOCK_STONE }, true)
OffhandCase("end crystal on nothing", "E_ITEM_END_CRYSTAL", { air = true }, true)

print("== J. offhand shield: inert items ==")
Loop(InertNames, function(N)
	OffhandCase(N .. " on stone", N, { target = E_BLOCK_STONE }, true)
	OffhandCase(N .. " on nothing", N, { air = true }, true)
end)

-- ===========================================================================
-- 5. HOOK_PLAYER_RIGHT_CLICK (right-click air, before any item use)
-- ===========================================================================

local function FireRightClick(a_Player, a_Scene)
	a_Scene = a_Scene or {}
	local X, Y, Z, Face
	if a_Scene.air then
		X, Y, Z, Face = -1, 255, -1, BLOCK_FACE_NONE
	else
		X, Y, Z, Face = 0, 0, 1, 1
	end
	return pcall(CheckUseShieldOnRightClick, a_Player, X, Y, Z, Face, 0, 0, 0)
end

local function RightClickCase(a_Name, a_MainItem, a_Options, a_Air, a_Expected)
	a_Options = a_Options or {}
	a_Options.main = a_MainItem and cItem(a_MainItem) or nil
	if not a_Options.NoShield then
		a_Options.off = cItem(E_ITEM_SHIELD)
	end
	local P = NewPlayer(a_Options)
	local Ok, Err = FireRightClick(P, { air = a_Air })
	Check(a_Name .. ": no Lua error", Ok, tostring(Err))
	if Ok then
		Check(a_Name, IsRaised(P) == a_Expected,
			"raised=" .. tostring(IsRaised(P)) .. " wanted=" .. tostring(a_Expected))
	end
	return P
end

print("== K. right-click-air handler ==")
RightClickCase("empty main hand raises the offhand shield", nil, nil, true, true)
-- Engine HandleUseItem blocks normal food in creative AND while satiated; the client
-- plays no eat animation in either case, so the offhand shield must raise.
RightClickCase("creative + normal food raises", Const("E_ITEM_RED_APPLE"), { creative = true }, true, true)
RightClickCase("satiated + normal food raises", Const("E_ITEM_RED_APPLE"), { satiated = true }, true, true)
RightClickCase("hungry + normal food does not raise", Const("E_ITEM_RED_APPLE"), { satiated = false }, true, false)
RightClickCase("creative + golden apple does not raise", Const("E_ITEM_GOLDEN_APPLE"), { creative = true }, true, false)
RightClickCase("creative + chorus fruit does not raise", Const("E_ITEM_CHORUS_FRUIT"), { creative = true }, true, false)
RightClickCase("inert item does not raise", Const("E_ITEM_STICK"), nil, true, false)
RightClickCase("block right-click never raises", nil, nil, false, false)
RightClickCase("no offhand shield never raises", nil, { NoShield = true }, true, false)

-- ===========================================================================
-- 6. State release: shooting, tossing, the world-tick safety net
-- ===========================================================================

local function RaisedPlayer()
	local P = NewPlayer({ main = cItem(E_ITEM_STICK), off = cItem(E_ITEM_SHIELD) })
	FireUsingItem(P, { air = true })   -- stick consumes nothing -> shield up
	Check("setup: shield raised", IsRaised(P))
	return P
end

print("== L. release paths ==")
do
	local P = RaisedPlayer()
	local Ok = pcall(CheckUseShieldOnShooting, P)
	Check("shooting: no Lua error", Ok)
	Check("shooting releases the shield", not IsRaised(P))
end
do
	-- Tossing an unrelated item while an offhand shield is still held keeps it up.
	local P = RaisedPlayer()
	local Ok = pcall(CheckUseShieldOnTossingItem, P)
	Check("tossing: no Lua error", Ok)
	Check("tossing an unrelated item keeps the shield up", IsRaised(P))
end
do
	-- Tossing the main-hand item while no shield remains lowers it.
	local P = NewPlayer({ main = cItem(E_ITEM_STICK) })
	FireRightClick(P, { air = true })
	local _ = P
	P = NewPlayer({ main = cItem(E_ITEM_STICK) })
	pcall(CheckUseShieldOnTossingItem, P)
	Check("tossing with no shield stays down", not IsRaised(P))
end
do
	-- World tick safety net: the raised shield left both hands.
	local P = RaisedPlayer()
	P.State.off = nil
	P.State.main = cItem(E_ITEM_STICK)
	World.Players = { P }
	local Ok = pcall(CheckUseShieldOnTick, World, 50, 50)
	Check("tick safety net: no Lua error", Ok)
	Check("tick safety net lowers a shield that left both hands", not IsRaised(P))
end
do
	-- World tick keeps a shield that is still held.
	local P = RaisedPlayer()
	World.Players = { P }
	pcall(CheckUseShieldOnTick, World, 50, 50)
	Check("tick safety net keeps a held shield up", IsRaised(P))
end
do
	-- Raise / release / raise again.
	local P = NewPlayer({ main = cItem(E_ITEM_STICK), off = cItem(E_ITEM_SHIELD) })
	FireUsingItem(P, { air = true })
	local First = IsRaised(P)
	pcall(CheckUseShieldOnShooting, P)
	local Second = IsRaised(P)
	FireUsingItem(P, { air = true })
	local Third = IsRaised(P)
	Check("raise/release/raise cycles", First and (not Second) and Third,
		tostring(First) .. "/" .. tostring(Second) .. "/" .. tostring(Third))
end
do
	-- A main-hand shield always raises, with or without an offhand shield.
	local P = NewPlayer({ main = cItem(E_ITEM_SHIELD) })
	local Ok = FireUsingItem(P, { air = true })
	Check("main-hand shield: no Lua error", Ok)
	Check("main-hand shield raises", IsRaised(P))
end
do
	-- No shield at all: the state is never set.
	local P = NewPlayer({ main = cItem(E_ITEM_STICK) })
	local Ok = FireUsingItem(P, { air = true })
	Check("no shield: no Lua error", Ok)
	Check("no shield: state stays unset", not IsRaised(P))
	Check("no shield: state table has no flag", GetPlayerState(P).IsUsingShield == nil)
end

-- ===========================================================================
-- 7. Damage blocking and shield durability
-- ===========================================================================

local LorePrefix = "Durability: "
local function ShieldWith(a_Remaining, a_Unbreaking)
	-- Remaining durability is carried in the damage field: damage = 336 - remaining.
	local Damage = 0
	if (a_Remaining ~= nil) then
		Damage = 336 - a_Remaining
	end
	local Levels = {}
	if (a_Unbreaking ~= nil) and (a_Unbreaking > 0) then
		Levels[cEnchantments.enchUnbreaking] = a_Unbreaking
	end
	return NewItem(E_ITEM_SHIELD, 1, Damage, nil, NewEnch(Levels))
end

local function ShieldWithLore(a_Lore)
	return NewItem(E_ITEM_SHIELD, 1, 0, a_Lore, NewEnch({}))
end

local function DurabilityOf(a_Item)
	if (a_Item == nil) then return nil end
	return 336 - (a_Item.m_ItemDamage or 0)
end

local function RaisedWithShield(a_Shield, a_PlayerOptions)
	a_PlayerOptions = a_PlayerOptions or {}
	a_PlayerOptions.main = cItem(E_ITEM_STICK)
	a_PlayerOptions.off = a_Shield
	local P = NewPlayer(a_PlayerOptions)
	FireUsingItem(P, { air = true })
	return P
end

-- Knockback points from attacker to receiver: (0,0,-1) means the attacker is behind
-- (positive Z is the player's look direction in the mock), so -Knockback = front.
local function Damage(a_Player, a_DamageType, a_FinalDamage, a_Knockback)
	return pcall(CheckUseShieldOnTakeDamage, a_Player, {
		DamageType = a_DamageType,
		RawDamage = a_FinalDamage,
		FinalDamage = a_FinalDamage,
		Attacker = nil,
		Knockback = a_Knockback or Vector3d(0, 0, -1),
	})
end

print("== M. damage blocking ==")
do
	local P = RaisedWithShield(ShieldWith(100))
	local Ok, Blocked = pcall(CheckUseShieldOnTakeDamage, P, {
		DamageType = dtAttack, RawDamage = 5, FinalDamage = 5, Attacker = nil,
		Knockback = Vector3d(0, 0, -1),
	})
	Check("front melee: no Lua error", Ok)
	Check("front melee is cancelled", Blocked == true)
	Check("front melee wears the shield", DurabilityOf(P.State.off) == 94,
		"durability=" .. tostring(DurabilityOf(P.State.off)))
	Check("front melee plays the block sound", Sounds[#Sounds] == "item.shield.block")
end
do
	-- A knockback pointing the other way: the attacker is behind the player.
	local P = RaisedWithShield(ShieldWith(100))
	local _, Blocked = Damage(P, dtRangedAttack, 5, Vector3d(0, 0, 1))
	Check("attack from behind is not cancelled", Blocked == false)
	Check("attack from behind does not wear the shield", DurabilityOf(P.State.off) == 100)
end
do
	local P = RaisedWithShield(ShieldWith(100))
	local _, Blocked = Damage(P, dtAttack, 2)
	Check("a weak hit is still cancelled", Blocked == true)
	Check("a hit below 3 damage does not wear the shield", DurabilityOf(P.State.off) == 100)
end
do
	local P = RaisedWithShield(ShieldWith(100))
	local _, Blocked = Damage(P, dtFall, 20)
	Check("fall damage is not blocked", Blocked == false)
end
do
	-- Unbreaking is a chance per point: 0.999 keeps every point, 0.0 drops every point.
	-- luacheck: push ignore
	local RealRandom = math.random
	math.random = function() return 0.999 end
	local P = RaisedWithShield(ShieldWith(100, 3))
	Damage(P, dtAttack, 9)  -- 10 points
	local Worn = 100 - (DurabilityOf(P.State.off) or 100)
	Check("unbreaking still lets points through", Worn > 0, "worn=" .. Worn)

	math.random = function() return 0.0 end
	local Q = RaisedWithShield(ShieldWith(100, 3))
	Damage(Q, dtAttack, 9)
	Check("unbreaking can negate every point", DurabilityOf(Q.State.off) == 100,
		"durability=" .. tostring(DurabilityOf(Q.State.off)))
	math.random = RealRandom
	-- luacheck: pop
end
do
	local P = RaisedWithShield(ShieldWith(100), { creative = true })
	Damage(P, dtAttack, 9)
	Check("creative does not wear the shield", DurabilityOf(P.State.off) == 100)
end
do
	local P = RaisedWithShield(ShieldWith(2))
	Damage(P, dtAttack, 9)  -- 10 points > 2 remaining
	Check("a shield that runs out is removed", P.State.off:IsEmpty())
	Check("a broken shield lowers the state", not IsRaised(P))
end
do
	-- A shield saved by the older, lore-based scheme is migrated on its first hit:
	-- the counter moves into the damage field and that lore line disappears, while
	-- any player-written lore line survives untouched.
	local P = RaisedWithShield(ShieldWithLore({ "My favourite shield", LorePrefix .. "50/336" }))
	Damage(P, dtAttack, 5)  -- 6 points
	Check("legacy counter migrated into the damage field", DurabilityOf(P.State.off) == 44,
		"durability=" .. tostring(DurabilityOf(P.State.off)))
	Check("damage field holds 336 - remaining", P.State.off.m_ItemDamage == 336 - 44,
		"damage=" .. tostring(P.State.off.m_ItemDamage))
	local Lore = P.State.off.m_LoreTable or {}
	Check("legacy counter line is dropped", #Lore == 1, "lines=" .. #Lore)
	Check("custom lore line survives", Lore[1] == "My favourite shield", tostring(Lore[1]))
end
do
	-- A pristine shield (no lore yet) starts at the full 336.
	local P = RaisedWithShield(ShieldWith(nil))
	Damage(P, dtAttack, 5)
	Check("a pristine shield starts at 336", DurabilityOf(P.State.off) == 330,
		"durability=" .. tostring(DurabilityOf(P.State.off)))
end
do
	-- Damage without a raised shield is untouched.
	local P = NewPlayer({ main = cItem(E_ITEM_STICK), off = ShieldWith(100) })
	local _, Blocked = Damage(P, dtAttack, 9)
	Check("damage with the shield down is not blocked", Blocked == false)
end
do
	-- Non-players are ignored.
	local Ok, Blocked = pcall(CheckUseShieldOnTakeDamage, { IsPlayer = function() return false end }, {
		DamageType = dtAttack, RawDamage = 5, FinalDamage = 5, Attacker = nil, Knockback = nil,
	})
	Check("non-player damage: no Lua error", Ok)
	Check("non-player damage is not blocked", Blocked == false)
end

print("== N. projectile deflection ==")
do
	local function Projectile(a_Kind)
		return {
			m_Kind = a_Kind,
			GetPosX = function() return 0 end,
			GetPosY = function() return 0 end,
			GetPosZ = function() return 1 end,   -- +Z: in front of the player's look vector
			GetProjectileKind = function(self) return self.m_Kind end,
			GetSpeed = function() return Vector3d(1, 0, 0) end,
			SetSpeed = function(self, a_Speed) self.m_Speed = a_Speed end,
			Destroy = function(self) self.m_Destroyed = true end,
		}
	end

	local P = RaisedWithShield(ShieldWith(100))
	local Snowball = Projectile(cProjectileEntity.pkSnowball)
	local Ok, Pass = pcall(CheckUseShieldOnProjectileHitEntity, Snowball, P)
	Check("deflect snowball: no Lua error", Ok)
	Check("deflect snowball: flies through", Pass == true)
	Check("deflect snowball: is destroyed", Snowball.m_Destroyed == true)

	local Arrow = Projectile(cProjectileEntity.pkArrow)
	local _, PassArrow = pcall(CheckUseShieldOnProjectileHitEntity, Arrow, P)
	Check("deflect arrow: flies through", PassArrow == true)
	Check("deflect arrow: is not destroyed", Arrow.m_Destroyed == nil)
	Check("deflect arrow: speed is reversed", (Arrow.m_Speed ~= nil) and (Arrow.m_Speed.x == -1),
		tostring(Arrow.m_Speed and Arrow.m_Speed.x))

	-- From behind the projectile still hits.
	local Behind = Projectile(cProjectileEntity.pkSnowball)
	Behind.GetPosZ = function() return -1 end
	local _, PassBehind = pcall(CheckUseShieldOnProjectileHitEntity, Behind, P)
	Check("a projectile from behind is not deflected", PassBehind == false)
end

-- ===========================================================================
-- 8. Exhaustive robustness: every itemtype through every handler
-- ===========================================================================

print("== O. exhaustive fuzz over every itemtype ==")

local ItemNames = {}
for Name in ITEM_NAMES:gmatch("%S+") do
	ItemNames[#ItemNames + 1] = Name
end

local Crashes = 0
for _, Name in ipairs(ItemNames) do
	local Type = Const(Name)
	local P = NewPlayer({ main = NewItem(Type, 1, 0), off = cItem(E_ITEM_SHIELD) })

	local Ok1, Err1 = FireUsingItem(P, { air = true })
	local Ok2, Err2 = FireUsingItem(P, { target = E_BLOCK_STONE })
	local Ok3, Err3 = FireRightClick(P, { air = true })
	local Ok4, Err4 = pcall(CheckUseShieldOnShooting, P)
	local Ok5, Err5 = pcall(CheckUseShieldOnTossingItem, P)
	World.Players = { P }
	local Ok6, Err6 = pcall(CheckUseShieldOnTick, World, 50, 50)

	if not (Ok1 and Ok2 and Ok3 and Ok4 and Ok5 and Ok6) then
		Crashes = Crashes + 1
		if Crashes <= 10 then
			print(string.format("  %s crashed: %s%s%s%s%s%s", Name,
				Err1 and ("using-air=" .. tostring(Err1) .. " ") or "",
				Err2 and ("using-block=" .. tostring(Err2) .. " ") or "",
				Err3 and ("rclick=" .. tostring(Err3) .. " ") or "",
				Err4 and ("shoot=" .. tostring(Err4) .. " ") or "",
				Err5 and ("toss=" .. tostring(Err5) .. " ") or "",
				Err6 and ("tick=" .. tostring(Err6) .. " ") or ""))
		end
	end
end
Check("every itemtype passes every handler without a Lua error", Crashes == 0,
	Crashes .. " itemtypes crashed")

print("== P. hostile / degenerate inputs ==")
do
	-- The engine can hand nil items in a hand; the handler must not dereference them.
	local P = NewPlayer({ main = nil, off = cItem(E_ITEM_SHIELD) })
	local Ok, Err = FireUsingItem(P, { air = true })
	Check("nil main-hand item does not crash", Ok, tostring(Err))
	if Ok then
		Check("nil main-hand item raises the offhand shield", IsRaised(P))
	end
end
do
	local P = NewPlayer({ main = cItem(E_ITEM_STICK), off = nil })
	local Ok, Err = FireUsingItem(P, { air = true })
	Check("nil offhand item does not crash", Ok, tostring(Err))
end
do
	local P = NewPlayer({ main = cItem(E_ITEM_STICK), off = cItem(E_ITEM_SHIELD) })
	local Ok, Err = FireUsingItem(P, { air = true, target = nil })
	Check("air use with nothing in reach does not crash", Ok, tostring(Err))
end
do
	-- An empty (m_ItemType == -1) main hand behaves like a missing one.
	local P = NewPlayer({ main = EmptyItem(), off = cItem(E_ITEM_SHIELD) })
	local Ok, Err = FireUsingItem(P, { air = true })
	Check("empty main-hand cItem does not crash", Ok, tostring(Err))
	if Ok then
		Check("empty main-hand cItem raises the offhand shield", IsRaised(P))
	end
end
do
	-- Unknown / future itemtypes fall through the tables and must not crash.
	local P = NewPlayer({ main = NewItem(32000, 1, 0), off = cItem(E_ITEM_SHIELD) })
	local Ok, Err = FireUsingItem(P, { target = E_BLOCK_STONE })
	Check("unknown itemtype does not crash", Ok, tostring(Err))
	if Ok then
		Check("unknown itemtype is treated as not consumed", IsRaised(P))
	end
end
do
	-- A player whose UUID is not available falls back to the name.
	local P = NewPlayer({ main = cItem(E_ITEM_STICK), off = cItem(E_ITEM_SHIELD) })
	P.GetUUID = function() return nil end
	local Ok = FireUsingItem(P, { air = true })
	Check("missing UUID does not crash", Ok)
end

-- ===========================================================================
-- Q. consumption probe (debug cross-check against the engine)
-- ===========================================================================
--
-- The probe is inert unless DebugLogging is on, so this section turns it on,
-- captures LOG() and drives the two hooks by hand. It asserts only on what the
-- probe chooses to report, never on shield behaviour.

-- Fire one HOOK_PLAYER_USED_ITEM event. a_Mutate simulates what the engine's
-- handler would have done to the main-hand slot between the two hooks.
local function FireUsedItem(a_Player, a_Mutate)
	if a_Mutate then a_Mutate(a_Player) end
	return pcall(ProbeItemConsumptionOnItemUsed, a_Player, 0, 0, 1, 1, 0, 0, 0)
end

print("== Q. consumption probe ==")
do
	local Captured = {}
	local SavedLog = LOG
	LOG = function(a_Message) Captured[#Captured + 1] = tostring(a_Message) end
	DebugLogging = true

	-- Only the probe's own lines; the USING_ITEM handler logs a trace of its own.
	local function ProbeLines()
		local Out = {}
		for _, Line in ipairs(Captured) do
			if Line:find("consumption-probe:", 1, true) then Out[#Out + 1] = Line end
		end
		return Out
	end

	-- Flint and steel aimed at stone: EvaluateEvent says the click is consumed.
	local Scene = { air = false, target = E_BLOCK_STONE }

	local function Lighter(a_Options)
		a_Options = a_Options or {}
		a_Options.main = a_Options.main or cItem(E_ITEM_FLINT_AND_STEEL)
		a_Options.off = cItem(E_ITEM_SHIELD)
		return NewPlayer(a_Options)
	end

	-- What the engine's cItemLighterHandler does on success.
	local function WearMain(a_Player)
		local Item = a_Player:GetEquippedItem()
		Item.m_ItemDamage = Item.m_ItemDamage + 1
	end

	-- 1. Agreement, consumed: the handler damaged the item, so the slot moved.
	do
		Captured = {}
		local P = Lighter()
		Check("probe: USING_ITEM takes a snapshot", FireUsingItem(P, Scene))
		Check("probe: USED_ITEM runs without error", FireUsedItem(P, WearMain))
		Check("probe: agreement is silent", #ProbeLines() == 0, table.concat(ProbeLines(), " | "))
	end

	-- 2. Agreement, not consumed: inert item, slot untouched.
	do
		Captured = {}
		local P = Lighter({ main = cItem(E_ITEM_STICK) })
		FireUsingItem(P, Scene)
		FireUsedItem(P, nil)
		Check("probe: agreement on 'not consumed' is silent", #ProbeLines() == 0,
			table.concat(ProbeLines(), " | "))
	end

	-- 3. Unbreaking negated the durability loss: consumed, but the slot is identical.
	do
		Captured = {}
		local Ench = NewEnch({ [cEnchantments.enchUnbreaking] = 3 })
		local P = Lighter({ main = cItem(E_ITEM_FLINT_AND_STEEL, 1, 0, Ench) })
		FireUsingItem(P, Scene)
		FireUsedItem(P, nil)
		local Lines = ProbeLines()
		Check("probe: Unbreaking disagreement is reported", #Lines == 1, table.concat(Lines, " | "))
		Check("probe: Unbreaking disagreement is tagged explained",
			(Lines[1] ~= nil) and (Lines[1]:find("explained", 1, true) ~= nil), Lines[1])
	end

	-- 4. Creative skipped the consumption entirely: consumed, slot identical.
	do
		Captured = {}
		local P = Lighter({ creative = true })
		FireUsingItem(P, Scene)
		FireUsedItem(P, nil)
		local Lines = ProbeLines()
		Check("probe: creative disagreement is reported", #Lines == 1, table.concat(Lines, " | "))
		Check("probe: creative disagreement is tagged explained",
			(Lines[1] ~= nil) and (Lines[1]:find("explained", 1, true) ~= nil), Lines[1])
	end

	-- 5. Survival, no Unbreaking, consumed but the slot never moved. Synthetic:
	--    we deliberately do not simulate the damage, so the probe sees a
	--    disagreement it cannot explain. That is the case worth reporting.
	do
		Captured = {}
		local P = Lighter()
		FireUsingItem(P, Scene)
		FireUsedItem(P, nil)
		local Lines = ProbeLines()
		Check("probe: unexplained disagreement is reported", #Lines == 1, table.concat(Lines, " | "))
		Check("probe: unexplained disagreement is flagged SUSPICIOUS",
			(Lines[1] ~= nil) and (Lines[1]:find("SUSPICIOUS", 1, true) ~= nil), Lines[1])
	end

	-- 6. The reverse disagreement: "not consumed" predicted, slot moved anyway.
	do
		Captured = {}
		local P = Lighter({ main = cItem(E_ITEM_STICK) })
		FireUsingItem(P, Scene)
		FireUsedItem(P, function(a_Player)
			local Item = a_Player:GetEquippedItem()
			Item.m_ItemCount = Item.m_ItemCount + 1
		end)
		local Lines = ProbeLines()
		Check("probe: unexpected slot change is reported", #Lines == 1, table.concat(Lines, " | "))
		Check("probe: unexpected slot change says so",
			(Lines[1] ~= nil) and (Lines[1]:find("unexpected slot change", 1, true) ~= nil), Lines[1])
	end

	-- 7. USED_ITEM without a preceding USING_ITEM: nothing recorded, nothing logged.
	do
		Captured = {}
		local P = Lighter()
		FireUsedItem(P, nil)
		Check("probe: no snapshot is silent", #ProbeLines() == 0, table.concat(ProbeLines(), " | "))
	end

	-- 8. A snapshot whose USED_ITEM never arrives (another plugin cancelled the
	--    use) must be dropped by the tick, not compared against a stale slot.
	do
		Captured = {}
		local P = Lighter()
		FireUsingItem(P, Scene)
		Check("probe: snapshot is pending after USING_ITEM",
			GetPlayerState(P).ConsumptionProbe ~= nil)
		World.Players[#World.Players + 1] = P
		pcall(CheckUseShieldOnTick, World, 50, 50)
		World.Players[#World.Players] = nil
		Check("probe: tick drops a stale snapshot",
			GetPlayerState(P).ConsumptionProbe == nil)
	end

	-- 9. Disabled: the probe must neither record nor log.
	do
		Captured = {}
		DebugLogging = false
		local P = Lighter()
		FireUsingItem(P, Scene)
		Check("probe: disabled records nothing", GetPlayerState(P).ConsumptionProbe == nil)
		FireUsedItem(P, nil)
		Check("probe: disabled is silent", #ProbeLines() == 0, table.concat(ProbeLines(), " | "))
		DebugLogging = true
	end

	LOG = SavedLog
	DebugLogging = false
end

-- ===========================================================================
-- 9. Summary
-- ===========================================================================

World.Players = {}

print("")
print(string.format("shield_test: %d passed, %d failed", Passed, Failed))
if (Failed > 0) then
	print("")
	print("Failures:")
	for _, F in ipairs(Failures) do
		print("  - " .. F)
	end
end
os.exit(Failed == 0 and 0 or 1)
