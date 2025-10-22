-----------------------
----   Variables   ----
-----------------------
Tracks = {}
Races = {}
UseDebug = Config.Debug
local AvailableRaces = {}
local NotFinished = {}
local Timers = {}
local IsFirstUser = false

local HostingIsAllowed = true
local AutoHostIsAllowed = true

local DefaultTrackMetadata = {
    description = nil,
    raceType = nil
}

-- Deep copy function
function DeepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[DeepCopy(orig_key)] = DeepCopy(orig_value)
        end
        setmetatable(copy, DeepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

local RaceResults = {}
if Config.Debug then
    -- RaceResults = DebugRaceResults
end

local function leftRace(src)
    local player = Player(src)
    player.state.inRace = false
    player.state.raceId = nil
end

local function setInRace(src, raceId)
    local player = Player(src)
    player.state.inRace = true
    player.state.raceId = raceId
end

local function updateRaces()
    if not RADB then
        print('ERROR: RADB not available, waiting...')
        Wait(1000)
        if not RADB then
            print('ERROR: RADB still not available after wait')
            return
        end
    end
    
    local success, tracks = pcall(RADB.getAllRaceTracks)
    if not success then
        print('ERROR: Failed to get tracks from RADB:', tracks)
        return
    end
    
    
    if tracks and #tracks > 0 then
        for _, v in pairs(tracks) do
            if v and v.raceid then
                
                local metadata = DeepCopy(DefaultTrackMetadata)
                if v.metadata then
                    local success, decoded = pcall(json.decode, v.metadata)
                    if success then
                        metadata = decoded
                    end
                end

                local success, result = pcall(function()
                    return {
                        RaceName = v.name or "Unknown",
                        Checkpoints = json.decode(v.checkpoints or "[]"),
                        Creator = v.creatorid or 0,
                        CreatorName = v.creatorname or "Unknown",
                        TrackId = v.raceid or "UNKNOWN",
                        Started = false,
                        Waiting = false,
                        Distance = v.distance or 0,
                        LastLeaderboard = {},
                        Racers = {},
                        MaxClass = nil,
                        Access = json.decode(v.access or "{}") or {},
                        Curated = v.curated or 0,
                        NumStarted = 0,
                        Metadata = metadata
                    }
                end)
                
                if success then
                    Tracks[v.raceid] = result
                else
                    print('ERROR: Failed to create track data:', result)
                end
            end
        end
    end
    
    local success, isFirst = pcall(RADB.getSizeOfRacerNameTable)
    if success then
        IsFirstUser = isFirst == 0
    else
        print('ERROR: Failed to check if first user:', isFirst)
        IsFirstUser = false
    end
end

MySQL.ready(function()
    Wait(2000) -- Wait 2 seconds for RADB to be loaded
    updateRaces()
end)

local function getAmountOfRacers(raceId)
    local AmountOfRacers = 0
    local PlayersFinished = 0
    for _, v in pairs(Races[raceId].Racers) do
        if v.Finished then
            PlayersFinished = PlayersFinished + 1
        end
        AmountOfRacers = AmountOfRacers + 1
    end
    return AmountOfRacers, PlayersFinished
end

local function getTrackIdByRaceId(raceId)
    if Races[raceId] then return Races[raceId].TrackId end
end

local function raceWithTrackIdIsActive(trackId)
    for raceId, raceData in pairs(Races) do
        if raceData.TrackId == trackId then
            if UseDebug then print('found hosted race with same id:', json.encode(raceData, {indent=true})) end
            if raceData.Waiting or raceData.active then
                return true
            end
        end
    end
end

local function handleAddMoney(src, moneyType, amount, racerName, textKey)
    if UseDebug then print('Attempting to give', racerName, amount, moneyType) end

    if moneyType == 'racingcrypto' then
        RacingCrypto.addRacerCrypto(racerName, math.floor(tonumber(amount)))
        TriggerClientEvent('cw-racingapp:client:updateUiData', src, 'crypto', RacingCrypto.getRacerCrypto(racerName))

        TriggerClientEvent('cw-racingapp:client:notify', src,
            Lang(textKey or "participation_trophy_crypto") .. math.floor(amount) .. ' ' .. Config.Payments.cryptoType,
            'success')
    else
        addMoney(src, moneyType, math.floor(tonumber(amount)))
    end
end

local function handleRemoveMoney(src, moneyType, amount, racerName)
    if UseDebug then print('Attempting to charge', racerName, amount, moneyType) end
    if moneyType == 'racingcrypto' then
        if RacingCrypto.removeCrypto(racerName, amount) then
            TriggerClientEvent('cw-racingapp:client:notify', src,
                Lang("remove_crypto") .. math.floor(amount) .. ' ' .. Config.Payments.cryptoType, 'success')
            TriggerClientEvent('cw-racingapp:client:updateUiData', src, 'crypto', RacingCrypto.getRacerCrypto(racerName))

            return true
        end
        TriggerClientEvent('cw-racingapp:client:notify', src,
            Lang("can_not_afford") .. math.floor(amount) .. ' ' .. Config.Payments.cryptoType,
            'error')
    else
        if removeMoney(src, moneyType, math.floor(amount)) then
            if UseDebug then print('^2Payment successful^0') end
            return true
        end
        if UseDebug then print('^1Payment Not successful^0') end
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("can_not_afford") .. ' $' .. math.floor(amount),
            'error')
    end
    return false
end

local function hasEnoughMoney(src, moneyType, amount, racerName)
    if moneyType == 'racingcrypto' then
        return RacingCrypto.hasEnoughCrypto(racerName, amount)
    else
        return canPay(src, moneyType, amount)
    end
end

local function giveSplit(src, racers, position, pot, racerName)
    local total = 0
    if (racers == 2 or racers == 1) and position == 1 then
        total = pot
    elseif racers == 3 and (position == 1 or position == 2) then
        total = Config.Splits['three'][position] * pot
        if UseDebug then print('Payout for ', position, total) end
    elseif racers > 3 and Config.Splits['more'][position] then
        total = Config.Splits['more'][position] * pot
        if UseDebug then print('Payout for ', position, total) end
    else
        if UseDebug then print('Racer finishing at postion', position, ' will not recieve a payout') end
    end
    if total > 0 then
        handleAddMoney(src, Config.Payments.racing, total, racerName)
    end
end

local function handOutParticipationTrophy(src, position, racerName)
    if Config.ParticipationTrophies.amount[position] then
        handleAddMoney(src, Config.Payments.participationPayout, Config.ParticipationTrophies.amount[position], racerName)
    end
end

local function handOutAutomationPayout(src, amount, racerName)
    if Config.Payments.automationPayout then
        handleAddMoney(src, Config.Payments.automationPayout, amount, racerName, 'extra_payout')
    end
end

local function changeRacerName(src, racerName)
    local result = RADB.changeRaceUser(getCitizenId(src), racerName)
    if result then
        TriggerClientEvent('cw-racingapp:client:updateRacerNames', src)
    end
    return result
end

local function getRankingForRacer(racerName)
    if UseDebug then print('Fetching ranking for racer', racerName) end
    return RADB.getRaceUserRankingByName(racerName) or 0
end

local function updateRacerElo(source, racerName, eloChange)
    local currentRank = getRankingForRacer(racerName)
    RADB.updateRacerElo(racerName, eloChange)
    TriggerClientEvent('cw-racingapp:client:updateRanking', source, eloChange, currentRank + eloChange)
end

local function handleEloUpdates(results)
    RADB.updateEloForRaceResult(results)
    for _, racer in ipairs(results) do
        TriggerClientEvent('cw-racingapp:client:updateRanking', racer.RacerSource, racer.TotalChange,
            racer.Ranking + racer.TotalChange)
    end
end

local function resetTrack(raceId, reason)
    if UseDebug then
        print('^6Resetting race^0', raceId)
        print('Reason:', reason)
    end
    Races[raceId].Racers = {}
    Races[raceId].Started = false
    Races[raceId].Waiting = false
    Races[raceId].MaxClass = nil
    Races[raceId].Ghosting = false
    Races[raceId].GhostingTime = nil
end

local function createRaceResultsIfNotExisting(raceId)
    if UseDebug then print('Verifying race result table for ', raceId) end
    local existingResults = RaceResults[raceId]
    if not existingResults then
        if UseDebug then print('Initializing race result', raceId) end
        RaceResults[raceId] = {}
        return true
    end
    if not RaceResults[raceId].Result then
        if UseDebug then print('Initializing result table for', raceId) end
        RaceResults[raceId].Result = {}
    end
end

local function completeRace(amountOfRacers, raceData, availableKey)

    local totalLaps = raceData.TotalLaps
    if amountOfRacers == 1 then
        if UseDebug then print('^3Only one racer. No ELO change^0') end
    elseif amountOfRacers > 1 then

        -- Update crew statistics for all participants
        local crewStats = {}
        for citizenId, racerData in pairs(RaceResults[raceData.RaceId].Result) do
            local crewName = getCrewNameFromCitizenId(citizenId)
            if crewName then
                if not crewStats[crewName] then
                    crewStats[crewName] = { races = 0, wins = 0, members = {} }
                end
                crewStats[crewName].races = crewStats[crewName].races + 1
                table.insert(crewStats[crewName].members, citizenId)
                
                -- Check if this member won (position 1)
                if racerData.Placement == 1 then
                    crewStats[crewName].wins = crewStats[crewName].wins + 1
                end
            end
        end
        
        -- Update crew statistics in database
        for crewName, stats in pairs(crewStats) do
            if UseDebug then print('Updating crew stats for:', crewName, 'races:', stats.races, 'wins:', stats.wins) end
            exports.oxmysql:executeSync('UPDATE characters SET RaceParticipations = RaceParticipations + ? WHERE crew_name = ?', {stats.races, crewName})
            if stats.wins > 0 then
                exports.oxmysql:executeSync('UPDATE characters SET RaceWins = RaceWins + ? WHERE crew_name = ?', {stats.wins, crewName})
            end
        end

        if AvailableRaces[availableKey].Ranked then
            if UseDebug then print('Is ranked. Doing Elo check') end
            if UseDebug then print('^2 Pre elo', json.encode(RaceResults[raceData.RaceId].Result)) end
            local crewResult
            RaceResults[raceData.RaceId].Result, crewResult = calculateTrueSkillRatings(RaceResults
                [raceData.RaceId].Result)

            if UseDebug then print('^2 Post elo', json.encode(RaceResults[raceData.RaceId].Result)) end
            handleEloUpdates(RaceResults[raceData.RaceId].Result)
            if #crewResult > 1 then
                if UseDebug then print('Enough crews to give ranking') end
                HandleCrewEloUpdates(crewResult)
            end
        end
        local raceEntryData = {
            raceId = raceData.RaceId,
            trackId = raceData.TrackId,
            results = RaceResults[raceData.RaceId].Result,
            amountOfRacers = amountOfRacers,
            laps = totalLaps,
            hostName = raceData.SetupRacerName,
            maxClass = raceData.MaxClass,
            ghosting = raceData.Ghosting,
            ranked = raceData.Ranked,
            reversed = Races[raceData.RaceId].Reversed,
            firstPerson = raceData.FirstPerson,
            automated = raceData.Automated,
            hidden = raceData.Hidden,
            silent = raceData.Silent,
            buyIn = raceData.BuyIn
        }

        RESDB.addRaceEntry(raceEntryData)
    end

    resetTrack(raceData.RaceId, 'Race is over')
    table.remove(AvailableRaces, availableKey)
    RaceResults[raceData.RaceId].Data.FinishTime = os.time()
    NotFinished[raceData.RaceId] = nil
    Races[raceData.RaceId].MaxClass = nil
end

