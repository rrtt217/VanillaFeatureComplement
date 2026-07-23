PLUGIN = nil

function Initialize(Plugin)
	Plugin:SetName("VanillaFeatureComplement")
	Plugin:SetVersion(2)

    -- Load Config
    local path = Plugin:GetLocalFolder() .. "/settings.ini"
    Config = cIniFile()
    _G.Config = Config
	-- Hooks
    if Config:GetValueSetB("Features","EnableMapZoomout",true) then
        LOG("HOOK_CRAFTING_NO_RECIPE has been added to EnableMapZoomout!")
        cPluginManager:AddHook(cPluginManager.HOOK_CRAFTING_NO_RECIPE,MapZoomoutOnCraftingNoRecipe)
        cPluginManager:AddHook(cPluginManager.HOOK_TICK,CheckForZoomOutMapOnTick)
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
        LOG("HOOK_PLAYER_USING_ITEM and HOOK_TICK has been added to EnableElytraPoweredFlight")
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_USING_ITEM,StartPoweredFilghtOnPlayerUsingItem)
        cPluginManager:AddHook(cPluginManager.HOOK_TICK,SpeedUpPlayerOnTick)
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
        cPluginManager:AddHook(cPluginManager.HOOK_TICK,CheckUseShieldOnTick)
        cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_RIGHT_CLICK,CheckUseShieldOnRightClick)
        -- HOOK_TAKE_DAMAGE intentionally NOT registered: it causes a deadlock in
        -- Cuberite (empty callback still deadlocks). Shield damage blocking is
        -- therefore not implemented.
        cPluginManager:AddHook(cPluginManager.HOOK_PROJECTILE_HIT_ENTITY,CheckUseShieldOnProjectileHitEntity)
    end
	PLUGIN = Plugin -- NOTE: only needed if you want OnDisable() to use GetName() or something like that

	-- Command Bindings

	LOG("Initialised version " .. Plugin:GetVersion())
	return true
end

function OnDisable()
    local path = PLUGIN:GetLocalFolder() .. "/settings.ini"
    Config:WriteFile(path)
	LOG("Shutting down...")
end