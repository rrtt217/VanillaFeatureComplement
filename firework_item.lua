-- firework_item.lua
--
-- Lua access to the cItem firework payload (C++ cItem::m_FireworkItem, a
-- cFireworkItem) -- the firework rocket / firework star data that upstream
-- Cuberite does not document and does not expose as a class.
--
-- WHY THIS FILE EXISTS
--   cItem::m_FireworkItem IS registered as a tolua variable, so reading it
--   yields a real userdata:
--       local Payload = Item.m_FireworkItem   --> userdata, tolua.type == "cFireworkItem"
--   but cFireworkItem has NO bound methods and NO global class table, so the
--   only way in is to reinterpret the userdata as another, bound class with
--   tolua.cast().  Its first bytes happen to line up with cItem's, and
--   cItem::m_Enchantments happens to sit exactly on cFireworkItem::m_Colours.
--
-- LAYOUT (from src/WorldStorage/FireworksSerializer.h and src/Item.h):
--
--   class cFireworkItem {
--       bool             m_HasFlicker;         // +0x00
--       bool             m_HasTrail;           // +0x01
--       NIBBLETYPE       m_Type;               // +0x02  explosion shape (uchar)
--       short            m_FlightTimeInTicks;  // +0x04
--       std::vector<int> m_Colours;            // +0x08
--       std::vector<int> m_FadeColours;        // +0x08 + sizeof(std::vector<int>)
--   };
--
--   class cItem { short m_ItemType; char m_ItemCount; short m_ItemDamage;
--                 cEnchantments m_Enchantments; ... cFireworkItem m_FireworkItem; ... };
--
--   So with View = tolua.cast(Item.m_FireworkItem, "cItem"):
--     View.m_ItemType   -> payload bytes 0..1 -> {m_HasFlicker, m_HasTrail}
--     View.m_ItemCount  -> payload byte  2    -> m_Type
--     View.m_ItemDamage -> payload bytes 4..5 -> m_FlightTimeInTicks
--     View.m_Enchantments addresses payload+0x08 == m_Colours
--
-- Verified by disassembly on two ABIs (field getters read cItem+0/2/4 and
-- cFireworkItem+0/2/4 respectively):
--   x86-64 LP64 : offsetof(cItem, m_FireworkItem) = 0x78, vector<int> = 24 B,
--                 m_FadeColours = payload+0x20
--   ARM32  ILP32: offsetof(cItem, m_FireworkItem) = 0x48, vector<int> = 12 B,
--                 m_FadeColours = payload+0x14
-- The scalar mapping and m_Colours work identically on both; only the
-- m_FadeColours walk depends on the pointer width (see below).
--
-- READ / WRITE / COPY
--   * m_Type and m_FlightTimeInTicks are readable AND writable.
--   * The colour VALUES are NOT reachable from Lua (no bound std::vector<int>
--     accessor, and Lua cannot dereference a pointer).  Their LENGTH is, and
--     the whole payload -- colours included -- can be copied between two items
--     with a plain assignment, which is enough to make cProjectileEntity::Create
--     accept a rocket it would otherwise reject as "no colours".
--
-- SAFETY
--   tolua.cast(userdata, T) with T absent from the tolua type registry makes
--   tolua_pushusertype() dereference a nil metatable and SIGSEGVs the server
--   (observed on x86-64: crash in tolua_pushusertype+0x3e -> lua_rawget; the
--   ARM32 build has the identical codegen).  Every cast here is guarded by a
--   registry lookup, and the module degrades to "unavailable" otherwise.

FireworkItem = {}

local AvailabilityChecked = false
local Available = false

---Return the tolua type registry, or nil when the debug library is absent.
---@return table|nil
local function GetTypeRegistry()
    if (debug == nil) or (debug.getregistry == nil) then
        return nil
    end
    local Ok, Registry = pcall(debug.getregistry)
    if not Ok then
        return nil
    end
    return Registry
end

---True when TypeName is a registered tolua type (i.e. tolua.cast to it is safe).
---@param TypeName string
---@return boolean
local function RegistryHasType(TypeName)
    local Registry = GetTypeRegistry()
    return (Registry ~= nil) and (Registry[TypeName] ~= nil)
end

---tolua.cast() that refuses unknown types instead of crashing the server.
---@param Userdata any
---@param TypeName string
---@return any
local function SafeCast(Userdata, TypeName)
    if (Userdata == nil) or not RegistryHasType(TypeName) then
        return nil
    end
    local Ok, Result = pcall(tolua.cast, Userdata, TypeName)
    if not Ok then
        return nil
    end
    return Result
