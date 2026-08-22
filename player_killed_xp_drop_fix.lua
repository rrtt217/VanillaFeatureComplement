-- Fix two vanilla behaviors that Cuberite is missing on player death:
--   1. Players drop experience orbs on death (min(7 * level, 100) points).
--   2. The off-hand (shield) slot item is dropped as a pickup.
--
-- Hook choice: HOOK_KILLING, not HOOK_KILLED.
-- For a player victim, HOOK_KILLED is fired from cEntity::BroadcastDeathMessage(),
-- which cPlayer::KilledBy() calls *after* m_Inventory.Clear() has already wiped
-- every slot (including the off-hand shield slot). By the time HOOK_KILLED runs,
-- the off-hand item is gone and the XP level is about to be reset on respawn.
-- HOOK_KILLING fires at the very start of cEntity::KilledBy(), before any
-- inventory / XP mutation, so both the off-hand item and the current XP level
-- are still readable here. A plugin can also "resurrect" the victim by healing
-- it in HOOK_KILLING; in that case cPlayer::KilledBy() returns early and we
-- must NOT have dropped anything yet -- which is naturally satisfied because
-- we drop here only when the victim is actually dying (health already 0).
--
-- Reference:
--   https://minecraft.wiki/w/Experience  (death drops min(7 * level, 100))
--   https://api.cuberite.org/OnKilling.html

---Maximum total experience a player can drop on death, per vanilla rules.
local MAX_XP_DROP = 100

---Multiplier applied to the player's XP level to compute the drop amount.
local XP_PER_LEVEL = 7

---Drop experience orbs and the off-hand item when a player is about to die.
---@param Victim cEntity The player or mob that is about to be killed
---@param Killer cEntity|nil The entity that dealt the final blow; may be nil
---@param TDI TakeDamageInfo The damage info describing the killing blow
function OnKillingDropXpAndOffhand(Victim, Killer, TDI)
    -- Only handle player deaths; mobs already drop their own XP via GetDrops().
    if not Victim:IsPlayer() then
        return false
    end

    -- If a plugin resurrected the victim (health > 0) in an earlier KILLING
    -- callback, cEntity::KilledBy() would have bailed out before reaching us,
    -- so we don't need an extra health check here. But guard anyway: a victim
    -- with positive health is not actually dying.
    if Victim:GetHealth() > 0 then
        return false
    end

    local Player = Victim  -- cEntity descendant that is a cPlayer
    local World = Player:GetWorld()
    local Pos = Player:GetPosition()

    -- 1) Experience orbs: min(7 * level, 100), split into vanilla-sized orbs.
    --    Use the player's current level (GetXpLevel), not the raw XP total,
    --    matching vanilla "7 * level" behavior.
    local Level = Player:GetXpLevel()
    local XpReward = Level * XP_PER_LEVEL
    if XpReward > MAX_XP_DROP then
        XpReward = MAX_XP_DROP
    end
    if XpReward > 0 then
        -- SpawnSplitExperienceOrbs splits the total into the standard
        -- 1/3/7/17/37/73/149/307/617/1237/2477 orb values and scatters them.
        -- NOTE: the spawn must be deferred by one tick. Entities created directly
        -- inside HOOK_KILLING (i.e. while cEntity::KilledBy() is still running)
        -- are wiped before the next world tick in this Cuberite build, so the
        -- orbs would never appear. QueueTask runs the lambda on the world tick
        -- right after the death flow has finished.
        World:QueueTask(
            ---@param DeathWorld cWorld
            function (DeathWorld)
                DeathWorld:SpawnSplitExperienceOrbs(Pos, XpReward)
            end
        )
    end

    -- 2) Off-hand (shield) slot: Cuberite's cInventory::CopyToItems() skips the
    --    shield grid, so cPlayer::KilledBy() never drops it. Drop it manually
    --    and clear the slot so the respawned player doesn't keep a duplicate.
    local OffhandItem = Player:GetOffHandEquipedItem()
    if not OffhandItem:IsEmpty() then
        local Drops = cItems()
        Drops:Add(OffhandItem)
        -- a_IsPlayerCreated = true so the pickup behaves like a player toss.
        World:SpawnItemPickups(Drops, Pos.x, Pos.y, Pos.z, 10, true)
        Player:GetInventory():SetShieldSlot(cItem())
    end

    return false  -- let other plugins and the normal death flow proceed
end
