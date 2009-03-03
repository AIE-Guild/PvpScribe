--[[

    PvpScribe.lua -- AIE PvP statistics recorder add-on
    Author: Mark Rogaski, stigg@pobox.com
    $Id: PvpScribe.lua,v 1.9 2007-06-08 03:38:51 wendigo Exp $

    Copyright (c) 2007, 2009; Mark Rogaski.

    All rights reserved.

    Redistribution and use in source and binary forms, with or without 
    modification, are permitted provided that the following conditions 
    are met:

        * Redistributions of source code must retain the above copyright 
          notice, this list of conditions and the following disclaimer.

        * Redistributions in binary form must reproduce the above 
          copyright notice, this list of conditions and the following
          disclaimer in the documentation and/or other materials provided
          with the distribution.

        * Neither the name of the copyright holder nor the names of any
          contributors may be used to endorse or promote products derived
          from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    'AS IS' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

--]]

PvpScribe = AceLibrary('AceAddon-2.0'):new('AceConsole-2.0', 
        'AceEvent-2.0', 'AceDB-2.0', 'AceDebug-2.0')


--
-- Addon properties
--
PvpScribe.VERSION = '0.3.00'

PvpScribe.statsRecorded             = false
PvpScribe.currentBattlegroundStart  = nil
PvpScribe.currentBattlegroundName   = nil
PvpScribe.currentBattlegroundID     = nil
PvpScribe.hashStore                 = {}

PvpScribe:RegisterChatCommand({ '/pvpscribe', '/pvps' }, {
    type = 'group',
    args = {
        history = {
            type = 'text',
            name = 'History Size',
            desc = 'Set the maximum number of event records',
            usage = '<length>',
            set = function(n)
                PvpScribe.db.char.config.maxHistory = n
                while table.maxn(PvpScribe.db.char.history) > n do
                    table.remove(PvpScribe.db.char.history)
                end
            end,
            get = function()
                return PvpScribe.db.char.config.maxHistory
            end,
        },
        clear = {
            type = 'execute',
            name = 'Clear Stats',
            desc = 'Erase statistics database',
            func = function ()
                StaticPopup_Show('PVPSCRIBE_CLEAR_CONFIRM')
            end,
        },
        show = {
            type = 'execute',
            name = 'Show Stats',
            desc = 'Show PvP statistics',
            func = 'ShowStats'
        },
    },
})

PvpScribe:RegisterDB('PvpScribeDB', 'PvpScribeDB', 'char')
PvpScribe:RegisterDefaults('char', {
    config = {
        maxHistory = 256,
    },
    charInfo = {
        name      = '',
        faction   = '',
        realm     = '',
        class     = '',
        level     = '',
        guild     = '',
        guildRank = '',
    },
    summary = {
        count           = 0,
        wins            = 0,
        killingBlows    = 0, 
        honorKills      = 0, 
        deaths          = 0, 
        honorGained     = 0, 
        damageDone      = 0, 
        healingDone     = 0,
        rankSum         = 0,
        rankMax         = 0,
    },
    wgStats = {
        count           = 0,
        flagsCaptured   = 0,
        flagsReturned   = 0,
    },
    abStats = {
        count           = 0,
        basesAssaulted  = 0,
        basesDefended   = 0,
    },
    avStats = {
        count               = 0,
        graveyardsAssaulted = 0,
        graveyardsDefended  = 0,
        towersAssaulted     = 0,
        towersDefended      = 0,
        minesCaptured       = 0,
        leadersKilled       = 0,
        secondaryObjectives = 0,
    },
    signature = {
        summary = '',
        wgStats = '',
        abStats = '',
        avStats = '',
    },
    history = {},
})

--[[
--
--  Popup definitions
--
--]]

StaticPopupDialogs['PVPSCRIBE_CLEAR_CONFIRM'] = {
    text            = 'Do you want to erase all recorded PvP statistics?',
    button1         = 'Yes',
    button2         = 'No',
    timeout         = 30,
    whileDead       = 1,
    hideOnEscape    = 1,
    OnAccept = function ()
        PvpScribe:ClearStats()
    end,
};


--[[
--
--  Event handlers
--
--]]

function PvpScribe:OnInitialize()

    -- Refresh DB signatures
    local char  = self.db.char
    local sig   = char.signature
    local newDb = true
    for _, sec in pairs({ 'summary', 'wgStats', 'abStats', 'avStats' }) do
        for k, v in pairs(char[sec]) do
            if v ~= 0 then
                newDb = false
            end
        end
    end

    if not newDb then
        PvpScribe:StoreSignatures()
    end
    PvpScribe:GenerateSignatures()

    self.db.char.version = PvpScribe.VERSION
end

