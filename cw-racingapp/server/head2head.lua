local useDebug = Config.Debug

local activeRaces = {}
local Timers = {}

local race = {
    racers = { nil, nil},
    startCoords = nil,
    finishCoords = nil,
    winner = nil,
    started = false,
    finished = false,
    forMoney = false,
    amount = 0
}

-- Sistema de notificações para H2H
local function sendH2HNotification(src, message, type)
    local theme = "default"
    
    if type == 'success' then
        theme = "verde"
    elseif type == 'error' then
        theme = "vermelho"
    elseif type == 'warning' then
        theme = "amarelo"
    elseif type == 'info' then
        theme = "default"
    end
    
    TriggerClientEvent('Notify', src, "H2H", message, theme, 5000)
end

local function generateRaceId()
    local RaceId = "IR-" .. math.random(1111, 9999)
    while activeRaces[RaceId] ~= nil do
        RaceId = "IR-" .. math.random(1111, 9999)
    end
    return RaceId
end

local function getFinish(startCoords)
    for i=1, 100 do
        local finishCoords = ConfigH2H.Finishes[math.random(1,#ConfigH2H.Finishes)]
        local distance = #(finishCoords.xy-startCoords.xy)
        if tonumber(distance) > ConfigH2H.MinimumDistance and tonumber(distance) < ConfigH2H.MaximumDistance then
            return finishCoords
        end
    end
end

local function resetRace(raceId)
    for _, racer in pairs(activeRaces[raceId].racers) do
        if GetPlayerName(racer.source) then
            TriggerClientEvent('cw-racingapp:h2h:client:leaveRace', racer.source, raceId)
        end
    end
    activeRaces[raceId] = nil
end

local function handleTimeout(raceId)
    SetTimeout(Config.RaceResetTimer, function()
        if activeRaces[raceId] then
            if useDebug then print('Cleaning up '.. raceId..' due to inactivit') end
            resetRace(raceId)
        end
    end)
end

RegisterNetEvent('cw-racingapp:h2h:server:leaveRace', function(raceId)
    resetRace(raceId)
end)

RegisterNetEvent('cw-racingapp:h2h:server:setupRace', function(citizenId, racerName, startCoords, amount, waypoint)
    local raceId = generateRaceId()
    if useDebug then
        print('setting up', citizenId, racerName, startCoords, amount)
    end

    local finishCoords = getFinish(startCoords)
    if finishCoords then
        activeRaces[raceId] = {
            raceId = raceId,
            racers = { { citizenId = citizenId, racerName = racerName, source = source } },
            startCoords = startCoords,
            finishCoords = finishCoords,
            winner = nil,
            started = false,
            finished = false,
            amount = amount,
        }
        if useDebug then print('Race Data:', json.encode(activeRaces[raceId], {indent=true})) end
        if ConfigH2H.SoloRace then
            TriggerEvent('cw-racingapp:h2h:server:startRace', raceId) -- Used for debugging
        else
            TriggerClientEvent('cw-racingapp:h2h:client:checkDistance', source, raceId, amount)
        end
        handleTimeout(raceId)
    else
        TriggerClientEvent('cw-racingapp:client:notify', source, Lang("error.failed_to_find_a_waypoint"), "error")
    end
end)

RegisterNetEvent('cw-racingapp:h2h:server:invitePlayer', function(sourceToInvite, raceId, amount, racerName)
    if useDebug then print('[H2H]', racerName, ' is inviting', sourceToInvite,'to', raceId) end
    TriggerClientEvent('cw-racingapp:h2h:client:invite', sourceToInvite, raceId, amount, racerName)
end)

RegisterNetEvent('cw-racingapp:h2h:server:startRace', function(raceId)
    if useDebug then
        print('starting race')
    end
    activeRaces[raceId].started = false
    for citizenId, racer in pairs(activeRaces[raceId].racers) do
        if useDebug then
            print('racer', json.encode(racer, {indent=true}))
        end
        local playerSource = getSrcOfPlayerByCitizenId(racer.citizenId)
        if playerSource ~= nil then
            if useDebug then
                print('pinging player', playerSource)
            end
            if activeRaces[raceId].amount > 0 then
                if useDebug then
                    print('money', activeRaces[raceId].amount)
                end
                removeMoney(playerSource, ConfigH2H.MoneyType, activeRaces[raceId].amount, "H2H")
            end
            TriggerClientEvent('cw-racingapp:h2h:client:raceCountdown', playerSource, activeRaces[raceId])
        end
    end
end)

RegisterNetEvent('cw-racingapp:h2h:server:raceStarted', function(raceId)
    activeRaces[raceId].started = true
end)

RegisterNetEvent('cw-racingapp:h2h:server:joinRace', function(citizenId, racerName, raceId)
    local src = source
    if activeRaces[raceId].started then
        sendH2HNotification(src, "Corrida já começou!", "error")
    elseif activeRaces[raceId].amount > 0 then
        if not canPay(src, ConfigH2H.MoneyType, activeRaces[raceId].amount) then
            sendH2HNotification(src, "Você não tem dinheiro suficiente!", "error")
            return
        end
    end
    
    activeRaces[raceId].racers[#activeRaces[raceId].racers+1] = { citizenId = citizenId, source = src, racerName = racerName }
    sendH2HNotification(src, "Você entrou na corrida H2H!", "success")
    
    if #activeRaces[raceId].racers >= 2 then
        TriggerEvent('cw-racingapp:h2h:server:startRace', raceId)
    end
end)

RegisterNetEvent('cw-racingapp:h2h:server:finishRacer', function(raceId, citizenId, finishTime)
    local src = source
    if useDebug then
        print('finishing', citizenId, 'in race', raceId)
    end
    
    if activeRaces[raceId].winner == nil then
        activeRaces[raceId].winner = citizenId
        sendH2HNotification(src, "🏆 VOCÊ GANHOU A CORRIDA H2H! 🏆", "success")
        
        if activeRaces[raceId].amount > 0 then
            addMoney(src, ConfigH2H.MoneyType, activeRaces[raceId].amount*2)
            sendH2HNotification(src, "Você ganhou $" .. (activeRaces[raceId].amount*2) .. "!", "success")
        end
    else
        activeRaces[raceId].finished = true
        sendH2HNotification(src, "Você perdeu a corrida H2H!", "warning")
    end
end)

registerCommand('h2hsetup', 'Setup Impromptu',{}, false, function(source)
    TriggerClientEvent('cw-racingapp:h2h:client:setupRace', source)
end, true)

registerCommand('h2hjoin', 'join impromtu',{}, false, function(source)
    TriggerClientEvent('cw-racingapp:h2h:client:joinRace', source)
end, true)

registerCommand('impdebugmap', 'Show H2H locations',{}, false, function(source)
    TriggerClientEvent('cw-racingapp:h2h:client:debugMap', source)
end, true)

registerCommand('cwdebughead2head', 'toggle debug for head2head', {}, true, function(source, args)
    useDebug = not useDebug
    print('debug is now:', useDebug)
    TriggerClientEvent('cw-racingapp:h2h:client:toggleDebug',source, useDebug)
end, true)

-- Eventos H2H que estavam faltando
RegisterNetEvent('cw-racingapp:h2h:server:createRace', function(startCoords, forMoney, amount)
    local src = source
    local citizenId = getCitizenId(src)
    local raceId = generateRaceId()
    
    if useDebug then
        print('Creating H2H race:', raceId, 'by', citizenId)
    end
    
    activeRaces[raceId] = {
        racers = {},
        startCoords = startCoords,
        finishCoords = getFinish(startCoords),
        winner = nil,
        started = false,
        finished = false,
        forMoney = forMoney,
        amount = amount or 0
    }
    
    sendH2HNotification(src, "Corrida H2H criada! ID: " .. raceId, 'success')
    handleTimeout(raceId)
end)

RegisterNetEvent('cw-racingapp:h2h:server:challengePlayer', function(targetSource, raceId)
    local src = source
    local citizenId = getCitizenId(src)
    local targetCitizenId = getCitizenId(targetSource)
    
    if activeRaces[raceId] then
        -- Enviar convite para o jogador
        TriggerClientEvent('cw-racingapp:h2h:client:receiveChallenge', targetSource, {
            raceId = raceId,
            challenger = citizenId,
            amount = activeRaces[raceId].amount
        })
        
        sendH2HNotification(src, "Convite enviado para o jogador!", 'info')
        sendH2HNotification(targetSource, "Você recebeu um convite H2H!", 'info')
    end
end)

RegisterNetEvent('cw-racingapp:h2h:server:acceptChallenge', function(raceId)
    local src = source
    local citizenId = getCitizenId(src)
    
    if activeRaces[raceId] and not activeRaces[raceId].started then
        activeRaces[raceId].racers[#activeRaces[raceId].racers+1] = {
            citizenId = citizenId,
            source = src,
            racerName = GetPlayerName(src)
        }
        
        sendH2HNotification(src, "Você aceitou o desafio H2H!", 'success')
        
        -- Se temos 2 jogadores, iniciar a corrida
        if #activeRaces[raceId].racers >= 2 then
            TriggerEvent('cw-racingapp:h2h:server:startRace', raceId)
        end
    end
end)

RegisterNetEvent('cw-racingapp:h2h:server:declineChallenge', function(raceId)
    local src = source
    sendH2HNotification(src, "Você recusou o desafio H2H.", 'warning')
    
    -- Notificar o desafiante
    if activeRaces[raceId] and activeRaces[raceId].racers[1] then
        local challengerSource = activeRaces[raceId].racers[1].source
        sendH2HNotification(challengerSource, "Seu desafio foi recusado.", 'warning')
    end
end)

-- Comando para iniciar H2H
RegisterCommand("h2h", function(source, args)
    local src = source
    sendH2HNotification(src, "Use /h2hsetup para criar uma corrida H2H", 'info')
end, false)

-- Comando para X1 (apelido para H2H)
RegisterCommand("x1", function(source, args)
    local src = source
    sendH2HNotification(src, "Use /h2hsetup para criar uma corrida X1", 'info')
end, false)

-- Callbacks H2H
RegisterServerCallback('cw-racingapp:server:getH2HRaces', function(source)
    local src = source
    local availableRaces = {}
    
    for raceId, raceData in pairs(activeRaces) do
        if not raceData.started and not raceData.finished then
            table.insert(availableRaces, {
                raceId = raceId,
                startCoords = raceData.startCoords,
                finishCoords = raceData.finishCoords,
                amount = raceData.amount,
                racerCount = #raceData.racers
            })
        end
    end
    
    return availableRaces
end)

RegisterServerCallback('cw-racingapp:server:getH2HRaceData', function(source, raceId)
    local src = source
    if activeRaces[raceId] then
        return activeRaces[raceId]
    end
    return nil
end)

RegisterServerCallback('cw-racingapp:server:getH2HPlayerData', function(source)
    local src = source
    local citizenId = getCitizenId(src)
    local playerName = GetPlayerName(src)
    
    return {
        citizenId = citizenId,
        playerName = playerName,
        source = src
    }
end)