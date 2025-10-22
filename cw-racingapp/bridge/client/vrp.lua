-- VRP Bridge for CW Racing App (Client-side)

-- Fallback functions (global)
hasGps = function()
    return true -- Always return true since we're using commands instead of items
end

notify = function(text, type)
    -- Fallback notification using chat
    TriggerEvent('chat:addMessage', {
        color = {255, 255, 255},
        multiline = true,
        args = {"[RACING]", text}
    })
end

getVehicleModel = function(vehicle)
    local model = GetEntityModel(vehicle)
    return GetDisplayNameFromVehicleModel(model)
end

getVehicleClass = function(vehicle)
    return GetVehicleClass(vehicle)
end

getClosestPlayer = function()
    local players = GetActivePlayers()
    local closestDistance = -1
    local closestPlayer = -1
    local ply = PlayerPedId()
    local plyCoords = GetEntityCoords(ply)
    
    for _, player in ipairs(players) do
        local target = GetPlayerPed(player)
        if target ~= ply then
            local targetCoords = GetEntityCoords(target)
            local distance = #(targetCoords - plyCoords)
            if closestDistance == -1 or closestDistance > distance then
                closestPlayer = player
                closestDistance = distance
            end
        end
    end
    
    return closestPlayer, closestDistance
end

-- Get citizen ID for VRP (using city ID, not citizenfx ID)
getCitizenId = function()
    -- Try to get from VRP passport system (city ID)
    if vRP and vRP.Passport then
        return vRP.Passport()
    end
    
    -- Fallback: return player server ID as string
    return tostring(GetPlayerServerId(PlayerId()))
end

-- Cache object for compatibility (similar to ox_lib cache)
cache = {
    ped = PlayerPedId(),
    vehicle = 0
}

-- Update cache in a thread
CreateThread(function()
    while true do
        cache.ped = PlayerPedId()
        cache.vehicle = GetVehiclePedIsIn(cache.ped, false)
        Wait(1000)
    end
end)

CreateThread(function()
    while not module do
        Wait(100)
    end
    
    local Tunnel = module("vrp", "lib/Tunnel")
    local Proxy = module("vrp", "lib/Proxy")
    
    vRP = Proxy.getInterface("vRP")
    vRPserver = Tunnel.getInterface("vRP")
    
    -- Initialize client functions after VRP is loaded
    InitializeClientVRPFunctions()
end)

function InitializeClientVRPFunctions()
    -- Check if player has racing tablet (global function)
    hasGps = function()
        return true -- Always return true since we're using commands instead of items
    end
    
    -- Notification function for VRP
    notify = function(text, type)
        -- Use VRP notification system
        TriggerEvent('Notify', type or 'info', text)
    end
    
    -- Client-side VRP functions can be added here if needed
    -- For now, most functionality is handled server-side
end