RegisterNetEvent('cw-racingapp:server:finishPlayer',
    function(raceData, totalTime, totalLaps, bestLap, carClass, vehicleModel, ranking, racingCrew)
        local src = source
        local raceId = raceData.RaceId
        local availableKey = GetOpenedRaceKey(raceData.RaceId)
        local racerName = raceData.RacerName
        local playersFinished = 0
        local amountOfRacers = 0
        local reversed = Races[raceData.RaceId].Reversed

        if UseDebug then
            print('^3=== Finishing Racer: ' .. racerName .. ' ===^0')
        end

        local bestLapDef
        if totalLaps < 2 then
            if UseDebug then
                print('Sprint or 1 lap')
            end
            bestLapDef = totalTime
        else
            if UseDebug then
                print('2+ laps')
            end
            bestLapDef = bestLap
        end

        createRaceResultsIfNotExisting(raceData.RaceId)
        local raceResult = {
            TotalTime = totalTime,
            BestLap = bestLapDef,
            CarClass = carClass,
            VehicleModel = vehicleModel,
            RacerName = racerName,
            Ranking = ranking,
            RacerSource = src,
            RacingCrew = racingCrew
        }
        table.insert(RaceResults[raceId].Result, raceResult)

        local amountOfRacersThatLeft = 0
        if NotFinished and NotFinished[raceId] then
            if UseDebug then print('Race had racers that left before completion') end
           amountOfRacersThatLeft = #NotFinished[raceId]
        end

        for _, v in pairs(Races[raceId].Racers) do
            if v.Finished then
                playersFinished = playersFinished + 1
            end
            amountOfRacers = amountOfRacers + 1
        end
        if amountOfRacers > 1 then
            RADB.increaseRaceCount(racerName, playersFinished)
        end
        if UseDebug then
            print('Total: ', totalTime)
            print('Best Lap: ', bestLapDef)
            print('Place:', playersFinished, Races[raceData.RaceId].BuyIn)
        end
        if Races[raceData.RaceId].BuyIn > 0 then
            giveSplit(src, amountOfRacers, playersFinished,
                Races[raceData.RaceId].BuyIn * Races[raceData.RaceId].AmountOfRacers, racerName)
        end

        -- Participation amount (global)
        if Config.ParticipationTrophies.enabled and Config.ParticipationTrophies.minimumOfRacers <= amountOfRacers then
            if UseDebug then print('Participation Trophies are enabled') end
            local distance = Tracks[raceData.TrackId].Distance
            if totalLaps > 1 then
                distance = distance * totalLaps
            end
            if distance > Config.ParticipationTrophies.minumumRaceLength then
                if not Config.ParticipationTrophies.requireBuyins or (Config.ParticipationTrophies.requireBuyins and Config.ParticipationTrophies.buyInMinimum >= Races[raceData.RaceId].BuyIn) then
                    if UseDebug then print('Participation Trophies buy in check passed', src) end
                    if not Config.ParticipationTrophies.requireRanked or (Config.ParticipationTrophies.requireRanked and AvailableRaces[availableKey].Ranked) then
                        if UseDebug then print('Participation Trophies Rank check passed, handing out to', src) end
                        handOutParticipationTrophy(src, playersFinished, racerName)
                    end
                end
            else
                if UseDebug then
                    print('Race length was to short: ', distance, ' Minumum required:',
                        Config.ParticipationTrophies.minumumRaceLength)
                end
            end
        end
        if UseDebug then
            print('Race has participation price', Races[raceData.RaceId].ParticipationAmount,
                Races[raceData.RaceId].ParticipationCurrency)
        end

        -- Participation amount (on this specific race)
        if Races[raceData.RaceId].ParticipationAmount and Races[raceData.RaceId].ParticipationAmount > 0 then
            local amountToGive = math.floor(Races[raceData.RaceId].ParticipationAmount)
            if Config.ParticipationAmounts.positionBonuses[playersFinished] then
                amountToGive = math.floor(amountToGive +
                    amountToGive * Config.ParticipationAmounts.positionBonuses[playersFinished])
            end
            if UseDebug then
                print('Race has participation price set', Races[raceData.RaceId].ParticipationAmount,
                    amountToGive, Races[raceData.RaceId].ParticipationCurrency)
            end
            handleAddMoney(src, Races[raceData.RaceId].ParticipationCurrency, amountToGive, racerName,
                'participation_trophy_crypto')
        end

        if Races[raceData.RaceId].Automated then
            if UseDebug then print('Race Was Automated', src) end
            if Config.AutomatedOptions.payouts then
                local payoutData = Config.AutomatedOptions.payouts
                if UseDebug then print('Automation Payouts exist', src) end
                local total = 0
                if payoutData.participation then total = total + payoutData.participation end
                if payoutData.perRacer then
                    total = total + payoutData.perRacer * amountOfRacers
                end
                if playersFinished == 1 and payoutData.winner then
                    total = total + payoutData.winner
                end
                handOutAutomationPayout(src, total, racerName)
            end
        end

        local bountyResult = BountyHandler.checkBountyCompletion(racerName, vehicleModel, ranking, raceData.TrackId,
            carClass, bestLapDef, totalLaps == 0, reversed)
        if bountyResult then
            addMoney(src, Config.Payments.bountyPayout, bountyResult)
            TriggerClientEvent('cw-racingapp:client:notify', src, Lang("bounty_claimed") .. tostring(bountyResult),
                'success')
        end

        local raceType = 'Sprint'
        if totalLaps > 0 then raceType = 'Circuit' end

        -- PB check 
        local timeData = {
            trackId = raceData.TrackId,
            racerName = racerName,
            carClass = carClass,
            raceType = raceType,
            reversed = reversed,
            vehicleModel = vehicleModel,
            time = bestLapDef,
        }

        local newPb = RESDB.addTrackTime(timeData)
        if newPb then
            TriggerClientEvent('cw-racingapp:client:notify', src,
                string.format(Lang("race_record"), raceData.RaceName, MilliToTime(bestLapDef)), 'success')
        end

        AvailableRaces[availableKey].RaceData = Races[raceData.RaceId]
        for _, racer in pairs(Races[raceData.RaceId].Racers) do
            TriggerClientEvent('cw-racingapp:client:playerFinish', racer.RacerSource, raceData.RaceId, playersFinished,
                racerName)
            leftRace(racer.RacerSource)
        end

        if playersFinished + amountOfRacersThatLeft == amountOfRacers then
            completeRace(amountOfRacers, raceData, availableKey)
        end

        if UseDebug then
            print('^2/=/ Finished Racer: ' .. racerName .. ' /=/^0')
        end
    end)

RegisterNetEvent('cw-racingapp:server:createTrack', function(RaceName, RacerName, Checkpoints)
    local src = source
    if UseDebug then print(src, RacerName, 'is creating a track named', RaceName) end

    if IsPermissioned(RacerName, 'create') then
        if IsNameAvailable(RaceName) then
            TriggerClientEvent('cw-racingapp:client:startRaceEditor', src, RaceName, RacerName, nil, Checkpoints)
        else
            TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_name_exists"), 'error')
        end
    else
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("no_permission"), 'error')
    end
end)

local function isToFarAway(src, trackId, reversed)
    if reversed then
        return Config.JoinDistance <=
            #(GetEntityCoords(GetPlayerPed(src)).xy - vec2(Tracks[trackId].Checkpoints[#Tracks[trackId].Checkpoints].coords.x, Tracks[trackId].Checkpoints[#Tracks[trackId].Checkpoints].coords.y))
    else
        return Config.JoinDistance <=
            #(GetEntityCoords(GetPlayerPed(src)).xy - vec2(Tracks[trackId].Checkpoints[1].coords.x, Tracks[trackId].Checkpoints[1].coords.y))
    end
end