end

---Reinterpret a possibly-negative 32-bit int as unsigned.
---@param Value number
---@return number
local function ToU32(Value)
    if Value < 0 then
        return Value + 4294967296
    end
    return Value
end

---Reinterpret a possibly-negative byte as unsigned.
---@param Value number
---@return number
local function ToByte(Value)
    return Value % 256
end

---Reassemble a 64-bit pointer stored as two 32-bit halves (little-endian).
---@param Low number
---@param High number
---@return number
local function Combine32(Low, High)
    return ToU32(High) * 4294967296 + ToU32(Low)
end

---Read a std::vector<int> header addressed by VectorAddress.
---A cCuboid view exposes the {begin, end, capacity} triple as six 32-bit words
---(Vector3i p1 = begin.lo/begin.hi/end.lo, p2 = end.hi/cap.lo/cap.hi).
---@param VectorAddress any userdata addressing the vector itself
---@return number|nil Count, boolean NonEmpty  (nil when implausible)
local function ReadVector(VectorAddress)
    local Cuboid = SafeCast(VectorAddress, "cCuboid")
    if Cuboid == nil then
        return nil
    end
    local Begin = Combine32(Cuboid.p1.x, Cuboid.p1.y)
    local End = Combine32(Cuboid.p1.z, Cuboid.p2.x)
    local Capacity = Combine32(Cuboid.p2.y, Cuboid.p2.z)
    if (Begin == 0) and (End == 0) and (Capacity == 0) then
        return 0, false -- default-constructed / cleared vector
    end
    if (Begin < 4096) or (End < Begin) or (Capacity < End) then
        return nil
    end
    local Bytes = End - Begin
    if ((Bytes % 4) ~= 0) or (Bytes > 4096) or ((Capacity - Begin) > 4096) then
        return nil
    end
    return Bytes / 4, true
end

---Address of m_FadeColours, reached by walking cCuboid.p2 hops (12 bytes each)
---from m_Colours.  sizeof(std::vector<int>) is 24 bytes on LP64 (two hops) and
---12 bytes on ILP32 (one hop), so both candidates are tried and the one that
---reads as a plausible vector wins.
---@param ColoursAddress any
---@return number|nil Count
local function ReadFadeColours(ColoursAddress)
    local Node = ColoursAddress
    local FirstCount = nil
    for _ = 1, 2 do
        local Cuboid = SafeCast(Node, "cCuboid")
        if Cuboid == nil then
            break
        end
        Node = Cuboid.p2
        local Count, NonEmpty = ReadVector(Node)
        if Count ~= nil then
            if NonEmpty then
                return Count -- a populated vector: this is the real one
            end
            if FirstCount == nil then
                FirstCount = Count
            end
        end
    end
    return FirstCount
end

---Probe whether the accessors work on this build, using cItem:IsEqual as an
---independent oracle: it compares the whole payload, so writing the flight time
---through the cItem view must make a previously equal copy compare unequal.
---@return boolean
local function Probe()
    if (tolua == nil) or (tolua.cast == nil) then
        return false
    end
    if not (RegistryHasType("cFireworkItem") and RegistryHasType("cItem") and RegistryHasType("cCuboid")) then
        return false
    end
    local Ok, Result = pcall(function()
        local ProbeItem = cItem(E_ITEM_FIREWORK_ROCKET, 1, 0)
        local View = tolua.cast(ProbeItem.m_FireworkItem, "cItem")
        View.m_ItemDamage = 1234
        local Copy = cItem(ProbeItem)
        if not ProbeItem:IsEqual(Copy) then
            return false -- our view and the C++ copy disagree
        end
        View.m_ItemDamage = 4321
        return not ProbeItem:IsEqual(Copy) -- the write reached the real payload
    end)
    return Ok and (Result == true)
end

---True when cFireworkItem access works on this server build.
---@return boolean
function FireworkItem.IsAvailable()
    if not AvailabilityChecked then
        AvailabilityChecked = true
        local Ok, Result = pcall(Probe)
        Available = Ok and (Result == true)
        if not Available then
            LOG("FireworkItem: firework payload introspection unavailable on this build; firework data stays opaque")
        end
    end
    return Available
end