function PvpScribe:OnEnable(first)
    -- get character info
    local info = self.db.char.charInfo
    if first then
        -- these shouldn't change during a login session
        info.name       = UnitName('player')
        info.class      = UnitClass('player')
        _, info.faction = UnitFactionGroup('player')
        info.realm      = GetRealmName()
    end
    info.level                  = UnitLevel('player')
    info.guild, info.guildRank  = GetGuildInfo('player')

    PvpScribe:RegisterEvent('UPDATE_BATTLEFIELD_STATUS')
    PvpScribe:RegisterEvent('ZONE_CHANGED_NEW_AREA')
    PvpScribe:RegisterEvent('PLAYER_LEVEL_UP')
    PvpScribe:RegisterEvent('PLAYER_GUILD_UPDATE')

    self:Print('enabled ... the Bookkeeper of Blood is ready.')
end

function PvpScribe:OnDisable()
    self:Print('disabled.')
end

function PvpScribe:UPDATE_BATTLEFIELD_STATUS()
    self:LevelDebug(3, 'received event: UPDATE_BATTLEFIELD_STATUS')
    PvpScribe:ExamineBGStatus()
end

function PvpScribe:ZONE_CHANGED_NEW_AREA()
    self:LevelDebug(3, 'received event: ZONE_CHANGED_NEW_AREA')
    if PvpScribe.statsRecorded then
        PvpScribe.statsRecorded             = false
        PvpScribe.currentBattlegroundStart  = nil
        PvpScribe.currentBattlegroundName   = nil
        self:LevelDebug(3, 'set currentBattlegroundName = NIL')
        PvpScribe.currentBattlegroundID     = nil
    end
end

function PvpScribe:PLAYER_LEVEL_UP(new)
    self.db.char.charInfo.level = new
end

function PvpScribe:PLAYER_GUILD_UPDATE()
    local info = self.db.char.charInfo
    info.guild, info.guildRank = GetGuildInfo('player')
end

function PvpScribe:ClearStats()
    local char = self.db.char

    char.summary = {
        count           = 0,
        wins            = 0,
        killingBlows    = 0, 
        honorKills      = 0, 
        deaths          = 0, 
        honorGained     = 0, 
        damageDone      = 0, 
        healingDone     = 0,
        rankSum         = 0,
        rankMax         = 0,
    }
    char.wgStats = {
        count           = 0,
        flagsCaptured   = 0,
        flagsReturned   = 0,
    }
    char.abStats = {
        count           = 0,
        basesAssaulted  = 0,
        basesDefended   = 0,
    }
    char.avStats = {
        count               = 0,
        graveyardsAssaulted = 0,
        graveyardsDefended  = 0,
        towersAssaulted     = 0,
        towersDefended      = 0,
        minesCaptured       = 0,
        leadersKilled       = 0,
        secondaryObjectives = 0,
    }
    char.signature = {
        summary = '',
        wgStats = '',
        abStats = '',
        avStats = '',
    }
    char.history = {}

    PvpScribe:GenerateSignatures()

    UIErrorsFrame:AddMessage('PvP Statistics Cleared', 0, 0.5, 1.0, 1.0, 10)
end

function PvpScribe:ShowStats()
    local summary = self.db.char.summary
    local wgStats = self.db.char.wgStats
    local abStats = self.db.char.abStats
    local avStats = self.db.char.avStats

    -- This is a friggin' ugly mess.  But, until I start mucking about
    -- with some XML for a proper display it will have to do.

    local message = '|cFF00FF00PvP Statistics|r\n\n' ..
            string.format('Battles: %d\n', summary.count) ..
            string.format('Wins: %d\n', summary.wins) ..
            string.format('Killing blows: %d\n', summary.killingBlows) ..
            string.format('Honor kills: %d\n', summary.honorKills) ..
            string.format('Deaths: %d\n', summary.deaths) ..
            string.format('Honor gained: %d\n', summary.honorGained) ..
            string.format('Damage done: %d\n', summary.damageDone) ..
            string.format('Healing done: %d\n', summary.healingDone) ..
            '\n|cFF00FF00Warsong Gulch Statistics|r\n\n' ..
            string.format('Battles: %d\n', wgStats.count) ..
            string.format('Flags captured: %d\n', wgStats.flagsCaptured) ..
            string.format('Flags returned: %d\n', wgStats.flagsReturned) ..
            '\n|cFF00FF00Arathi Basin Statistics|r\n\n' ..
            string.format('Battles: %d\n', abStats.count) ..
            string.format('Bases assaulted: %d\n', abStats.basesAssaulted) ..
            string.format('Bases defended: %d\n', abStats.basesDefended) ..
            '\n|cFF00FF00Alterac Valley Statistics|r\n\n' ..
            string.format('Battles: %d\n', avStats.count) ..
            string.format('Graveyards assaulted: %d\n', 
                    avStats.graveyardsAssaulted) ..
            string.format('Graveyards defended: %d\n',
                    avStats.graveyardsDefended) ..
            string.format('Towers assaulted: %d\n', avStats.towersAssaulted) ..
            string.format('Towers defended: %d\n', avStats.towersDefended) ..
            string.format('Mines captured: %d\n', avStats.minesCaptured) ..
            string.format('Leaders killed: %d\n', avStats.leadersKilled) ..
            string.format('Secondary objectives: %d\n', 
                    avStats.secondaryObjectives)

    UIErrorsFrame:AddMessage(message, 0, 0.5, 1.0, 1.0, 10)
