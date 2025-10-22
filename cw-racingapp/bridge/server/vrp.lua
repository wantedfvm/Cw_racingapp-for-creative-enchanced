-- VRP Bridge for CW Racing App

-- Fallback functions (global) - available immediately
getCitizenId = function(src)
    -- Fallback that returns source as string until VRP loads
    return tostring(src)
end

addMoney = function(src, moneyType, amount)
    -- Fallback - do nothing until VRP loads
    return true
end

removeMoney = function(src, moneyType, amount, reason)
    -- Fallback - do nothing until VRP loads
    return true
end

canPay = function(src, moneyType, cost)
    -- Fallback - always return true until VRP loads
    return true
end

getSrcOfPlayerByCitizenId = function(citizenId)
    -- Fallback - return nil until VRP loads
    return nil
end

-- Register fallback commands immediately
RegisterCommand("racingapp", function(source, args)
    openRacingApp(source)
end, false)

RegisterCommand("racing", function(source, args)
    openRacingApp(source)
end, false)

RegisterCommand("corridas", function(source, args)
    openRacingApp(source)
end, false)

RegisterCommand("automatedraces", function(source, args)
    local message = {
        "[AUTOMATED RACES] Corridas automáticas configuradas:",
        "• Intervalo: A cada 5 minutos",
        "• Mínimo de jogadores: 1", 
        "• Apenas pontos ELO, sem dinheiro",
        "• Classes: A, B, C, S"
    }
    
    if not source or source == 0 then
        -- Comando executado no console do servidor
        return
    end
    
    -- Comando executado por um jogador
    TriggerClientEvent('Notify', source, "AUTOMATED RACES", "Sistema de corridas automáticas ativado!", "verde", 5000)
end, false)

-- Function to handle pullrace command
local function handlePullRaceCommand(source)
    if not source or source == 0 then
        -- Comando executado no console do servidor
        TriggerEvent('cw-racingapp:server:newAutoHost')
        return
    end
    
    -- Comando executado por um jogador
    TriggerClientEvent('Notify', source, "AUTO RACE", "Puxando corrida automática...", "verde", 5000)
    
    -- Send notification to all players
    TriggerClientEvent('Notify', -1, "🏁 RACING", "Nova corrida automática criada!", "verde", 8000)
    
    -- Trigger the event that includes sound
    TriggerEvent('cw-racingapp:server:newAutoHost')
end

RegisterCommand("pullrace", function(source, args)
    handlePullRaceCommand(source)
end, false)

CreateThread(function()
    while not module do
        Wait(100)
    end
    
    local Tunnel = module("vrp", "lib/Tunnel")
    local Proxy = module("vrp", "lib/Proxy")
    
    vRPC = Tunnel.getInterface("vRP")
    vRP = Proxy.getInterface("vRP")
    
    -- Initialize functions after VRP is loaded
    InitializeVRPFunctions()
end)

function InitializeVRPFunctions()
    -- Override global functions with VRP implementations
    
    -- Adds money to user
    addMoney = function(src, moneyType, amount)
        local Passport = vRP.Passport(src)
        if Passport then
            if moneyType == "cash" or moneyType == "money" then
                vRP.GenerateItem(Passport, "dollars", amount)
            elseif moneyType == "bank" then
                vRP.SetSrvData(Passport, "bank", vRP.GetSrvData(Passport, "bank") + amount)
            end
            return true
        end
        return false
    end

    -- Removes money from user
    removeMoney = function(src, moneyType, amount, reason)
        local Passport = vRP.Passport(src)
        if Passport then
            if moneyType == "cash" or moneyType == "money" then
                return vRP.TakeItem(Passport, "dollars", amount)
            elseif moneyType == "bank" then
                local currentBank = vRP.GetSrvData(Passport, "bank")
                if currentBank >= amount then
                    vRP.SetSrvData(Passport, "bank", currentBank - amount)
                    return true
                end
            end
        end
        return false
    end

    -- Checks that user can pay
    canPay = function(src, moneyType, cost)
        local Passport = vRP.Passport(src)
        if Passport then
            if moneyType == "cash" or moneyType == "money" then
                local money = vRP.GetSrvData(Passport, "money")
                return money >= cost
            elseif moneyType == "bank" then
                local bank = vRP.GetSrvData(Passport, "bank")
                return bank >= cost
            end
        end
        return false
    end

    -- Fetches the CitizenId by Source
    getCitizenId = function(src)
        local Passport = vRP.Passport(src)
        return Passport
    end

    -- Fetches the Source of an online player by citizenid
    getSrcOfPlayerByCitizenId = function(citizenId)
        local players = vRP.Players()
        for k, v in pairs(players) do
            if v == citizenId then
                return k
            end
        end
        return nil
    end
    
    
    -- Pull race command for VRP
    RegisterCommand("pullrace", function(source, args)
        handlePullRaceCommand(source)
    end, false)
    
    -- Command to check automated races status (removed duplicate registration)

    -- Alternative item-based trigger (if you have racestablet item)
    AddEventHandler("inventory:Use", function(source, item)
        if item == "racestablet" then
            openRacingApp(source)
        end
    end)
end