---Return the cItem view over the item's firework payload, or nil.
---@param Item cItem
---@return any|nil
local function FireworkView(Item)
    if (Item == nil) or not FireworkItem.IsAvailable() then
        return nil
    end
    local ItemType = Item.m_ItemType
    if (ItemType ~= E_ITEM_FIREWORK_ROCKET) and (ItemType ~= E_ITEM_FIREWORK_STAR) then
        return nil
    end
    local Ok, View = pcall(function()
        return tolua.cast(Item.m_FireworkItem, "cItem")
    end)
    if not Ok then
        return nil
    end
    return View
end

---Describe the firework payload of an item.
---@param Item cItem
---@return table|nil  { Type, HasFlicker, HasTrail, FlightTimeInTicks,
---                     ColourCount, FadeColourCount, HasColours }
function FireworkItem.GetInfo(Item)
    local View = FireworkView(Item)
    if View == nil then
        return nil
    end
    local Flags = View.m_ItemType % 65536 -- payload bytes 0..1
    local Info = {
        Type = ToByte(View.m_ItemCount), -- payload byte 2
        HasFlicker = (Flags % 256) ~= 0,
        HasTrail = (math.floor(Flags / 256) % 256) ~= 0,
        FlightTimeInTicks = View.m_ItemDamage, -- payload bytes 4..5
        ColourCount = 0,
        FadeColourCount = 0,
        HasColours = false,
    }
    -- cItem+0x08 == cFireworkItem+0x08 == m_Colours on both tested ABIs.
    local ColoursAddress = View.m_Enchantments
    local Count, NonEmpty = ReadVector(ColoursAddress)
    Info.ColourCount = Count or 0
    Info.HasColours = (NonEmpty == true)
    Info.FadeColourCount = ReadFadeColours(ColoursAddress) or 0
    return Info
end

---True when the item is a rocket/star whose payload carries primary colours.
---Rockets without colours are rejected by cProjectileEntity::Create.
---@param Item cItem
---@return boolean
function FireworkItem.HasColours(Item)
    local Info = FireworkItem.GetInfo(Item)
    return (Info ~= nil) and Info.HasColours
end

---Return the payload's flight time in ticks, or nil.
---@param Item cItem
---@return number|nil
function FireworkItem.GetFlightTimeInTicks(Item)
    local Info = FireworkItem.GetInfo(Item)
    if Info == nil then
        return nil
    end
    return Info.FlightTimeInTicks
end

---Overwrite the payload's flight time in ticks.
---@param Item cItem
---@param Ticks number
---@return boolean
function FireworkItem.SetFlightTimeInTicks(Item, Ticks)
    local View = FireworkView(Item)
    if View == nil then
        return false
    end
    return (pcall(function()
        View.m_ItemDamage = Ticks
    end))
end

---Copy the WHOLE firework payload (flicker, trail, type, flight time, colours
---and fade colours) from SourceItem into TargetItem.  This is ABI-independent:
---it is the compiler-generated cFireworkItem assignment, not offset arithmetic.
---It is also the only way to give an item colours from Lua.
---@param TargetItem cItem
---@param SourceItem cItem
---@return boolean
function FireworkItem.Copy(TargetItem, SourceItem)
    if (TargetItem == nil) or (SourceItem == nil) then
        return false
    end
    if not FireworkItem.IsAvailable() then
        return false
    end
    return (pcall(function()
        TargetItem.m_FireworkItem = SourceItem.m_FireworkItem
    end))
end

---Return a copy of TargetPrototype carrying SourceItem's firework payload, or nil.
---@param TargetPrototype cItem
---@param SourceItem cItem
---@return cItem|nil
function FireworkItem.CloneWith(TargetPrototype, SourceItem)
    if (TargetPrototype == nil) or (SourceItem == nil) then
        return nil
    end
    local Clone = cItem(TargetPrototype)
    if not FireworkItem.Copy(Clone, SourceItem) then
        return nil
    end
    return Clone
end

---Return the first inventory item that carries firework colours, or nil.
---@param Inventory cInventory
---@return cItem|nil
function FireworkItem.FindColouredDonor(Inventory)
    if (Inventory == nil) or not FireworkItem.IsAvailable() then
        return nil
    end
    local SlotCount = 41 -- cInventory.invNumSlots; fall back to the literal
    if (type(cInventory) == "table") and (cInventory.invNumSlots ~= nil) then
        SlotCount = cInventory.invNumSlots
    end
    for Slot = 0, SlotCount - 1 do
        local Ok, Item = pcall(function()
            return Inventory:GetSlot(Slot)
        end)
        if Ok and (Item ~= nil) then
            local Info = FireworkItem.GetInfo(Item)
            if (Info ~= nil) and Info.HasColours then
                return Item
            end
        end
    end
    return nil
end