end

function PvpScribe:ExamineBGStatus()
    local map = {};
    if not PvpScribe.statsRecorded then
        for i = 1, MAX_BATTLEFIELD_QUEUES do
            map =  {}
            local status, mapName, instanceID = GetBattlefieldStatus(i);

            -- find the current battleground instance
            if (status == 'active') then
                if not PvpScribe.currentBattlegroundStart then
                    PvpScribe.currentBattlegroundStart = 
                            date('%Y-%m-%d %H:%M:%S')
                    PvpScribe.currentBattlegroundName  = mapName
                    self:LevelDebug(3, 
                            'set currentBattlegroundName = ' .. mapName)
                    PvpScribe.currentBattlegroundID    = instanceID
                end
                local winner = GetBattlefieldWinner()
                if winner then
                    PvpScribe:RecordBGScore(winner)
                    PvpScribe.statsRecorded = true
                end
            end
        end
    end
end

function PvpScribe:RecordBGScore(winner)
    local n             = GetNumBattlefieldScores()
    local m             = GetNumBattlefieldStats()
    local bgRecord      = {}
    local bgAuxStat     = {}
    local bgName        = PvpScribe.currentBattlegroundName
    local archRecord    = ''

    for i = 1, n do
        local name, killingBlows, honorKills, deaths, honorGained, faction, 
                rank, race, class, filename, damageDone, healingDone = 
                GetBattlefieldScore(i);

        if name == self.db.char.charInfo.name then
            local isWin
            if winner == faction then
                isWin = true
            else
                isWin = false
            end
            bgRecord = { 
                beginTime       = PvpScribe.currentBattlegroundStart,
                endTime         = date('%Y-%m-%d %H:%M:%S'),
                battleground    = bgName,
                win             = isWin, 
                killingBlows    = killingBlows, 
                honorKills      = honorKills, 
                deaths          = deaths, 
                honorGained     = honorGained,
                damageDone      = damageDone,
                healingDone     = healingDone,
                rank            = i,
                population      = n,
            }

            -- Gather battleground-specific stats
            for j = 1, m do
                bgAuxStat[j] = GetBattlefieldStatData(i, j)
            end
        end
    end

    -- Stash the current DB signatures
    PvpScribe:StoreSignatures()

    -- Add data to the collected statistics
    PvpScribe:UpdateSummaryStats(bgRecord)

    -- Add battleground-specific data
    PvpScribe:UpdateBattlegroundStats(bgName, bgRecord, bgAuxStat)

    -- Generate the new DB signatures
    PvpScribe:GenerateSignatures()

    -- Build the archival record
    archRecord = PvpScribe:BuildArchiveRecord(bgRecord, bgAuxStat)
    self:LevelDebug(3, 'created record ' .. tostring(name))

    -- Push the record to the historical data queue
    local history = self.db.char.history
    local histmax = self.db.char.config.maxHistory
    table.insert(history, 1, archRecord)
    while table.maxn(history) > histmax do
        table.remove(history)
    end

end

function PvpScribe:UpdateSummaryStats(rec)
    local db = self.db.char.summary
    db.count = db.count + 1
    if rec.win then
        db.wins = db.wins + 1
    end
    db.killingBlows = db.killingBlows   + rec.killingBlows
    db.honorKills   = db.honorKills     + rec.honorKills
    db.deaths       = db.deaths         + rec.deaths
    db.honorGained  = db.honorGained    + rec.honorGained
    db.damageDone   = db.damageDone     + rec.damageDone
    db.healingDone  = db.healingDone    + rec.healingDone
    db.rankSum      = db.rankSum        + rec.rank
    db.rankMax      = db.rankMax        + rec.population
end

