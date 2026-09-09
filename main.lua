PLUGIN = nil

-- Per-player plugin state storage.
--
-- We deliberately do NOT store per-player state as dynamic fields on the
-- cPlayer userdata (e.g. Player.IsUsingShield): the Lua wrapper object can be
-- garbage-collected during idle periods and recreated on the next event, which
-- silently drops those fields (observed: a raised shield stopped blocking after
-- ~90 s of inactivity). Instead we keep a plugin-owned table keyed by a stable
-- player key (UUID, falling back to the name), with explicit lifecycle
-- handling: state is reset on death and removed on disconnect.
local PlayerStates = {}

---Return a stable storage key for the given player.
---@param Player cPlayer
---@return string
function GetPlayerKey(Player)
	local UUID = Player:GetUUID()
	if (UUID ~= nil) and (UUID ~= "") then
		return UUID
	end
	return Player:GetName()
end

---Return (and lazily create) the plugin state table for the given player.
---@param Player cPlayer
---@return table
function GetPlayerState(Player)
	local Key = GetPlayerKey(Player)
	local State = PlayerStates[Key]
	if not State then
		State = {}
		PlayerStates[Key] = State
	end
	return State
end

---Remove the plugin state for the given player (e.g. when they disconnect).
---@param Player cPlayer
function RemovePlayerState(Player)
	PlayerStates[GetPlayerKey(Player)] = nil
end

-- HOOK_PLAYER_DESTROYED: clean up per-player state when a player disconnects.
---@param Player cPlayer
function RemovePlayerStateOnDestroy(Player)
	RemovePlayerState(Player)
end

-- HOOK_KILLING: when a player is actually dying, drop their per-player combat
-- state (shield raised / pending shield durability / elytra boost). The state
-- table does not auto-clear on death like the userdata fields it replaced.
---@param Victim cPawn
---@param Killer cEntity|nil
---@param TDI TakeDamageInfo
function ResetCombatStateOnKilling(Victim, Killer, TDI)
	if Victim:IsPlayer() and Victim:GetHealth() <= 0 then
		RemovePlayerState(Victim)
	end
	return false -- let other plugins and the normal death flow proceed
end

function Initialize(Plugin)
	Plugin:SetName("VanillaFeatureComplement")
	Plugin:SetVersion(4)

    -- Load Config
    local path = Plugin:GetLocalFolder() .. "/settings.ini"
    Config = cIniFile()
    _G.Config = Config
    Config:ReadFile(path)  -- Load existing settings.ini so user feature toggles are honored
	-- Hooks
    if Config:GetValueSetB("Features","EnableMapZoomout",true) then
        LOG("HOOK_CRAFTING_NO_RECIPE has been added to EnableMapZoomout!")
        cPluginManager:AddHook(cPluginManager.HOOK_CRAFTING_NO_RECIPE,MapZoomoutOnCraftingNoRecipe)
        cPluginManager:AddHook(cPluginManager.HOOK_WORLD_TICK,CheckForZoomOutMapOnTick)
    end
    if Config:GetValueSetB("Features","EnableMapClone",true) then
        LOG("HOOK_CRAFTING_NO_RECIPE has been added to EnableMapClone!")
        cPluginManager:AddHook(cPluginManager.HOOK_CRAFTING_NO_RECIPE,MapCloningOnCraftingNoRecipe)
    end
    if Config:GetValueSetB("Features","EnableEndPlatformGeneration",true) then
        LOG("HOOK_ENTITY_CHANGING_WORLD has been added to EnableEndPlatformGeneration!")
        cPluginManager:AddHook(cPluginManager.HOOK_ENTITY_CHANGING_WORLD,GenerateEndPlatformOnEntityChangingWorld)
    end
    if Config:GetValueSetB("Features","EnableElytraPoweredFlight",true) then
        LOG("HOOK_PLAYER_USING_ITEM and HOOK_WORLD_TICK has been added to EnableElytraPoweredFlight")
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_USING_ITEM,StartPoweredFilghtOnPlayerUsingItem)
        cPluginManager:AddHook(cPluginManager.HOOK_WORLD_TICK,SpeedUpPlayerOnTick)
    end
    if Config:GetValueSetB("Features","EnableSleepClearWeather",true) then
        LOG("HOOK_PLAYER_USED_BLOCK has been added to EnableSleepClearWeather!")
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_USED_BLOCK,ClearWeatherOnPlayerSleep)
    end
    if Config:GetValueSetB("Features","EnableShield",true) then
        LOG("Shield hooks have been added to EnableShield!")
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_USING_ITEM,CheckUseShieldOnUsingItem)
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_SHOOTING,CheckUseShieldOnShooting)
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_TOSSING_ITEM,CheckUseShieldOnTossingItem)
        cPluginManager:AddHook(cPluginManager.HOOK_WORLD_TICK,CheckUseShieldOnTick)
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_RIGHT_CLICK,CheckUseShieldOnRightClick)
        cPluginManager:AddHook(cPluginManager.HOOK_TAKE_DAMAGE,CheckUseShieldOnTakeDamage)
        cPluginManager:AddHook(cPluginManager.HOOK_PROJECTILE_HIT_ENTITY,CheckUseShieldOnProjectileHitEntity)
    end
    if Config:GetValueSetB("Features","EnablePlayerKilledXpDropFix",true) then
        LOG("HOOK_KILLING has been added to EnablePlayerKilledXpDropFix!")
        cPluginManager:AddHook(cPluginManager.HOOK_KILLING,OnKillingDropXpAndOffhand)
    end
    -- Per-player state lifecycle: reset on death, clean up on disconnect.
    cPluginManager:AddHook(cPluginManager.HOOK_KILLING,ResetCombatStateOnKilling)
    cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_DESTROYED,RemovePlayerStateOnDestroy)
	PLUGIN = Plugin -- NOTE: only needed if you want OnDisable() to use GetName() or something like that

	-- Command Bindings

	LOG("Initialised version " .. Plugin:GetVersion())
	return true
end

function OnDisable()
	LOG("Shutting down...")
end