RegisterNetEvent('cw-racingapp:server:joinRace', function(RaceData)
    local src = source
    local playerVehicleEntity = RaceData.PlayerVehicleEntity
    local raceName = RaceData.RaceName
    local raceId = RaceData.RaceId
    local trackId = RaceData.TrackId
    local availableKey = GetOpenedRaceKey(RaceData.RaceId)
    local citizenId = getCitizenId(src)
    local currentRaceId = GetCurrentRace(citizenId)
    local racerName = RaceData.RacerName
    local racerCrew = RaceData.RacerCrew

    if UseDebug then
        print('======= Joining Race =======')
        print('race id', raceId )
        print('track id', trackId )
        print('AvailableKey', availableKey)
        print('PreviousRaceKey', GetOpenedRaceKey(currentRaceId))
        print('Racer Name:', racerName)
        print('Racer Crew:', racerCrew)
    end

    -- Distance check disabled - teleport system handles location
    -- if isToFarAway(src, trackId, RaceData.Reversed) then
    --     if RaceData.Reversed then
    --         TriggerClientEvent('cw-racingapp:client:notCloseEnough', src,
    --             Tracks[trackId].Checkpoints[#Tracks[trackId].Checkpoints].coords.x,
    --             Tracks[trackId].Checkpoints[#Tracks[trackId].Checkpoints].coords.y)
    --     else
    --         TriggerClientEvent('cw-racingapp:client:notCloseEnough', src, Tracks[trackId].Checkpoints[1].coords.x,
    --             Tracks[trackId].Checkpoints[1].coords.y)
    --     end
    --     return
    -- end
    if not Races[raceId].Started then
        if UseDebug then
            print('Join: BUY IN', RaceData.BuyIn)
        end

        if RaceData.BuyIn > 0 and not hasEnoughMoney(src, Config.Payments.racing, RaceData.BuyIn, racerName) then
            TriggerClientEvent('cw-racingapp:client:notify', src, Lang("not_enough_money"))
        else
            if currentRaceId ~= nil then
                local amountOfRacers = 0
                local PreviousRaceKey = GetOpenedRaceKey(currentRaceId)
                for _, _ in pairs(Races[currentRaceId].Racers) do
                    amountOfRacers = amountOfRacers + 1
                end
                Races[currentRaceId].Racers[citizenId] = nil
                if (amountOfRacers - 1) == 0 then
                    Races[currentRaceId].Racers = {}
                    Races[currentRaceId].Started = false
                    Races[currentRaceId].Waiting = false
                    table.remove(AvailableRaces, PreviousRaceKey)
                    TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_last_person"))
                    TriggerClientEvent('cw-racingapp:client:leaveRace', src)
                    leftRace(src)
                else
                    AvailableRaces[PreviousRaceKey].RaceData = Races[currentRaceId]
                    TriggerClientEvent('cw-racingapp:client:leaveRace', src)
                    leftRace(src)
                end
            end

            local amountOfRacers = 0
            for _, _ in pairs(Races[raceId].Racers) do
                amountOfRacers = amountOfRacers + 1
            end
            if amountOfRacers == 0 and not Races[raceId].Automated then
                if UseDebug then print('setting creator') end
                Races[raceId].SetupCitizenId = citizenId
            end
            Races[raceId].AmountOfRacers = amountOfRacers + 1
            if UseDebug then print('Current amount of racers in this race:', amountOfRacers) end
            if RaceData.BuyIn > 0 then
                if not handleRemoveMoney(src, Config.Payments.racing, RaceData.BuyIn, racerName) then
                    return
                end
            end

            Races[raceId].Racers[citizenId] = {
                Checkpoint = 1,
                Lap = 1,
                Finished = false,
                RacerName = racerName,
                RacerCrew = racerCrew,
                Placement = 0,
                PlayerVehicleEntity = playerVehicleEntity,
                RacerSource = src,
                CheckpointTimes = {},
            }
            AvailableRaces[availableKey].RaceData = Races[raceId]
            
            TriggerClientEvent('cw-racingapp:client:joinRace', src, Races[raceId], Tracks[trackId].Checkpoints, RaceData.Laps, racerName)
            for _, racer in pairs(Races[raceId].Racers) do
                TriggerClientEvent('cw-racingapp:client:updateActiveRacers', racer.RacerSource, raceId,
                    Races[raceId].Racers)
            end
            if not Races[raceId].Automated then
                local creatorsource = getSrcOfPlayerByCitizenId(AvailableRaces[availableKey].SetupCitizenId)
                if creatorsource and creatorsource ~= src then
                    TriggerClientEvent('cw-racingapp:client:notify', creatorsource, Lang("race_someone_joined"))
                end
            end
        end
    else
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_already_started"))
    end
end)

local function assignNewOrganizer(raceId, src)
    for citId, racerData in pairs(Races[raceId].Racers) do
        if citId ~= getCitizenId(src) then
            Races[raceId].SetupCitizenId = citId
            TriggerClientEvent('cw-racingapp:client:notify', racerData.RacerSource, Lang("new_host"))
            for _, racer in pairs(Races[raceId].Racers) do
                TriggerClientEvent('cw-racingapp:client:updateOrganizer', racer.RacerSource, raceId, citId)
            end
            return
        end
    end
end

local function leaveCurrentRace(src)
    TriggerClientEvent('cw-racingapp:server:leaveCurrentRace', src)    
end exports('leaveCurrentRace', leaveCurrentRace)

RegisterNetEvent('cw-racingapp:server:leaveCurrentRace', function(src)
    leaveCurrentRace(src)
end)

RegisterNetEvent('cw-racingapp:server:leaveRace', function(RaceData, reason)
    if UseDebug then
        print('Player left race', source)
        print('Reason:', reason)
        print(json.encode(RaceData, { indent = true }))
    end
    local src = source
    local citizenId = getCitizenId(src)

    if not citizenId then print('ERROR: Could not find identifier for player with src', src) return end

    local racerName = RaceData.RacerName

    local raceId = RaceData.RaceId
    local availableKey = GetOpenedRaceKey(raceId)

    if not Races[raceId].Automated then
        local creator = getSrcOfPlayerByCitizenId(AvailableRaces[availableKey].SetupCitizenId)

        if creator then
            TriggerClientEvent('cw-racingapp:client:notify', creator, Lang("race_someone_left"))
        end
    end

    local amountOfRacers = 0
    local playersFinished = 0
    for _, v in pairs(Races[raceId].Racers) do
        if v.Finished then
            playersFinished = playersFinished + 1
        end
        amountOfRacers = amountOfRacers + 1
    end
    if NotFinished[raceId] ~= nil then
        NotFinished[raceId][#NotFinished[raceId] + 1] = {
            TotalTime = "DNF",
            BestLap = "DNF",
            Holder = racerName
        }
    else
        NotFinished[raceId] = {}
        NotFinished[raceId][#NotFinished[raceId] + 1] = {
            TotalTime = "DNF",
            BestLap = "DNF",
            Holder = racerName
        }
    end
    -- Races[raceId].Racers[citizenId] = nil
    if Races[raceId].SetupCitizenId == citizenId then
        assignNewOrganizer(raceId, src)
    end

    -- Check if last racer
    if (amountOfRacers - 1) == 0 then
        -- Complete race if leaving last
        if not Races[raceId].Automated then
            if UseDebug then print(citizenId, ' was the last racer. ^3Cancelling race^0') end
            resetTrack(raceId, 'last racer left')
            table.remove(AvailableRaces, availableKey)
            TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_last_person"))
            NotFinished[raceId] = nil
        else
            if UseDebug then print(citizenId, ' was the last racer. ^Race was Automated. No cancel.^0') end
        end
    else
        AvailableRaces[availableKey].RaceData = Races[raceId]
    end
    if playersFinished == amountOfRacers - 1 then
        if UseDebug then print('Last racer to leave') end
        completeRace(amountOfRacers, RaceData, availableKey)
    end

    TriggerClientEvent('cw-racingapp:client:leaveRace', src)
    leftRace(src)

    for _, racer in pairs(Races[raceId].Racers) do
        TriggerClientEvent('cw-racingapp:client:updateRaceRacers', racer.RacerSource, raceId, Races[raceId].Racers)
    end
    if RaceData.Ranked and RaceData.Started and RaceData.TotalRacers > 1 and reason then
        if Config.EloPunishments[reason] then
            updateRacerElo(src, racerName, Config.EloPunishments[reason])
        end
    end
end)

local function createTimeoutThread(raceId)
    CreateThread(function()
        local count = 0
        while Races[raceId] and Races[raceId].Waiting do
            Wait(1000)
            if count < Config.TimeOutTimerInMinutes * 60 then
                count = count + 1
            else
                local availableKey = GetOpenedRaceKey(raceId)
                if UseDebug then print('Available Key', availableKey) end
                if Races[raceId].Automated then
                    if UseDebug then print('Track Timed Out. Automated') end
                    local amountOfRacers = getAmountOfRacers(raceId)
                    if amountOfRacers >= Config.AutomatedOptions.minimumParticipants then
                        if UseDebug then print('Enough Racers to start automated') end
                        TriggerEvent('cw-racingapp:server:startRace', raceId)
                    else
                        table.remove(AvailableRaces, availableKey)
                        resetTrack(raceId, 'not enough players to start automated')

                        if amountOfRacers > 0 then
                            for cid, _ in pairs(Races[raceId].Racers) do
                                local racerSource = getSrcOfPlayerByCitizenId(cid)
                                if racerSource ~= nil then
                                    TriggerClientEvent('cw-racingapp:client:notify', racerSource, Lang("race_timed_out"),
                                        'error')
                                    TriggerClientEvent('cw-racingapp:client:leaveRace', racerSource)
                                    leftRace(racerSource)
                                end
                            end
                        end
                    end
                else
                    if UseDebug then print('Track Timed Out. NOT automated', raceId) end
                    for cid, _ in pairs(Races[raceId].Racers) do
                        local racerSource = getSrcOfPlayerByCitizenId(cid)
                        if racerSource then
                            TriggerClientEvent('cw-racingapp:client:notify', racerSource, Lang("race_timed_out"), 'error')
                            TriggerClientEvent('cw-racingapp:client:leaveRace', racerSource)
                            leftRace(racerSource)
                        end
                    end
                    table.remove(AvailableRaces, availableKey)
                    resetTrack(raceId, 'Timed out, Not automated')
                end
            end
        end
    end)
end

local function joinRaceByRaceId(raceId, src)
    if src and raceId then
        TriggerClientEvent('cw-racingapp:client:joinRaceByRaceId', src, raceId)
        return true
    else
        print('Attempted to join a race but was lacking input')
        print('raceid:', raceId)
        print('src:', src)
        return false
    end
end exports('joinRaceByRaceId', joinRaceByRaceId)

local function setupRace(setupData, src)
    local trackId = setupData.trackId
    local laps = setupData.laps
    local racerName = setupData.hostName or Config.AutoMatedRacesHostName
    local maxClass = setupData.maxClass
    local ghostingEnabled = setupData.ghostingEnabled
    local ghostingTime = setupData.ghostingTime
    local buyIn = setupData.buyIn
    local ranked = setupData.ranked
    local reversed = setupData.reversed
    local participationAmount = setupData.participationMoney
    local participationCurrency = setupData.participationCurrency
    local firstPerson = setupData.firstPerson
    local automated = setupData.automated
    local hidden = setupData.hidden
    local silent = setupData.silent
                         
    if not HostingIsAllowed then
        if src then TriggerClientEvent('cw-racingapp:client:notify', src, Lang("hosting_not_allowed"), 'error') end
        return
    end

    local raceId = GenerateRaceId()

    if UseDebug then
        print('Setting up race', 'RaceID: '..raceId or 'FAILED TO GENERATE RACE ID', json.encode(setupData))
    end
    
    if not src then
        if UseDebug then
            print('No Source was included. Defaulting to Automated')
        end
        automated = true
    end

    if Tracks[trackId] ~= nil then
        Races[raceId] = {}
        if not Races[raceId].Waiting then
            if not Races[raceId].Started then
                local setupId = 0
                if src then
                    setupId = getCitizenId(src)
                end
                if Tracks[trackId] then
                    Tracks[trackId].NumStarted = Tracks[trackId].NumStarted + 1
                else
                    print('ERROR: Could not find track id', trackId)
                end

                local expirationTime = os.time() + 60 * Config.TimeOutTimerInMinutes

                Races[raceId].RaceId = raceId
                Races[raceId].TrackId = trackId
                Races[raceId].RaceName = Tracks[trackId].RaceName
                Races[raceId].Waiting = true
                Races[raceId].Automated = automated
                Races[raceId].SetupRacerName = racerName
                Races[raceId].MaxClass = maxClass
                Races[raceId].SetupCitizenId = setupId
                Races[raceId].Ghosting = ghostingEnabled
                Races[raceId].GhostingTime = ghostingTime
                Races[raceId].BuyIn = buyIn
                Races[raceId].Ranked = ranked
                Races[raceId].Laps = laps
                Races[raceId].Reversed = reversed
                Races[raceId].FirstPerson = firstPerson
                Races[raceId].Hidden = hidden
                Races[raceId].ParticipationAmount = tonumber(participationAmount)
                Races[raceId].ParticipationCurrency = participationCurrency
                Races[raceId].ExpirationTime = expirationTime
                Races[raceId].Racers = {}

                local allRaceData = {
                    TrackData = Tracks[trackId],
                    RaceData = Races[raceId],
                    Laps = laps,
                    RaceId = raceId,
                    TrackId = trackId,
                    SetupCitizenId = setupId,
                    SetupRacerName = racerName,
                    MaxClass = maxClass,
                    Ghosting = ghostingEnabled,
                    GhostingTime = ghostingTime,
                    BuyIn = buyIn,
                    Ranked = ranked,
                    Reversed = reversed,
                    ParticipationAmount = participationAmount,
                    ParticipationCurrency = participationCurrency,
                    FirstPerson = firstPerson,
                    ExpirationTime = expirationTime,
                    Hidden = hidden,
                }
                AvailableRaces[#AvailableRaces + 1] = allRaceData
                if not automated then
                    TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_created"), 'success')
                    TriggerClientEvent('cw-racingapp:client:readyJoinRace', src, allRaceData)
                end

                local cleanedRaceData = {}
                for i, v in pairs(allRaceData) do
                    cleanedRaceData[i] = v
                end
                cleanedRaceData.TrackData = nil

                RaceResults[raceId] = { Data = cleanedRaceData, Result = {} }

                if Config.NotifyRacers and not silent then
                    TriggerClientEvent('cw-racingapp:client:notifyRacers', -1,
                        'New Race Available')
                end
                createTimeoutThread(raceId)
                return raceId
            else
                if src then TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_already_started"), 'error') end
                return false
            end
        else
            if src then TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_already_started"), 'error') end
            return false
        end
    else
        if src then TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_doesnt_exist"), 'error') end
        return false
    end
end exports('setupRace', setupRace)

RegisterServerCallback('cw-racingapp:server:setupRace', function(source, setupData)
    local src = source
    if not Tracks[setupData.trackId] then
       TriggerClientEvent('cw-racingapp:client:notify', src, Lang("no_track_found").. tostring(setupData.trackId), 'error')
    end
    -- Distance check disabled - teleport system handles location
    -- if isToFarAway(src, setupData.trackId, setupData.reversed) then
    --     if setupData.reversed then
    --         TriggerClientEvent('cw-racingapp:client:notCloseEnough', src,
    --             Tracks[setupData.trackId].Checkpoints[#Tracks[setupData.trackId].Checkpoints].coords.x,
    --             Tracks[setupData.trackId].Checkpoints[#Tracks[setupData.trackId].Checkpoints].coords.y)
    --     else
    --         TriggerClientEvent('cw-racingapp:client:notCloseEnough', src,
    --             Tracks[setupData.trackId].Checkpoints[1].coords.x, Tracks[setupData.trackId].Checkpoints[1].coords.y)
    --     end
    --     return false
    -- end
    if (setupData.buyIn > 0 and not hasEnoughMoney(src, Config.Payments.racing, setupData.buyIn, setupData.hostName)) then
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("not_enough_money"))
    else
        setupData.automated = false
        return setupRace(setupData, src)
    end
end)

-- AUTOMATED RACES SETUP
function generateAutomatedRace()
    print('DEBUG: generateAutomatedRace called')
    if not AutoHostIsAllowed then
        print('DEBUG: Auto hosting is not allowed')
        if UseDebug then print('Auto hosting is not allowed') end
        return
    end
    print('DEBUG: Auto hosting is allowed, checking races...')
    print('DEBUG: Number of automated races configured:', #Config.AutomatedRaces)
    local race = Config.AutomatedRaces[math.random(1, #Config.AutomatedRaces)]
    if race == nil or race.trackId == nil then
        print('DEBUG: Race or trackId is nil')
        if UseDebug then print('Race Id for generated track was nil, your Config might be incorrect') end
        return
    end
    print('DEBUG: Selected race track ID:', race.trackId)
    if Tracks[race.trackId] == nil then
        print('DEBUG: Track not found:', race.trackId)
        if UseDebug then print('ID' .. race.trackId .. ' does not exist in tracks list') end
        return
    end
    if raceWithTrackIdIsActive(race.trackId) then
        print('DEBUG: Race already active on track:', race.trackId)
        if UseDebug then print('Automation: Race on track is already active, skipping Automated') end
        return
    end
    print('DEBUG: Creating new Automated Race from', race.trackId)
    if UseDebug then print('Creating new Automated Race from', race.trackId) end
    
    -- Play notification sound for automated race
    TriggerClientEvent('cw-racingapp:client:playAutomatedRaceSound', -1)
    
    local ranked = race.ranked
    if ranked == nil then
        if UseDebug then print('Automation: ranked was not set. defaulting to ranked = true') end
        ranked = true
    end
    local reversed = race.reversed
    if reversed == nil then
        if UseDebug then print('Automation: rank was not set. defaulting to reversed = false') end
        reversed = false
    end
    race.automated = true

    setupRace(race, nil)
end

RegisterNetEvent('cw-racingapp:server:newAutoHost', function()
    generateAutomatedRace()
end)

if Config.AutomatedOptions and Config.AutomatedRaces then
    CreateThread(function()
        print('DEBUG: Automated races thread started')
        if #Config.AutomatedRaces == 0 then
            print('DEBUG: No automated races configured')
            if UseDebug then print('^3No automated races in list') end
            return
        end
        print('DEBUG: Found', #Config.AutomatedRaces, 'automated races configured')
        while true do
            print('DEBUG: Waiting for automated race interval...')
            if not UseDebug then Wait(Config.AutomatedOptions.timeBetweenRaces) else Wait(1000) end
            print('DEBUG: Interval completed, generating automated race...')
            generateAutomatedRace()
            Wait(Config.AutomatedOptions.timeBetweenRaces)
        end
    end)
else
    print('DEBUG: Automated races not configured properly')
end

RegisterNetEvent('cw-racingapp:server:updateRaceState', function(raceId, started, waiting)
    Races[raceId].Waiting = waiting
    Races[raceId].Started = started
end)

local function timer(raceId)
    local trackId = getTrackIdByRaceId(raceId)
    local NumStartedAtTimerCreation = Tracks[trackId].NumStarted
    if UseDebug then
        print('============== Creating timer for ' ..
            raceId .. ' with numstarted: ' .. NumStartedAtTimerCreation .. ' ==============')
    end
    SetTimeout(Config.RaceResetTimer, function()
        if UseDebug then print('============== Checking timer for ' .. raceId .. ' ==============') end
        if NumStartedAtTimerCreation ~= Tracks[trackId].NumStarted then
            if UseDebug then
                print('============== A new race has been created on this track. Canceling ' ..
                    trackId .. ' ==============')
            end
            return
        end
        if next(Races[raceId].Racers) == nil then
            if UseDebug then print('Race is finished. Canceling timer ' .. raceId .. '') end
            return
        end
        if math.abs(GetGameTimer() - Timers[raceId]) < Config.RaceResetTimer then
            Timers[raceId] = GetGameTimer()
            timer(raceId)
        else
            if UseDebug then print('Cleaning up race ' .. raceId) end
            for _, racer in pairs(Races[raceId].Racers) do
                TriggerClientEvent('cw-racingapp:client:leaveRace', racer.RacerSource)
                leftRace(racer.RacerSource)
            end
            resetTrack(raceId, 'Idle race')
            NotFinished[raceId] = nil
            local AvailableKey = GetOpenedRaceKey(trackId)
            if AvailableKey then
                table.remove(AvailableRaces, AvailableKey)
            end
        end
    end)
end

local function startTimer(raceId)
    if UseDebug then print('Starting timer', raceId) end
    Timers[raceId] = GetGameTimer()
    timer(raceId)
end

local function updateTimer(raceId)
    if UseDebug then print('Updating timer', raceId) end
    Timers[raceId] = GetGameTimer()
end

-- Helper function for notifications using your script's system
local function sendNotification(src, message, type)
    local theme = "default"
    
    if type == 'sucesso' or type == 'success' then
        theme = "verde"
    elseif type == 'error' then
        theme = "vermelho"
    elseif type == 'info' then
        theme = "default"
    elseif type == 'amarelo' or type == 'warning' then
        theme = "amarelo"
    end
    
    TriggerClientEvent('Notify', src, "RACING", message, theme, 5000)
end

RegisterNetEvent('cw-racingapp:server:updateRacerData', function(raceId, checkpoint, lap, finished, raceTime)
    local src = source
    local citizenId = getCitizenId(src)
    
    if not Races[raceId] or not Races[raceId].Racers or not Races[raceId].Racers[citizenId] then
        return
    end
    
    if Races[raceId].Racers[citizenId] then
        Races[raceId].Racers[citizenId].Checkpoint = checkpoint
        Races[raceId].Racers[citizenId].Lap = lap
        Races[raceId].Racers[citizenId].Finished = finished
        Races[raceId].Racers[citizenId].RaceTime = raceTime

        Races[raceId].Racers[citizenId].CheckpointTimes[#Races[raceId].Racers[citizenId].CheckpointTimes + 1] = {
            lap =
                lap,
            checkpoint = checkpoint,
            time = raceTime
        }

        -- If race is finished, calculate points and update database
        if finished then
            -- Calculate position and points
            local position = 1
            local totalRacers = 0
            local fasterRacers = 0
            
            -- Count total racers and find position
            for racerId, racer in pairs(Races[raceId].Racers) do
                if racer.Finished and racer.RaceTime < raceTime then
                    fasterRacers = fasterRacers + 1
                end
                if racer.Finished then
                    totalRacers = totalRacers + 1
                end
            end
            
            position = fasterRacers + 1
            
            -- Calculate points based on position
            local points = 0
            if position == 1 then
                points = 25
            elseif position == 2 then
                points = 20
            elseif position == 3 then
                points = 15
            elseif position <= 5 then
                points = 10
            elseif position <= 10 then
                points = 5
            else
                points = 2
            end
            
            
            -- Send notification to player about race finish
            local positionText = position .. "º lugar"
            local icon = "🏁"
            local color = {255, 255, 255} -- White
            
            if position == 1 then
                icon = "🏆"
                color = {255, 215, 0} -- Gold
                positionText = "1º LUGAR!"
            elseif position == 2 then
                icon = "🥈"
                color = {192, 192, 192} -- Silver
                positionText = "2º LUGAR"
            elseif position == 3 then
                icon = "🥉"
                color = {205, 127, 50} -- Bronze
                positionText = "3º LUGAR"
            end
            
            TriggerClientEvent('Notify', src, "CORRIDA FINALIZADA", "Você terminou em " .. positionText .. " e ganhou " .. points .. " pontos!", "verde", 8000)
            
            -- Update database
            exports.oxmysql:execute('UPDATE characters SET RacePoints = RacePoints + ?, RaceParticipations = RaceParticipations + 1 WHERE id = ?', {
                points, tonumber(citizenId)
            })
            
            if position == 1 then
                exports.oxmysql:execute('UPDATE characters SET RaceWins = RaceWins + 1 WHERE id = ?', {
                    tonumber(citizenId)
                })
            end
            
            -- Save race result to history
            local raceData = Races[raceId]
            local trackName = "Unknown Track"
            local trackId = "UNKNOWN"
            
            if raceData then
                if raceData.RaceName then
                    trackName = raceData.RaceName
                end
                if raceData.TrackId then
                    trackId = raceData.TrackId
                end
            end
            
            
            -- Check if race_results table exists before inserting
            local tableExists = exports.oxmysql:executeSync([[
                SELECT COUNT(*) as count 
                FROM information_schema.tables 
                WHERE table_schema = DATABASE() 
                AND table_name = 'race_results'
            ]])
            
            if tableExists and tableExists[1] and tableExists[1].count > 0 then
                -- Insert race result
                local insertResult = exports.oxmysql:execute([[
                    INSERT INTO race_results (race_id, track_name, track_id, player_id, position, race_time, points_earned) 
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ]], {
                    raceId, trackName, trackId, tonumber(citizenId), position, raceTime, points
                })
                
                if insertResult then
                    print('DEBUG: Race result saved successfully')
                else
                    print('ERROR: Failed to save race result')
                end
            else
                print('DEBUG: race_results table does not exist, skipping race result save')
            end
            
            -- Update track record if this is the best time
            if trackId ~= "UNKNOWN" then
                -- Check if race_records table exists
                local recordsTableExists = exports.oxmysql:executeSync([[
                    SELECT COUNT(*) as count 
                    FROM information_schema.tables 
                    WHERE table_schema = DATABASE() 
                    AND table_name = 'race_records'
                ]])
                
                if recordsTableExists and recordsTableExists[1] and recordsTableExists[1].count > 0 then
                    local existingRecord = exports.oxmysql:executeSync(
                        'SELECT best_time FROM race_records WHERE track_id = ? AND player_id = ? ORDER BY best_time ASC LIMIT 1',
                        {trackId, citizenId}
                    )
                    
                    local isNewRecord = true
                    if existingRecord and existingRecord[1] and existingRecord[1].best_time <= raceTime then
                        isNewRecord = false
                    end
                    
                    if isNewRecord then
                        local recordResult = exports.oxmysql:execute([[
                            INSERT INTO race_records (track_id, player_id, best_time) 
                            VALUES (?, ?, ?)
                            ON DUPLICATE KEY UPDATE best_time = VALUES(best_time)
                        ]], {trackId, citizenId, raceTime})
                        
                        if recordResult then
                            print('DEBUG: Track record updated successfully')
                        else
                            print('ERROR: Failed to update track record')
                        end
                    else
                        print('DEBUG: Not a new record, skipping track record update')
                    end
                else
                    print('DEBUG: race_records table does not exist, skipping track record update')
                end
            end
            
            -- Send notification to player
            print('DEBUG: Sending notification to player:', src, 'Message: Corrida finalizada! Posição:', position, 'Pontos:', points)
            sendNotification(src, string.format('Corrida finalizada! Posição: %d/%d | Pontos: +%d', position, totalRacers, points), 'sucesso')
        end

        for _, racer in pairs(Races[raceId].Racers) do
            if GetPlayerName(racer.RacerSource) then 
                TriggerClientEvent('cw-racingapp:client:updateRaceRacerData', racer.RacerSource, raceId, citizenId,
                    Races[raceId].Racers[citizenId])
            else
                if UseDebug then 
                    print('^1Could not find player with source^0', racer.RacerSource)
                    print(json.encode(racer, {indent=true})) 
                end
            end
        end
    else
        -- Attemt to make sure script dont break if something goes wrong
        sendNotification(src, "Você não está na corrida", 'error')
        TriggerClientEvent('cw-racingapp:client:leaveRace', -1, nil)
        leftRace(src)
    end
    if Config.UseResetTimer then updateTimer(raceId) end
end)

RegisterNetEvent('cw-racingapp:server:startRace', function(raceId)
    if UseDebug then print(source, 'is starting race', raceId) end
    local src = source
    local AvailableKey = GetOpenedRaceKey(raceId)

    if not raceId then
        if src then sendNotification(src, "Você não está em uma corrida", 'error') end
        return
    end

    if not AvailableRaces[AvailableKey] then
        if UseDebug then print('Could not find available race', raceId) end
        return
    end

    if not AvailableRaces[AvailableKey].RaceData then
        if UseDebug then print('Could not find available race data', raceId) end
        return
    end
    if AvailableRaces[AvailableKey].RaceData.Started then
        if UseDebug then print('Race was already started', raceId) end
        if src then TriggerClientEvent('cw-racingapp:client:notify', src, Lang("race_already_started"), 'error') end
        return
    end

    AvailableRaces[AvailableKey].RaceData.Started = true
    AvailableRaces[AvailableKey].RaceData.Waiting = false
    local TotalRacers = 0
    for _, _ in pairs(Races[raceId].Racers) do
        TotalRacers = TotalRacers + 1
    end
    if UseDebug then print('Total Racers', TotalRacers) end
    for _, racer in pairs(Races[raceId].Racers) do
        TriggerClientEvent('cw-racingapp:client:raceCountdown', racer.RacerSource, TotalRacers)
        setInRace(racer.RacerSource, raceId)
    end
    if Config.UseResetTimer then startTimer(raceId) end
end)

RegisterNetEvent('cw-racingapp:server:saveTrack', function(trackData)
    local src = source
    local citizenId = getCitizenId(src)
    local trackId
    if trackData.TrackId ~= nil then
        trackId = trackData.TrackId
    else
        trackId = GenerateTrackId()
    end
    local checkpoints = {}
    for k, v in pairs(trackData.Checkpoints) do
        checkpoints[k] = {
            offset = v.offset,
            coords = v.coords
        }
    end

    if trackData.IsEdit then
        print('Saving over previous track', trackData.TrackId)
        RADB.setTrackCheckpoints(checkpoints, trackData.TrackId)
        Tracks[trackId].Checkpoints = checkpoints
    else
        Tracks[trackId] = {
            RaceName = trackData.RaceName,
            Checkpoints = checkpoints,
            Creator = citizenId,
            CreatorName = trackData.RacerName,
            TrackId = trackId,
            Started = false,
            Waiting = false,
            Distance = math.ceil(trackData.RaceDistance),
            Racers = {},
            Metadata = DeepCopy(DefaultTrackMetadata),
            Access = {},
            LastLeaderboard = {},
            NumStarted = 0,
        }
        RADB.createTrack(trackData, checkpoints, citizenId, trackId)
    end
end)

RegisterNetEvent('cw-racingapp:server:deleteTrack', function(trackId)
    RADB.deleteTrack(trackId)
    Tracks[trackId] = nil
end)

RegisterNetEvent('cw-racingapp:server:removeRecord', function(record)
    if UseDebug then print('Removing record', json.encode(record, { indent = true })) end
    RESDB.removeTrackRecord(record.id)
end)

RegisterNetEvent('cw-racingapp:server:clearLeaderboard', function(trackId)
    RESDB.clearTrackRecords(trackId)
end)

RegisterServerCallback('cw-racingapp:server:getRaceResults', function(source, amount)
    local limit = amount or 10
    local result = RESDB.getRecentRaces(limit)
    for i, track in ipairs(result) do
        result[i].raceName = Tracks[track.trackId].RaceName
    end
    return result
end)

RegisterServerCallback('cw-racingapp:server:getAllRacers', function(source)
    if UseDebug then print('Fetching all racers') end
    local allRacers = RADB.getAllRacerNames()
    if UseDebug then print("^2Result", json.encode(allRacers)) end
    return allRacers
end)

RegisterServerCallback('cw-racingapp:server:isFirstUser', function(source)
    if UseDebug then print('Is first user:', IsFirstUser) end
    return IsFirstUser
end)

-----------------------
----   Functions   ----
-----------------------

function MilliToTime(milli)
    local milliseconds = milli % 1000;
    milliseconds = tostring(milliseconds)
    local seconds = math.floor((milli / 1000) % 60);
    local minutes = math.floor((milli / (60 * 1000)) % 60);
    if minutes < 10 then
        minutes = "0" .. tostring(minutes);
    else
        minutes = tostring(minutes)
    end
    if seconds < 10 then
        seconds = "0" .. tostring(seconds);
    else
        seconds = tostring(seconds)
    end
    return minutes .. ":" .. seconds .. "." .. milliseconds;
end

function IsPermissioned(racerName, type)
    local auth = RADB.getUserAuth(racerName)
    if not auth then
        if UseDebug then print('Could not find user with this racer Name', racerName) end
        return false
    end
    if UseDebug then print(racerName, 'has auth', auth) end
    return Config.Permissions[auth][type]
end

function IsNameAvailable(trackname)
    local retval = true
    for trackId, _ in pairs(Tracks) do
        if Tracks[trackId].RaceName == trackname then
            retval = false
            break
        end
    end
    return retval
end

function GetOpenedRaceKey(raceId)
    local retval = nil
    for k, v in pairs(AvailableRaces) do
        if v.RaceId == raceId then
            retval = k
            break
        end
    end
    return retval
end

function GetCurrentRace(citizenId)
    for raceId, race in pairs(Races) do
        for cid, _ in pairs(race.Racers) do
            if cid == citizenId then
                return raceId
            end
        end
    end
end

function GetRaceId(name)
    for k, v in pairs(Tracks) do
        if v.RaceName == name then
            return k
        end
    end
    return nil
end

function GenerateTrackId()
    local trackId = "LR-" .. math.random(1000, 9999)
    while Tracks[trackId] ~= nil do
        trackId = "LR-" .. math.random(1000, 9999)
    end
    return trackId
end

function GenerateRaceId()
    local raceId = "RI-" .. math.random(100000, 999999)
    while Races[raceId] ~= nil do
        raceId = "RI-" .. math.random(100000, 999999)
    end
    return raceId
end

function openRacingApp(source)
    TriggerClientEvent('cw-racingapp:client:openRacingApp', source)
end

exports('openRacingApp', openRacingApp)

-- Make function global for bridge access
_G.openRacingApp = openRacingApp

-- Get race data for teleport
RegisterServerCallback('cw-racingapp:server:getRaceData', function(source, raceId)
    local src = source
    print('DEBUG: Getting race data for teleport:', raceId)
    
    -- Check if race exists in Races table
    if Races[raceId] then
        local race = Races[raceId]
        print('DEBUG: Found race in Races table')
        
        -- Get track data from AvailableRaces
        for _, availableRace in pairs(AvailableRaces) do
            if availableRace.RaceId == raceId then
                print('DEBUG: Found race in AvailableRaces, returning data')
                return {
                    Checkpoints = availableRace.Checkpoints,
                    Laps = race.Laps or 0,
                    RaceName = race.RaceName
                }
            end
        end
    end
    
    print('DEBUG: No race data found')
    return nil
end)

-- Helper function to get crew name from citizen ID
local function getCrewNameFromCitizenId(citizenId)
    local crewData = exports.oxmysql:executeSync('SELECT crew_name FROM characters WHERE id = ?', {tonumber(citizenId)})
    if crewData and crewData[1] and crewData[1].crew_name then
        return crewData[1].crew_name
    end
    return nil
end

-- Load all crews on server start
local function loadAllCrews()
    print('DEBUG: Loading all crews from database...')
    local crews = exports.oxmysql:executeSync('SELECT DISTINCT crew_name FROM characters WHERE crew_name IS NOT NULL', {})
    
    if crews then
        print('DEBUG: Found', #crews, 'crews in database')
        for _, crew in ipairs(crews) do
            print('DEBUG: Loaded crew:', crew.crew_name)
        end
    else
        print('DEBUG: No crews found in database')
    end
end

-- Load crews when server starts
CreateThread(function()
    Wait(5000) -- Wait for MySQL to be ready
    loadAllCrews()
end)

-- Crew management functions
RegisterServerCallback('cw-racingapp:server:createCrew', function(source, crewName)
    local src = source
    local citizenId = getCitizenId(src)
    print('DEBUG: Creating crew:', crewName, 'for player:', citizenId)
    
    -- Check if player already has a crew
    local existingCrew = exports.oxmysql:executeSync('SELECT crew_name FROM characters WHERE id = ?', {tonumber(citizenId)})
    if existingCrew and existingCrew[1] and existingCrew[1].crew_name then
        sendNotification(src, 'Você já está em uma crew!', 'error')
        return false
    end
    
    -- Check if crew name already exists
    local crewExists = exports.oxmysql:executeSync('SELECT id FROM characters WHERE crew_name = ?', {crewName})
    if crewExists and #crewExists > 0 then
        sendNotification(src, 'Nome da crew já existe!', 'error')
        return false
    end
    
    -- Create crew
    local result = exports.oxmysql:execute('UPDATE characters SET crew_name = ? WHERE id = ?', {crewName, tonumber(citizenId)})
    if result then
        sendNotification(src, 'Crew "' .. crewName .. '" criada com sucesso!', 'sucesso')
        return true
    else
        sendNotification(src, 'Erro ao criar crew!', 'error')
        return false
    end
end)


RegisterServerCallback('cw-racingapp:server:getCrewData', function(source, crewName)
    local src = source
    print('DEBUG: Getting crew data for:', crewName)
    
    local members = exports.oxmysql:executeSync('SELECT name, RacePoints, RaceWins, RaceParticipations FROM characters WHERE crew_name = ? ORDER BY RacePoints DESC', {crewName})
    
    local memberList = {}
    if members then
        for _, member in ipairs(members) do
            table.insert(memberList, {
                name = member.name,
                points = member.RacePoints or 0,
                wins = member.RaceWins or 0,
                participations = member.RaceParticipations or 0
            })
        end
    end
    
    return memberList
end)

-- Dashboard data functions
RegisterServerCallback('cw-racingapp:server:getDashboardData', function(source)
    local src = source
    print('DEBUG: Getting dashboard data')
    
    local dashboardData = {
        mostUsedTracks = {},
        rankedVsUnranked = {ranked = 0, unranked = 0},
        mostUsedClasses = {},
        bestAndAverageTimes = {}
    }
    
    -- Get most used tracks
    local trackUsage = exports.oxmysql:executeSync([[
        SELECT track_name, COUNT(*) as usage_count 
        FROM race_results 
        WHERE track_name IS NOT NULL 
        GROUP BY track_name 
        ORDER BY usage_count DESC 
        LIMIT 5
    ]])
    
    if trackUsage then
        for _, track in ipairs(trackUsage) do
            table.insert(dashboardData.mostUsedTracks, {
                name = track.track_name,
                count = track.usage_count
            })
        end
    end
    
    -- Get ranked vs unranked races (simplified - we'll assume all races are ranked for now)
    dashboardData.rankedVsUnranked = {ranked = 100, unranked = 0}
    
    -- Get class usage (simplified - mostly "no class limit")
    dashboardData.mostUsedClasses = {
        {name = "Sem limite de classe", percentage = 80},
        {name = "X", percentage = 10},
        {name = "S", percentage = 5},
        {name = "A", percentage = 3},
        {name = "B", percentage = 2}
    }
    
    -- Get best and average times (simplified data)
    dashboardData.bestAndAverageTimes = {
        {time = "1:23.45", type = "best"},
        {time = "1:45.67", type = "average"}
    }
    
    return dashboardData
end)

-- Get available tracks for recent races and track records
RegisterServerCallback('cw-racingapp:server:getAvailableTracks', function(source)
    local src = source
    print('DEBUG: Getting available tracks')
    
    local tracks = {}
    
    -- Get tracks from race_results
    local trackData = exports.oxmysql:executeSync([[
        SELECT DISTINCT track_name, track_id 
        FROM race_results 
        WHERE track_name IS NOT NULL 
        ORDER BY track_name
    ]])
    
    if trackData then
        for _, track in ipairs(trackData) do
            table.insert(tracks, {
                name = track.track_name,
                id = track.track_id
            })
        end
    end
    
    -- If no tracks from race_results, add some default tracks
    if #tracks == 0 then
        tracks = {
            {name = "Elysian", id = "CW-7666"},
            {name = "Cop Blocked", id = "CW-3232"},
            {name = "Oil Fields", id = "CW-1234"},
            {name = "Devils Touge", id = "CW-5678"},
            {name = "Zancudo Petrol Station", id = "CW-9012"}
        }
    end
    
    return tracks
end)



-- Simple command to check admin status
RegisterCommand("racingstatus", function(source, args)
    local src = source
    local citizenId = getCitizenId(src)
    
    local isAdmin = false
    if vRP and vRP.HasGroup then
        isAdmin = vRP.HasGroup(citizenId, "Admin")
    elseif vRP and vRP.HasPermission then
        isAdmin = vRP.HasPermission(citizenId, "admin.permissao")
    end
    
    local status = isAdmin and "ADMIN" or "USER"
    local color = isAdmin and {0, 255, 0} or {255, 255, 0}
    
    if src ~= 0 then
        TriggerClientEvent('Notify', src, "RACING", "Status: " .. status, isAdmin and "verde" or "amarelo", 5000)
    end
    
    print('DEBUG: Player status check - Source:', src, 'Admin:', isAdmin)
end, false)

-- Test command to check all functions
RegisterCommand("racingtest", function(source, args)
    local src = source
    TriggerClientEvent('Notify', src, "TESTE", "Sistema de corridas funcionando!", "verde", 3000)
end, false)


-- Command to refresh admin status
RegisterCommand("racingrefresh", function(source, args)
    local src = source
    print('DEBUG: Refreshing admin status for player:', src)
    TriggerEvent('cw-racingapp:server:updateAdminStatus', src)
    TriggerClientEvent('Notify', src, "RACING", "Status de admin atualizado! Feche e abra o tablet.", "verde", 5000)
end, false)

-- Comando para definir GOD
RegisterCommand("setgod", function(source, args)
    local src = source
    print('DEBUG: setgod command called, source:', src)
    
    if src == 0 then
        print('DEBUG: Command called from console, setting ID 1 as GOD')
        -- Atualizar no banco de dados
        exports.oxmysql:execute('UPDATE characters SET racing_auth = ? WHERE id = ?', {'god', 1})
        exports.oxmysql:execute('UPDATE race_users SET auth = ? WHERE citizenid = ?', {'god', 1})
        print('DEBUG: Player ID 1 set as GOD from console')
        return
    end
    
    local citizenId = getCitizenId(src)
    print('DEBUG: Citizen ID:', citizenId)
    
    if citizenId == 1 then
        -- Atualizar no banco de dados
        exports.oxmysql:execute('UPDATE characters SET racing_auth = ? WHERE id = ?', {'god', 1})
        exports.oxmysql:execute('UPDATE race_users SET auth = ? WHERE citizenid = ?', {'god', 1})
        
        -- Atualizar na memória
        TriggerEvent('cw-racingapp:server:updateAdminStatus', src)
        
        if src and src > 0 then
            TriggerClientEvent('Notify', src, "RACING", "🏆 Você foi definido como GOD! Reinicie o tablet.", "amarelo", 5000)
        end
        
        print('DEBUG: Player', citizenId, 'set as GOD')
    else
        if src and src > 0 then
            TriggerClientEvent('Notify', src, "RACING", "❌ Apenas o ID 1 pode usar este comando!", "vermelho", 5000)
        end
    end
end, false)

-- Update player admin status
RegisterServerEvent('cw-racingapp:server:updateAdminStatus', function()
    local src = source
    local citizenId = getCitizenId(src)
    
    local isAdmin = false
    if vRP and vRP.HasGroup then
        isAdmin = vRP.HasGroup(citizenId, "Admin")
    elseif vRP and vRP.HasPermission then
        isAdmin = vRP.HasPermission(citizenId, "admin.permissao")
    end
    
    local authLevel = isAdmin and "admin" or "user"
    
    -- Update the racer data with new admin status
    local result = exports.oxmysql:executeSync('SELECT * FROM characters WHERE id = ?', {citizenId})
    if result and result[1] then
        local playerData = result[1]
        local playerName = playerData.name or playerData.nome or playerData.character_name or GetPlayerName(src) or "Player"
        
        local racerData = {
            {
                racername = playerName,
                auth = authLevel,
                active = 1,
                ranking = 0,
                crypto = 0,
                crew = playerData.crew_name or ""
            }
        }
        
        TriggerClientEvent('cw-racingapp:client:updateRacerData', src, racerData)
        print('DEBUG: Updated admin status for player:', playerName, 'to:', authLevel)
    end
end)

RegisterServerCallback('cw-racingapp:server:cancelRace', function(source, raceId)
    local src = source
    if UseDebug then
        print('Player is canceling race', src, raceId)
    end
    if not raceId or not Races[raceId] then return false end

    for _, racer in pairs(Races[raceId].Racers) do
        TriggerClientEvent('cw-racingapp:client:notify', racer.RacerSource, Lang("race_canceled"),
            'error')
        TriggerClientEvent('cw-racingapp:client:leaveRace', racer.RacerSource, Races[raceId])
        leftRace(racer.RacerSource)
    end
    Wait(500)
    local availableKey = GetOpenedRaceKey(raceId)
    if UseDebug then print('Available Key', availableKey) end
    table.remove(AvailableRaces, availableKey)
    resetTrack(raceId, 'Manually canceled by src ' .. tostring(src or 'UNKNOWN'))
    return true
end)


RegisterServerCallback('cw-racingapp:server:getAvailableRaces', function(source)
    return AvailableRaces
end)

RegisterServerCallback('cw-racingapp:server:getRaceRecordsForTrack', function(source, trackId)
    return RESDB.getAllBestTimesForTrack(trackId)
end)

RegisterServerCallback('cw-racingapp:server:getTracks', function(source)
    print('DEBUG: Getting tracks, count:', #Tracks)
    return Tracks
end)

RegisterServerCallback('cw-racingapp:server:getTracksTrimmed', function(source)
    local tracksWithoutCheckpoints = DeepCopy(Tracks)
    for i, track in pairs(tracksWithoutCheckpoints) do
        tracksWithoutCheckpoints[i] = track
        tracksWithoutCheckpoints[i].Checkpoints = nil
    end
    return tracksWithoutCheckpoints
end)

local function getTracks()
    return Tracks    
end exports('getTracks', getTracks)

local function getRaces()
    return Races
end exports('getRaces', getRaces)

RegisterServerCallback('cw-racingapp:server:getRaces', function(source)
    return Races
end)

RegisterServerCallback('cw-racingapp:server:getTrackData', function(source, trackId)
    return Tracks[trackId] or false
end)

RegisterServerCallback('cw-racingapp:server:getAccess', function(source, trackId)
    local track = Tracks[trackId]
    return track.Access or 'NOTHING'
end)

RegisterNetEvent('cw-racingapp:server:setAccess', function(trackId, access)
    local src = source
    if UseDebug then
        print('source ', src, 'has updated access for', trackId)
        print(json.encode(access))
    end
    local res = RADB.setAccessForTrack(access, trackId)
    if res then
        if res == 1 then
            TriggerClientEvent('cw-racingapp:client:notify', src, Lang("access_updated"), "success")
        end
        Tracks[trackId].Access = access
    end
end)

RegisterServerCallback('cw-racingapp:server:isAuthorizedToCreateRaces', function(source, trackName, racerName)
    return { permissioned = IsPermissioned(racerName, 'create'), nameAvailable = IsNameAvailable(trackName) }
end)


local function nameIsValid(racerName, citizenId)
    local result = RADB.getRaceUserByName(racerName)
    if result then
        if result.citizenid == citizenId then
            return true
        end
        return false
    else
        return true
    end
end

local function addRacerName(citizenId, racerName, targetSource, auth, creatorCitizenId)
    if not RADB.getRaceUserByName(racerName) then
        IsFirstUser = false
        RADB.createRaceUser(citizenId, racerName, auth, creatorCitizenId)
        Wait(500)
        TriggerClientEvent('cw-racingapp:client:updateRacerNames', tonumber(targetSource))
    end
end

RegisterServerCallback('cw-racingapp:server:getAmountOfTracks', function(source, citizenId)
    if Config.UseNameValidation then
        local tracks = RADB.getTracksByCitizenId(citizenId)
        return #tracks
    else
        return 0
    end
end)

RegisterServerCallback('cw-racingapp:server:nameIsAvailable', function(source, racerName, serverId)
    if UseDebug then
        print('checking availability for',
            json.encode({ racerName = racerName, sererId = serverId }, { indent = true }))
    end
    if Config.UseNameValidation then
        local citizenId = getCitizenId(serverId)
        if nameIsValid(racerName, citizenId) then
            return true
        else
            return false
        end
    else
        return true
    end
end)

local function getActiveRacerName(raceUsers)
    if raceUsers then
        for _, user in pairs(raceUsers) do
            if user.active then return user end
        end
    end
end

RegisterServerCallback('cw-racingapp:server:getRacerNamesByPlayer', function(source, serverId)
    local playerSource = serverId or source

    if UseDebug then print('Getting racer names for serverid', playerSource) end

    local citizenId = getCitizenId(playerSource)
    if UseDebug then print('Racer citizenid', citizenId) end

    -- Get player data from VRP characters table
    local result = exports.oxmysql:executeSync('SELECT * FROM characters WHERE id = ?', {citizenId})
    
    if result and result[1] then
        local playerData = result[1]
        
        -- Try different name fields
        local playerName = playerData.name or playerData.nome or playerData.character_name or GetPlayerName(playerSource) or "Player"
        
        -- Check if player is admin - check GOD status first, then VRP groups
        local isAdmin = false
        local authLevel = "user"
        
        -- Check if player is GOD in database
        local authResult = exports.oxmysql:executeSync('SELECT racing_auth FROM characters WHERE id = ?', {citizenId})
        if authResult and authResult[1] and authResult[1].racing_auth == 'god' then
            isAdmin = true
            authLevel = "god"
        elseif authResult and authResult[1] and authResult[1].racing_auth == 'admin' then
            isAdmin = true
            authLevel = "admin"
        -- Check if player is in Admin group
        elseif vRP and vRP.HasGroup then
            isAdmin = vRP.HasGroup(citizenId, "Admin")
            if isAdmin then authLevel = "admin" end
        elseif vRP and vRP.HasPermission then
            isAdmin = vRP.HasPermission(citizenId, "admin.permissao")
            if isAdmin then authLevel = "admin" end
        end
        
        print('DEBUG: Player admin status:', isAdmin, 'auth level:', authLevel, 'for player:', playerName)
        
        local racerData = {
            {
                racername = playerName,
                auth = authLevel,
                active = 1,
                ranking = playerData.RacePoints or 0,
                crypto = 0,
                crew = nil,
                revoked = 0
            }
        }
        
        if UseDebug then print('Racer Names found:', json.encode(racerData)) end
        return racerData
    else
        -- Fallback to original system if VRP data not found
        local result = RADB.getRaceUsersBelongingToCitizenId(citizenId)
        if UseDebug then print('Racer Names found (fallback):', json.encode(result)) end
        return result
    end
end)

-- Crew system functions

RegisterServerCallback('cw-racingapp:server:joinCrew', function(source, racerName, citizenId, crewName)
    local src = source
    print('DEBUG: Joining crew:', crewName, 'for player:', citizenId)
    
    -- Check if crew exists
    local crewExists = exports.oxmysql:executeSync('SELECT * FROM characters WHERE crew_name = ?', {crewName})
    if not crewExists or #crewExists == 0 then
        print('DEBUG: Crew does not exist:', crewName)
        return false
    end
    
    -- Join crew
    local result = exports.oxmysql:executeSync('UPDATE characters SET crew_name = ? WHERE id = ?', {crewName, citizenId})
    
    if result and result.affectedRows > 0 then
        print('DEBUG: Joined crew successfully:', crewName)
        return true
    else
        print('DEBUG: Failed to join crew:', crewName)
        return false
    end
end)

RegisterServerCallback('cw-racingapp:server:leaveCrew', function(source, racerName, citizenId, crewName)
    local src = source
    print('DEBUG: Leaving crew:', crewName, 'for player:', citizenId)
    
    -- Leave crew by setting crew_name to NULL
    local result = exports.oxmysql:executeSync('UPDATE characters SET crew_name = NULL WHERE id = ?', {citizenId})
    
    if result and result.affectedRows > 0 then
        print('DEBUG: Left crew successfully:', crewName)
        return true
    else
        print('DEBUG: Failed to leave crew:', crewName)
        return false
    end
end)

RegisterServerCallback('cw-racingapp:server:disbandCrew', function(source, citizenId, crewName)
    local src = source
    print('DEBUG: Disbanding crew:', crewName, 'by player:', citizenId)
    
    -- Check if player is the crew owner (first member)
    local crewOwner = exports.oxmysql:executeSync('SELECT * FROM characters WHERE crew_name = ? ORDER BY id ASC LIMIT 1', {crewName})
    if crewOwner and crewOwner[1] and crewOwner[1].id == citizenId then
        -- Remove all crew members
        local result = exports.oxmysql:executeSync('UPDATE characters SET crew_name = NULL WHERE crew_name = ?', {crewName})
        
        if result and result.affectedRows > 0 then
            print('DEBUG: Crew disbanded successfully:', crewName)
            return true
        else
            print('DEBUG: Failed to disband crew:', crewName)
            return false
        end
    else
        print('DEBUG: Player is not crew owner:', citizenId)
        return false
    end
end)

RegisterServerCallback('cw-racingapp:server:getAllCrews', function(source)
    local src = source
    print('DEBUG: Getting all crews')
    
    -- Get crews from racing_crews table
    local crews = exports.oxmysql:executeSync('SELECT * FROM racing_crews ORDER BY rank DESC', {})
    
    local crewList = {}
    if crews then
        for _, crew in ipairs(crews) do
            -- Count members from JSON
            local memberCount = 0
            if crew.members and crew.members ~= '[]' then
                local success, members = pcall(json.decode, crew.members)
                if success and members then
                    memberCount = #members
                end
            end
            
            table.insert(crewList, {
                name = crew.crew_name,
                memberCount = memberCount,
                totalPoints = crew.rank or 0,
                totalWins = crew.wins or 0,
                totalRaces = crew.races or 0
            })
        end
    end
    
    print('DEBUG: Found crews:', json.encode(crewList))
    return crewList
end)

RegisterServerCallback('cw-racingapp:server:getCrewData', function(source, citizenId, crewName)
    local src = source
    print('DEBUG: Getting crew data for:', crewName)
    
    -- Get crew from racing_crews table
    local crewData = exports.oxmysql:executeSync('SELECT * FROM racing_crews WHERE crew_name = ?', {crewName})
    
    if crewData and #crewData > 0 then
        local crew = crewData[1]
        local crewInfo = {
            name = crew.crew_name,
            founderName = crew.founder_name,
            wins = crew.wins or 0,
            races = crew.races or 0,
            rank = crew.rank or 0,
            members = {}
        }
        
        -- Parse members from JSON
        if crew.members and crew.members ~= '[]' then
            local success, members = pcall(json.decode, crew.members)
            if success and members then
                for _, member in ipairs(members) do
                    table.insert(crewInfo.members, {
                        name = member.racername,
                        points = 0, -- Not stored in racing_crews
                        wins = 0,   -- Not stored in racing_crews
                        participations = 0, -- Not stored in racing_crews
                        isOwner = tostring(member.citizenID) == tostring(citizenId)
                    })
                end
            end
        end
        
        print('DEBUG: Crew data:', json.encode(crewInfo))
        return crewInfo
    else
        print('DEBUG: Crew not found:', crewName)
        return nil
    end
end)

-- Get current player's crew
RegisterServerCallback('cw-racingapp:server:getMyCrew', function(source)
    local src = source
    local citizenId = getCitizenId(src)
    print('DEBUG: Getting my crew for citizenId:', citizenId)
    
    -- Get all crews and find which one the player belongs to
    local crews = exports.oxmysql:executeSync('SELECT * FROM racing_crews', {})
    
    if crews then
        for _, crew in ipairs(crews) do
            if crew.members and crew.members ~= '[]' then
                local success, members = pcall(json.decode, crew.members)
                if success and members then
                    for _, member in ipairs(members) do
                        if tostring(member.citizenID) == tostring(citizenId) then
                            print('DEBUG: Player is in crew:', crew.crew_name)
                            
                            local myCrewData = {
                                name = crew.crew_name,
                                founderName = crew.founder_name,
                                wins = crew.wins or 0,
                                races = crew.races or 0,
                                rank = crew.rank or 0,
                                members = {}
                            }
                            
                            -- Add all members
                            for _, mem in ipairs(members) do
                                table.insert(myCrewData.members, {
                                    name = mem.racername,
                                    points = 0, -- Not stored in racing_crews
                                    wins = 0,   -- Not stored in racing_crews
                                    participations = 0, -- Not stored in racing_crews
                                    isOwner = tostring(mem.citizenID) == tostring(citizenId)
                                })
                            end
                            
                            print('DEBUG: My crew data:', json.encode(myCrewData))
                            return { crew = myCrewData }
                        end
                    end
                end
            end
        end
    end
    
    print('DEBUG: Player is not in any crew')
    return { crew = nil }
end)

-- Debug command to check crew statistics
RegisterCommand('checkcrewstats', function(source, args)
    local crewName = args[1]
    if not crewName then
        print('Usage: /checkcrewstats [crew_name]')
        return
    end
    
    -- Check in racing_crews table first
    local crewData = exports.oxmysql:executeSync('SELECT * FROM racing_crews WHERE crew_name = ?', {crewName})
    
    if crewData and #crewData > 0 then
        local crew = crewData[1]
        print('=== Crew Statistics for:', crewName, '===')
        print('Founder:', crew.founder_name)
        print('Wins:', crew.wins or 0)
        print('Races:', crew.races or 0)
        print('Rank:', crew.rank or 0)
        print('Created:', crew.created_at)
        
        -- Parse members from JSON
        if crew.members and crew.members ~= '[]' then
            local success, members = pcall(json.decode, crew.members)
            if success and members then
                print('Members:')
                for _, member in ipairs(members) do
                    print('-', member.racername, 'CitizenID:', member.citizenID, 'Rank:', member.rank)
                end
            end
        else
            print('No members found')
        end
    else
        -- Fallback: check in characters table
        local fallbackData = exports.oxmysql:executeSync('SELECT name, RacePoints, RaceWins, RaceParticipations FROM characters WHERE crew_name = ? ORDER BY RacePoints DESC', {crewName})
        
        if fallbackData and #fallbackData > 0 then
            print('=== Crew Statistics for:', crewName, '(from characters table) ===')
            local totalWins = 0
            local totalRaces = 0
            local totalPoints = 0
            
            for _, member in ipairs(fallbackData) do
                print('Member:', member.name, 'Points:', member.RacePoints, 'Wins:', member.RaceWins, 'Races:', member.RaceParticipations)
                totalWins = totalWins + (member.RaceWins or 0)
                totalRaces = totalRaces + (member.RaceParticipations or 0)
                totalPoints = totalPoints + (member.RacePoints or 0)
            end
            
            print('Total Crew Stats - Points:', totalPoints, 'Wins:', totalWins, 'Races:', totalRaces)
        else
            print('Crew not found:', crewName)
        end
    end
end, true)

-- Debug command to check if player is in a crew
RegisterCommand('checkmycrew', function(source, args)
    local src = source
    local citizenId = getCitizenId(src)
    local playerName = GetPlayerName(src) or "Unknown"
    
    print('=== Checking crew for player:', playerName, 'citizenId:', citizenId, '===')
    
    -- First check in racing_crews table
    local crews = exports.oxmysql:executeSync('SELECT * FROM racing_crews', {})
    local foundCrew = nil
    
    if crews then
        for _, crew in ipairs(crews) do
            if crew.members and crew.members ~= '[]' then
                local success, members = pcall(json.decode, crew.members)
                if success and members then
                    for _, member in ipairs(members) do
                        if tostring(member.citizenID) == tostring(citizenId) then
                            foundCrew = crew
                            break
                        end
                    end
                end
            end
        end
    end
    
    if foundCrew then
        print('Player is in crew:', foundCrew.crew_name)
        print('Founder:', foundCrew.founder_name)
        print('Wins:', foundCrew.wins or 0)
        print('Races:', foundCrew.races or 0)
        print('Rank:', foundCrew.rank or 0)
        
        -- Show members
        if foundCrew.members and foundCrew.members ~= '[]' then
            local success, members = pcall(json.decode, foundCrew.members)
            if success and members then
                print('Crew members:')
                for _, member in ipairs(members) do
                    print('-', member.racername, 'CitizenID:', member.citizenID, 'Rank:', member.rank)
                end
            end
        end
    else
        -- Fallback: check in characters table
        local crewData = exports.oxmysql:executeSync('SELECT crew_name FROM characters WHERE id = ?', {tonumber(citizenId)})
        
        if crewData and crewData[1] and crewData[1].crew_name then
            local crewName = crewData[1].crew_name
            print('Player is in crew (from characters table):', crewName)
            
            -- Get crew members
            local members = exports.oxmysql:executeSync('SELECT name, RacePoints, RaceWins, RaceParticipations FROM characters WHERE crew_name = ? ORDER BY RacePoints DESC', {crewName})
            
            if members then
                print('Crew members:')
                for _, member in ipairs(members) do
                    print('-', member.name, 'Points:', member.RacePoints, 'Wins:', member.RaceWins, 'Races:', member.RaceParticipations)
                end
            end
        else
            print('Player is NOT in any crew')
        end
    end
end, true)

-- Get all racers for ranking
RegisterServerCallback('cw-racingapp:server:getAllRacers', function(source)
    local src = source
    
    -- Get top racers by points
    local racers = exports.oxmysql:executeSync([[
        SELECT name, RacePoints, RaceWins, RaceParticipations 
        FROM characters 
        WHERE RacePoints > 0 OR RaceWins > 0 OR RaceParticipations > 0
        ORDER BY RacePoints DESC, RaceWins DESC 
        LIMIT 50
    ]])
    
    local racerList = {}
    if racers and #racers > 0 then
        for i, racer in ipairs(racers) do
            local playerName = racer.name or "Player"
            table.insert(racerList, {
                racername = playerName,
                ranking = racer.RacePoints or 0,
                wins = racer.RaceWins or 0,
                races = racer.RaceParticipations or 0,
                tracks = 0,
                citizenid = tostring(i),
                auth = "user",
                id = i,
                lasttouched = 0,
                revoked = 0,
                crew = nil
            })
        end
    else
        -- Return empty list with a message
        table.insert(racerList, {
            racername = "Nenhum piloto encontrado",
            ranking = 0,
            wins = 0,
            races = 0,
            tracks = 0,
            citizenid = "0",
            auth = "user",
            id = 1,
            lasttouched = 0,
            revoked = 0,
            crew = nil
        })
    end
    
    return racerList
end)

-- Get race records for a specific track
RegisterServerCallback('cw-racingapp:server:getRaceRecordsForTrack', function(source, trackId)
    local src = source
    print('DEBUG: Getting race records for track:', trackId)
    
    -- Check if race_records table exists
    local tableExists = exports.oxmysql:executeSync([[
        SELECT COUNT(*) as count 
        FROM information_schema.tables 
        WHERE table_schema = DATABASE() 
        AND table_name = 'race_records'
    ]])
    
    if not tableExists or not tableExists[1] or tableExists[1].count == 0 then
        print('DEBUG: race_records table does not exist, returning empty list')
        return {}
    end
    
    -- Get race records from the database
    local records = exports.oxmysql:executeSync([[
        SELECT r.*, c.name 
        FROM race_records r 
        JOIN characters c ON r.player_id = c.id 
        WHERE r.track_id = ? 
        ORDER BY r.best_time ASC 
        LIMIT 10
    ]], {trackId})
    
    local recordList = {}
    if records then
        for i, record in ipairs(records) do
            local playerName = record.name or "Player"
            table.insert(recordList, {
                position = i,
                playerName = playerName,
                bestTime = record.best_time,
                date = record.created_at
            })
        end
    end
    
    print('DEBUG: Found records:', json.encode(recordList))
    return recordList
end)

-- Get recent race results
RegisterServerCallback('cw-racingapp:server:getRaceResults', function(source)
    local src = source
    print('DEBUG: Getting recent race results')
    
    -- Check if race_results table exists
    local tableExists = exports.oxmysql:executeSync([[
        SELECT COUNT(*) as count 
        FROM information_schema.tables 
        WHERE table_schema = DATABASE() 
        AND table_name = 'race_results'
    ]])
    
    if not tableExists or not tableExists[1] or tableExists[1].count == 0 then
        print('DEBUG: race_results table does not exist, returning empty list')
        return {}
    end
    
    -- Get recent race results
    local results = exports.oxmysql:executeSync([[
        SELECT r.*, c.name 
        FROM race_results r 
        JOIN characters c ON r.player_id = c.id 
        ORDER BY r.created_at DESC 
        LIMIT 20
    ]])
    
    local resultList = {}
    if results then
        for _, result in ipairs(results) do
            local playerName = result.name or "Player"
            table.insert(resultList, {
                raceId = result.race_id,
                trackName = result.track_name,
                playerName = playerName,
                position = result.position,
                time = result.race_time,
                points = result.points_earned,
                date = result.created_at
            })
        end
    end
    
    print('DEBUG: Found race results:', json.encode(resultList))
    return resultList
end)

-- Get racer history for a specific player
RegisterServerCallback('cw-racingapp:server:fetchRacerHistory', function(source, racerName)
    local src = source
    print('DEBUG: Getting racer history for:', racerName)
    
    -- Get player's race history
    local history = exports.oxmysql:executeSync([[
        SELECT r.*, c.name 
        FROM race_results r 
        JOIN characters c ON r.player_id = c.id 
        WHERE c.name = ?
        ORDER BY r.created_at DESC 
        LIMIT 50
    ]], {racerName})
    
    local historyList = {}
    if history then
        for _, race in ipairs(history) do
            table.insert(historyList, {
                raceId = race.race_id,
                trackName = race.track_name,
                position = race.position,
                time = race.race_time,
                points = race.points_earned,
                date = race.created_at
            })
        end
    end
    
    print('DEBUG: Found racer history:', json.encode(historyList))
    return historyList
end)

RegisterServerCallback('cw-racingapp:server:curateTrack', function(source, trackId, curated)
    local res = RADB.setCurationForTrack(curated, trackId)
    local status = 'curated'
    if curated == 0 then status = 'NOT curated' end
    if res == 1 then
        TriggerClientEvent('cw-racingapp:client:notify', source, 'Successfully set track ' .. trackId .. ' as ' .. status,
            'success')
        Tracks[trackId].Curated = curated
        return true
    else
        TriggerClientEvent('cw-racingapp:client:notify', source, 'Your input seems to be lacking...', 'error')
        return false
    end
end)

local function createRacingName(source, citizenid, racerName, type, purchaseType, targetSource, creatorName)
    if UseDebug then
        print('Creating a racing user. Input:')
        print('citizenid', citizenid)
        print('racerName', racerName)
        print('type', type)
        print('purchaseType', json.encode(purchaseType, { indent = true }))
    end

    local cost = 1000
    if purchaseType and purchaseType.racingUserCosts and purchaseType.racingUserCosts[type] then
        cost = purchaseType.racingUserCosts[type]
    else
        TriggerClientEvent('cw-racingapp:client:notify', source,
            'The user type you entered does not exist, defaulting to $1000', 'error')
    end

    if not handleRemoveMoney(source, purchaseType.moneyType, cost, creatorName) then return false end


    local creatorCitizenId = 'unknown'
    if getCitizenId(source) then creatorCitizenId = getCitizenId(source) end
    addRacerName(citizenid, racerName, targetSource, type, creatorCitizenId)
    return true
end

local function getRacersCreatedByUser(src, citizenId, type)
    if Config.Permissions[type] and Config.Permissions[type].controlAll then
        if UseDebug then print('Fetching racers for a god') end
        return RADB.getAllRaceUsers()
    end
    if UseDebug then print('Fetching racers for a master') end
    return RADB.getRaceUsersBelongingToCitizenId(citizenId)
end

RegisterServerCallback('cw-racingapp:server:getRacersCreatedByUser', function(source, citizenid, type)
    if UseDebug then print('Fetching all racers created by ', citizenid) end
    local result = getRacersCreatedByUser(source, citizenid, type)
    if UseDebug then print('result from fetching racers created by user', citizenid, json.encode(result)) end
    return result
end)

RegisterServerCallback('cw-racingapp:server:changeRacerName', function(source, racerNameInUse)
    if UseDebug then print('Changing Racer Name for src', source, ' to name', racerNameInUse) end
    local result = changeRacerName(source, racerNameInUse)
    if UseDebug then print('Race user result:', result) end
    local ranking = getRankingForRacer(racerNameInUse)
    if UseDebug then print('Ranking:', json.encode(ranking)) end
    return result
end)

RegisterServerCallback('cw-racingapp:server:updateTrackMetadata', function(source, trackId, metadata)
    if not trackId then
        return false
    end
    if UseDebug then print('Updating track', trackId, ' metadata with:', json.encode(metadata, { indent = true })) end
    if RADB.updateTrackMetadata(trackId, metadata) then
        Tracks[trackId].Metadata = metadata
        return true
    end
    return false
end)

RegisterNetEvent('cw-racingapp:server:removeRacerName', function(racerName)
    if UseDebug then print('removing racer with name', racerName) end
    if UseDebug then print('removed by source', source, getCitizenId(source)) end

    local res = RADB.getRaceUserByName(racerName)

    RADB.removeRaceUserByName(racerName)
    Wait(1000)
    local playerSource = getSrcOfPlayerByCitizenId(res.citizenid)
    if playerSource ~= nil then
        if UseDebug then
            print('pinging player', playerSource)
        end
        TriggerClientEvent('cw-racingapp:client:updateRacerNames', tonumber(playerSource))
    end
end)

local function setRevokedRacerName(src, racerName, revoked)
    local res = RADB.getRaceUserByName(racerName)
    if res then
        RADB.setRaceUserRevoked(racerName, revoked)
        local readableRevoked = 'revoked'
        if revoked == 0 then readableRevoked = 'active' end
        TriggerClientEvent('cw-racingapp:client:notify', src, 'User is now set to ' .. readableRevoked, 'success')
        if UseDebug then print('Revoking for citizenid', res.citizenid) end
        local playerSource = getSrcOfPlayerByCitizenId(res.citizenid)
        if playerSource ~= nil then
            if UseDebug then
                print('pinging player', playerSource)
            end
            TriggerClientEvent('cw-racingapp:client:updateRacerNames', tonumber(playerSource))
        end
    else
        TriggerClientEvent('cw-racingapp:client:notify', src, 'Race Name Not Found', 'error')
    end
end

RegisterNetEvent('cw-racingapp:server:setRevokedRacenameStatus', function(racername, revoked)
    if UseDebug then print('revoking racename', racername, revoked) end
    setRevokedRacerName(source, racername, revoked)
end)

RegisterNetEvent('cw-racingapp:server:createRacerName', function(playerId, racerName, type, purchaseType, creatorName)
    if UseDebug then
        print(
            'Creating a user',
            json.encode({ playerId = playerId, racerName = racerName, type = type, purchaseType = purchaseType })
        )
    end
    local citizenId = getCitizenId(tonumber(playerId))
    if citizenId then
        createRacingName(source, citizenId, racerName, type, purchaseType, playerId, creatorName)
    else
        TriggerClientEvent('cw-racingapp:client:notify', source, Lang("could_not_find_person"), "error")
    end
end)

RegisterServerCallback('cw-racingapp:server:purchaseCrypto', function(source, racerName, cryptoAmount)
    local src = source
    local moneyToPay = math.floor((1.0 * cryptoAmount) / Config.Options.conversionRate)
    if UseDebug then
        print('Buying Crypto')
        print('Crypto Amount:', cryptoAmount)
        print('In money:', moneyToPay)
    end
    if handleRemoveMoney(src, Config.Payments.crypto, moneyToPay, racerName) then
        handleAddMoney(src, 'racingcrypto', cryptoAmount, racerName, 'purchased_crypto')
        return 'SUCCESS'
    end
    return 'NOT_ENOUGH'
end)

RegisterServerCallback('cw-racingapp:server:sellCrypto', function(source, racerName, cryptoAmount)
    local src = source
    local money = (1.0 * cryptoAmount) / Config.Options.conversionRate
    local afterFee = math.floor(money - money * Config.Options.sellCharge)
    if UseDebug then
        print('Selling Crypto')
        print('Crypto Amount:', cryptoAmount)
        print('In money:', money)
        print('After fee:', afterFee)
    end
    if handleRemoveMoney(src, 'racingcrypto', cryptoAmount, racerName) then
        handleAddMoney(src, Config.Payments.crypto, afterFee, racerName, 'sold_crypto')
        return 'SUCCESS'
    end
    return 'NOT_ENOUGH'
end)

RegisterServerCallback('cw-racingapp:server:transferCrypto', function(source, racerName, cryptoAmount, recipientName)
    local src = source
    local recipient = RADB.getRaceUserByName(recipientName)
    if UseDebug then print('Recipient data', json.encode(recipient, { indent = true })) end
    if not recipient then return 'USER_DOES_NOT_EXIST' end
    local recipientSrc = getSrcOfPlayerByCitizenId(recipient.citizenid)
    if UseDebug then print('Recipient src:', recipientSrc) end
    if RacingCrypto.removeCrypto(racerName, cryptoAmount) then
        TriggerClientEvent('cw-racingapp:client:updateUiData', src, 'crypto', RacingCrypto.getRacerCrypto(racerName))
        RacingCrypto.addRacerCrypto(recipientName, math.floor(cryptoAmount))
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("transfer_succ") .. recipientName, 'success')
        if recipientSrc then
            TriggerClientEvent('cw-racingapp:client:updateUiData', tonumber(recipientSrc), 'crypto',
                RacingCrypto.getRacerCrypto(recipientName))
            TriggerClientEvent('cw-racingapp:client:notify', tonumber(recipientSrc),
                Lang("transfer_succ_rec") .. racerName, 'success')
        end
        return 'SUCCESS'
    end
    return 'NOT_ENOUGH'
end)

local function srcHasUserAccess(src, access)
    local raceUser = RADB.getActiveRacerName(getCitizenId(src))
    if not raceUser then 
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("error_no_user"), 'error')
        return false
    end
    local auth = raceUser.auth

    local hasAuth = Config.Permissions[auth][access]

    if not hasAuth then
        TriggerClientEvent('cw-racingapp:client:notify', src, Lang("not_auth"), 'error')
        return false
    end
    return true
end

RegisterServerCallback('cw-racingapp:server:toggleAutoHost', function(source)
    if not srcHasUserAccess(source,'handleAutoHost') then return end
    
    AutoHostIsAllowed = not AutoHostIsAllowed
    return AutoHostIsAllowed
end)

RegisterServerCallback('cw-racingapp:server:toggleHosting', function(source)
        local raceUser = RADB.getActiveRacerName(getCitizenId(source))
    if not srcHasUserAccess(source, 'handleHosting') then return end

    HostingIsAllowed = not HostingIsAllowed
    return HostingIsAllowed
end)

RegisterServerCallback('cw-racingapp:server:getAdminData', function(source)
    return {
        autoHostIsEnabled = AutoHostIsAllowed,
        hostingIsEnabled = HostingIsAllowed
    }
end)

local function updateRacingUserAuth(data)
    if not Config.Permissions[data.auth] then return end
    local res = RADB.setRaceUserAuth(data.racername, data.auth)
    if res then
        local userSrc = getSrcOfPlayerByCitizenId(data.citizenId)
        if userSrc then
            TriggerClientEvent('cw-racingapp:client:updateRacerNames', userSrc)
        end
        return true
    end
    return false
end

RegisterServerCallback('cw-racingapp:server:setUserAuth', function(source, data)
    if not srcHasUserAccess(source, 'controlAll') then return end

    return updateRacingUserAuth(data)
end)

RegisterServerCallback('cw-racingapp:server:fetchRacerHistory', function(source, racerName)
    return RESDB.getRacerHistory(racerName)
end)

RegisterServerCallback('cw-racingapp:server:getDashboardData', function(source, racerName, racers, daysBack)
    local trackStats = RESDB.getTrackRaceStats(daysBack or Config.Dashboard.defaultDaysBack)
    local racerStats = RESDB.getRacerHistory(racerName)
    local topRacerStats = RESDB.getTopRacerWinnersAndWinLoss(racers, daysBack or Config.Dashboard.defaultDaysBack)
    return { trackStats = trackStats, racerStats = racerStats, topRacerStats = topRacerStats }
end)

if Config.EnableCommands then
    registerCommand('changeraceuserauth', "Change authority on racing user. If used on another player they will need to relog for effect to take place.", {
        { name = 'Racer Name', help = 'Racer name. Put in quotations if multiple words' },
        { name = 'type',       help = 'racer/creator/master/god or whatever you got' },
    }, true, function(source, args)
        if not args[1] or not args[2] then
            print("^1PEBKAC error. Google it.^0")
            return
        end
        local data = {
            racername = args[1],
            auth = args[2],
            citizenId = getCitizenId(source)
        }
        updateRacingUserAuth(data)
    end, true)

    registerCommand('createracinguser', "Create a racing user", {
        { name = 'type',       help = 'racer/creator/master/god' },
        { name = 'identifier', help = 'Server ID' },
        { name = 'Racer Name', help = 'Racer name. Put in quotations if multiple words' }
        }, true, function(source, args)
        local type = args[1]
        local id = tonumber(args[2])
        print(
            '^4Creating a user with input^0',
            json.encode({ playerId = args[2], racerName = args[3], type = args[1] })
        )
        if args[4] then
            print('^1Too many args!')
            TriggerClientEvent('cw-racingapp:client:notify', source,
                "Too many arguments. You probably did not read the command input suggestions.", "error")
            return
        end

        if not Config.Permissions[type:lower()] then
            TriggerClientEvent('cw-racingapp:client:notify', source, "This user type does not exist", "error")
            return
        end

        local citizenid
        local name = args[3]

        if tonumber(id) then
            citizenid = getCitizenId(tonumber(id))
            if UseDebug then print('CitizenId', citizenid) end
            if not citizenid then
                TriggerClientEvent('cw-racingapp:client:notify', source, Lang("id_not_found"), "error")
                return
            end
        else
            citizenid = id
        end

        if #name >= Config.MaxRacerNameLength then
            TriggerClientEvent('cw-racingapp:client:notify', source, Lang("name_too_long"), "error")
            return
        end

        if #name <= Config.MinRacerNameLength then
            TriggerClientEvent('cw-racingapp:client:notify', source, Lang("name_too_short"), "error")
            return
        end

        local tradeType = {
            moneyType = Config.Payments.createRacingUser,
            racingUserCosts = {
                racer = 0,
                creator = 0,
                master = 0,
                god = 0
            },
        }

        createRacingName(source, citizenid, name, type:lower(), tradeType, id)
    end, true)

    registerCommand('remracename', 'Remove Racing Name From Database',
        { { name = 'name', help = 'Racer name. Put in quotations if multiple words' } }, true, function(source, args)
            local name = args[1]
            print('name of racer to delete:', name)
            RADB.removeRaceUserByName(name)
        end, true)

    registerCommand('removeallracetracks', 'Remove the race_tracks table', {}, true, function(source, args)
        RADB.wipeTracksTable()
    end, true)

    registerCommand('racingappcurated', 'Mark/Unmark track as curated',
            { { name = 'trackid', help = 'Track ID (not name). Use quotation marks!!!' }, { name = 'curated', help = 'true/false' } },
        true,
        function(source, args)
            print('Curating track: ', args[1], args[2])
            local curated = 0
            if args[2] == 'true' then
                curated = 1
            end
            local res = MySQL.Sync.execute('UPDATE race_tracks SET curated = ? WHERE raceid = ?', { curated, args[1] })
            if res == 1 then
                Tracks[args[1]].Curated = curated
                TriggerClientEvent('cw-racingapp:client:notify', source, 'Successfully set track curated as ' .. args[2])
            else
                TriggerClientEvent('cw-racingapp:client:notify', source, 'Your input seems to be lacking...')
            end
        end, true)

    registerCommand('cwdebugracing', 'toggle debug for racing', {}, true, function(source, args)
        UseDebug = not UseDebug
        print('debug is now:', UseDebug)
        TriggerClientEvent('cw-racingapp:client:toggleDebug', source, UseDebug)
    end, true)

    registerCommand('cwlisttracks', 'toggle debug for racing', {}, true, function(source, args)
        local tracksWithoutCheckpoints = {}
        for i, track in pairs(Tracks) do
            tracksWithoutCheckpoints[i] = track
            tracksWithoutCheckpoints[i].Checkpoints = nil
        end
        print(json.encode(tracksWithoutCheckpoints, {indent=true}))        
    end, true)

    registerCommand('cwracingapplist', 'list racingapp stuff', {}, true, function(source, args)
        print("=========================== ^3TRACKS^0 ===========================")
        print(json.encode(Tracks, { indent = true }))
        print("=========================== ^3AVAILABLE RACES^0 ===========================")
        print(json.encode(AvailableRaces, { indent = true }))
        print("=========================== ^3NOT FINISHED^0 ===========================")
        print(json.encode(NotFinished, { indent = true }))
        print("=========================== ^TIMERS^0 ===========================")
        print(json.encode(Timers, { indent = true }))
        print("=========================== ^RESULTS^0 ===========================")
        print(json.encode(RaceResults, { indent = true }))
    end, true)

end