function PvpScribe:UpdateBattlegroundStats(name, rec, aux)
    if name == 'Warsong Gulch' then

        local db = self.db.char.wgStats
        db.count                = db.count         + 1
        db.flagsCaptured        = db.flagsCaptured + aux[1]
        db.flagsReturned        = db.flagsReturned + aux[2]

    elseif name == 'Arathi Basin' then

        local db = self.db.char.abStats
        db.count                = db.count           + 1
        db.basesAssaulted       = db.basesAssaulted  + aux[1]
        db.basesDefended        = db.basesDefended   + aux[2]

    elseif name == 'Alterac Valley' then

        local db = self.db.char.avStats
        db.count                = db.count               + 1
        db.graveyardsAssaulted  = db.graveyardsAssaulted + aux[1]
        db.graveyardsDefended   = db.graveyardsDefended  + aux[2]
        db.towersAssaulted      = db.towersAssaulted     + aux[3]
        db.towersDefended       = db.towersDefended      + aux[4]
        db.minesCaptured        = db.minesCaptured       + aux[5]
        db.leadersKilled        = db.leadersKilled       + aux[6]
        db.secondaryObjectives  = db.secondaryObjectives + aux[7]

    else

        self:LevelDebug(2, 'battleground stats not supported for ' .. name)

    end

end

function PvpScribe:BuildArchiveRecord(rec, aux)
    local arch  = PvpScribe:FreezeRecord(rec)
    arch        = arch .. '/' 
    arch        = arch .. PvpScribe:FreezeRecord(aux)
    arch        = arch .. '/' 
    arch        = arch .. PvpScribe:CheckSum(arch)
    return arch
end

function PvpScribe:FreezeRecord(rec)
    local temp = {}

    for index, value in pairs(rec) do

        local code 

        if index == 'count' then
            code = 'ct'
        elseif index == 'beginTime' then
            code = 'bt'
        elseif index == 'endTime' then
            code = 'et'
        elseif index == 'battleground' then
            code = 'bg'
        elseif index == 'win' then
            code = 'wn'
        elseif index == 'killingBlows' then
            code = 'kb'
        elseif index == 'honorKills' then
            code = 'hk'
        elseif index == 'deaths' then
            code = 'de'
        elseif index == 'honorGained' then
            code = 'hg'
        elseif index == 'damageDone' then
            code = 'dd'
        elseif index == 'healingDone' then
            code = 'hd'
        elseif index == 'rank' then
            code = 'rk'
        elseif index == 'population' then
            code = 'po'
        elseif index == 'flagsCaptured' then
            code = 'fc'
        elseif index == 'flagsReturned' then
            code = 'fr'
        elseif index == 'basesAssaulted' then
            code = 'ba'
        elseif index == 'basesDefended' then
            code = 'bd'
        elseif index == 'graveyardsAssaulted' then
            code = 'ga'
        elseif index == 'graveyardsDefended' then
            code = 'gd'
        elseif index == 'towersAssaulted' then
            code = 'ta'
        elseif index == 'towersDefended' then
            code = 'td'
        elseif index == 'minesCaptured' then
            code = 'mc'
        elseif index == 'leadersKilled' then
            code = 'lk'
        elseif index == 'secondaryObjectives' then
            code = 'so'
        else
            self:LevelDebug(2, 'no code mapping for ' .. index)
            code = ''
        end

        if code ~= '' then
            table.insert(temp, code .. '=' .. tostring(value))
        end

    end

    return table.concat(temp, ':')
end

function PvpScribe:StoreSignatures()
    -- Record the current signature hashes for future comparison
    local char = self.db.char
    local sig  = char.signature
    for _, v in pairs({ 'summary', 'wgStats', 'abStats', 'avStats' }) do
        PvpScribe.hashStore[v] = 
                PvpScribe:CheckSum(PvpScribe:FreezeRecord(char[v]))
        if PvpScribe.hashStore[v] ~= sig[v] then
            self:LevelDebug(2, 'bad signature detected for ' .. v)
        end
    end
end

function PvpScribe:GenerateSignatures()
    -- Sign the current database values
    local char = self.db.char
    local sig  = char.signature
    for _, v in pairs({ 'summary', 'wgStats', 'abStats', 'avStats' }) do
        if PvpScribe.hashStore[v] and PvpScribe.hashStore[v] ~= sig[v] then
            sig[v] = ''
        else
            sig[v] = PvpScribe:CheckSum(PvpScribe:FreezeRecord(char[v]))
        end
    end
    PvpScribe.hashStore = {}
end

function PvpScribe:CheckSum(str)
    -- Implementation of a Fletcher 8-bit checksum, as described in 
    -- RFC 1146, adapted for ASCII strings.
    local a = 0
    local b = 0
    local n = string.len(str)
    for i = 1, n do
        local d = string.byte(str, i)
        a = (a + d) % 256
        b = (b + a) % 256
    end
    return string.format('%02x%02x', a, b)
end

