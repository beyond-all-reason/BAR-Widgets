-----------------------------------------------------------------------------------------------
-- Hold Alt+F. Still LMB tap = Look here (no wheel). Move or hold LMB = open the wheel, then release on a slice.
-- Clicks on the minimap ping that map position (minimap coords, not the 3D ray behind the UI).
-- custom_keybind_mode + action ping_wheel_on for a custom bind.
-- pingCommands = LMB, pingMessages = RMB (off by default).
-- Mouse 4 = commands, Mouse 5 = messages when enabled.
-- Top-bar metal/energy click asks allies for that resource.
-- backward_compat_pings is off: no extra engine map ping for players without this widget.
-----------------------------------------------------------------------------------------------
function widget:GetInfo()
    return {
        name    = "Callout Wheel",
        desc    = "Alt+F ping wheel. Names nearby units/wrecks and sends a system line to allies.",
        author  = "Manny",
        date    = "August 31, 2026",
        license = "GNU GPL, v2 or later",
        version = "1.0",
        layer   = 999, -- DrawScreen on top; minimap MousePress is layer 0 and runs first, so minimap clicks are polled in Update
        enabled = true,
        handler = true
    }
end

-- Player-facing text. %s = player name, second %s = unit name.
-- Do not translate ping `id` fields further down (network keys).
local L = {
    player = "Player",
    commander = "the Commander",
    unit = "unit",

    muted = "Callouts muted for %ds",
    mutedWheel = "MUTED %ds",
    close = "CLOSE",
    hintMsgs = "R-click\nMsgs",
    hintCmds = "L-click\nCmds",

    needMetal = "%s needs metal!",
    needEnergy = "%s needs energy!",
    wreck = "%s: Reclaim this field!",

    nukeReady1 = "%s: 1 nuke ready",
    nukeReadyN = "%s: %d nukes ready",
    nukeReadyIn = "%s: Nuke ready in %ds",
    nukeScout = ", requires scouting",

    dangerName = "⚠️ DANGER",
    dangerLabel = "DANGER",
    dangerMine = "%s warns %s is in danger!",
    dangerAlly = "%s warns %s is in danger!",
    dangerEnemy = "%s warns %s is dangerous!",
    dangerEmpty = "%s warns this area is dangerous!",

    onMyWayName = "🥾 ON MY WAY",
    onMyWayLabel = "ON MY WAY",
    onMyWayMine = "%s is coming to help %s!",
    onMyWayAlly = "%s is coming to help %s!",
    onMyWayEnemy = "%s is moving on %s!",
    onMyWayEmpty = "%s is on their way!",

    assistName = "✋ ASSIST ME",
    assistLabel = "ASSIST ME",
    assistMine = "%s wants help at %s!",
    assistAlly = "%s wants help at %s!",
    assistEnemy = "%s wants help pushing %s!",
    assistBuilding = "%s needs help building %s!",
    assistEmpty = "%s needs assistance!",

    defendName = "🛡️ DEFEND",
    defendLabel = "DEFEND",
    defendBuilding = "%s wants to defend %s!",
    defendUnit = "%s wants to protect %s!",
    defendEmpty = "%s wants to defend!",

    lookHereName = "Look here!",
    lookHereLabel = "LOOK HERE",
    lookHereMine = "%s wants you to look at %s!",
    lookHereAlly = "%s wants you to look at %s!",
    lookHereEnemy = "%s wants you to look at %s!",
    lookHereEnemyUnit = "%s wants to kill %s",
    lookHereEnemyBuilding = "%s wants to attack the %s",
    lookHereEmpty = "%s says look here!",

    dgunName = "D-gun!",
    dgunLabel = "D-gun!",
    dgunMine = "%s wants a D-gun near the %s.",
    dgunAlly = "%s wants a D-gun near the allied %s.",
    dgunEnemy = "%s wants a D-gun on the %s.",

    nukeName = "☢️Nuking here",
    nukeLabel = "Nuke",
    nukeMine = "%s is nuking near the %s.",
    nukeAlly = "%s is nuking near the allied %s.",
    nukeEnemy = "%s is nuking the %s.",
    nukeEmpty = "%s is nuking here!",
}

local resNeedChat = {
    metal  = L.needMetal,
    energy = L.needEnergy,
}

local custom_keybind_mode = false                  -- set to true for custom keybind

local pingCommands = {                             -- the options in the ping wheel, displayed clockwise from 12 o'clock
    { id = "DANGER", name = L.dangerName, icon = "⚠️", label = L.dangerLabel, color = { 1.00, 0.42, 0.10, 1 },
      targetChat = {
          mine  = L.dangerMine,
          ally  = L.dangerAlly,
          enemy = L.dangerEnemy,
      },
      emptyChat = L.dangerEmpty },
    { id = "ON MY WAY", name = L.onMyWayName, icon = "🥾", label = L.onMyWayLabel, color = { 0.22, 0.90, 0.35, 1 },
      targetChat = {
          mine  = L.onMyWayMine,
          ally  = L.onMyWayAlly,
          enemy = L.onMyWayEnemy,
      },
      emptyChat = L.onMyWayEmpty },
    { id = "ASSIST ME", name = L.assistName, icon = "✋", label = L.assistLabel, color = { 1.00, 0.92, 0.12, 1 },
      targetChat = {
          mine = L.assistMine,
          ally = L.assistAlly,
          enemy = L.assistEnemy,
          buildingUnfinished = L.assistBuilding,
      },
      wreckChat = L.wreck,
      emptyChat = L.assistEmpty },
    { id = "DEFEND", name = L.defendName, icon = "🛡️", label = L.defendLabel, color = { 0.82, 0.32, 0.88, 1 },
      targetChat = {
          building = L.defendBuilding,
          unit     = L.defendUnit,
      },
      emptyChat = L.defendEmpty },
}

-- Quick LMB on the hub (no slice): classic Look here, as a callout, no icon
local pingLookHere = {
    id = "LOOK HERE",
    name = L.lookHereName,
    label = L.lookHereLabel,
    color = { 0.45, 0.88, 1.00, 1 },
    targetChat = {
        mine = L.lookHereMine,
        ally = L.lookHereAlly,
        enemy = L.lookHereEnemy,
        enemyUnit = L.lookHereEnemyUnit,
        enemyBuilding = L.lookHereEnemyBuilding,
    },
    wreckChat = L.wreck,
    emptyChat = L.lookHereEmpty,
}

local enable_ping_messages = false -- set to true for RMB / Mouse 5 message wheel (D-gun, Nuke)

local pingMessages = {
    { id = "D-gun!", name = L.dgunName, icon = "💥", label = L.dgunLabel, color = { 1.00, 1.00, 0.10, 1 },
      targetChat = {
          mine  = L.dgunMine,
          ally  = L.dgunAlly,
          enemy = L.dgunEnemy,
      } },
    { id = "Nuke", name = L.nukeName, icon = "☢️", label = L.nukeLabel, color = { 1.00, 0.20, 0.20, 1 },
      targetChat = {
          mine  = L.nukeMine,
          ally  = L.nukeAlly,
          enemy = L.nukeEnemy,
      },
      emptyChat = L.nukeEmpty },
}

local player_color_mode = true -- set to false to use default pingWheelColor instead of player color

-- Fade frames (set to 0 to disable)
local numFadeInFrames = 4
local numFadeOutFrames = 4
-- more than pingBurstMax callouts inside pingBurstWindow -> mute
local pingBurstMax = 8
local pingBurstWindow = 6
local pingMuteDuration = 15

-- Custom ping FX (replaces the default engine map mark when true)
local replace_default_ping = true
local backward_compat_pings = true -- also send engine map pings for players without this widget
local pingFxDuration = 6.0     -- seconds the custom ping stays visible
local pingFxMinimapSize = 8    -- fallback dot size on the minimap
local pingFxMinimapIcon = 26   -- icon size on the minimap
local pingFxDropTime = 0.45    -- seconds for the land/shrink animation
local pingFxDropStart = 13     -- start scale on the world map (drops down to 1)
local pingFxMinimapDropStart = 18 -- start scale on the minimap (drops down to 1)
local pingFxPulseAmp = 0.38    -- breath expand after landing
local pingFxPulseSpeed = 3.4   -- breath speed (radians / sec)
local pingFxMaxActive = 24

local viewSizeX, viewSizeY, viewPosX, viewPosY = Spring.GetViewGeometry()
viewPosX, viewPosY = viewPosX or 0, viewPosY or 0

-- Sizes and colors
local pingWheelRadius = 0.12 * math.min(viewSizeX, viewSizeY)
local pingWheelMinimapScale = 0.5 -- wheel size on the minimap (1 = same as world)
local centerDotSize = 16
local deadZoneRadiusRatio = 0.30
local outerLimitRadiusRatio = 24 -- how far the white selection line can be dragged (× wheel radius)

local pingWheelTextSize = 17
local pingWheelTextSpamColor = { 0.9, 0.9, 0.9, 0.4 }
local pingWheelPlayerColor = { 0.9, 0.8, 0.5, 0.8 }
local pingWheelColor = { 0.9, 0.8, 0.5, 0.6 }

local wheelBg = { 0.035, 0.07, 0.14, 0.88 }
local wheelBgSel = { 0.12, 0.42, 0.72, 0.42 }
local wheelLine = { 0.38, 0.86, 1.0, 0.92 }
local wheelGlow = { 0.28, 0.72, 1.0, 0.22 }
local wheelHub = { 0.02, 0.05, 0.10, 0.94 }
local wheelX = { 0.42, 0.82, 0.96, 0.88 }
---------------------------------------------------------------
-- End of params

local globalDim = 1
local globalFadeIn = 0
local globalFadeOut = 0

local bgTexture = "LuaUI/images/glow.dds"
local bgTextureSizeRatio = 2.35
local bgTextureColor = { 0.12, 0.38, 0.62, 0.42 }

local pingWheel = pingCommands
local keyDown = false
local displayPingWheel = false

local pingWorldLocation
local pingWheelScreenLocation
local pingFromMinimap = false
local pingWheelSelection = 0
local recentPingTimes = {}
local pingMuteUntil = 0
local lastMuteWarn = 0
local lastPingRecvTimes = {}
local pingRecvMuteUntil = {}
local mousePressTime = 0
local lookHereMaxHold = 0.20 -- seconds; still LMB (no move) this long before the wheel opens
local lookHereMoveCancel = 12 -- px from press; mouse movement cancels Look here and opens the wheel
local pendingLmbWheel = false -- LMB down, waiting to see if it's a hold or a drag

-- Speedups
local spGetMouseState = Spring.GetMouseState
local spGetModKeyState = Spring.GetModKeyState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetMiniMapGeometry = Spring.GetMiniMapGeometry
local spIsAboveMiniMap = Spring.IsAboveMiniMap
local spGetMiniMapDualScreen = Spring.GetMiniMapDualScreen
local floor = math.floor
local pi = math.pi
local sin = math.sin
local cos = math.cos
local sqrt = math.sqrt

local soundDefaultSelect = "sounds/commands/cmd-default-select.wav"
local soundSetTarget = "sounds/commands/cmd-settarget.wav"
local soundMapPing = "sounds/ui/mappoint2.wav"

local myPlayerID
local pingDefs = {}
local activePings = {}
local recentPingPos = {}
local recentPingPosTTL = 2.5
local osClock = os.clock
local mapSizeX = (Game and Game.mapSizeX) or 1
local mapSizeZ = (Game and Game.mapSizeZ) or 1
local pingSoundReady = false
local lastLuaMsg = ""
local lastLuaMsgTime = 0
local lastLmbDown = false
local lastMiniPingLmb = false
local pendingResClick

local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetGroundHeight = Spring.GetGroundHeight
local spGetLocalAllyTeamID = Spring.GetLocalAllyTeamID
local spGetCameraPosition = Spring.GetCameraPosition
local spIsGUIHidden = Spring.IsGUIHidden
local spSendLuaUIMsg = Spring.SendLuaUIMsg
local spPlaySoundFile = Spring.PlaySoundFile

local function RegisterPingDefs()
    pingDefs = {}
    local function addList(list)
        for i = 1, #list do
            local opt = list[i]
            if opt.id then
                pingDefs[opt.id] = opt
            end
            if opt.label then
                pingDefs[opt.label] = opt
            end
            if opt.name then
                pingDefs[opt.name] = opt
            end
        end
    end
    addList(pingCommands)
    addList(pingMessages)
    addList({ pingLookHere })
end

local function PlayerDisplayName(playerID)
    local name = select(1, spGetPlayerInfo(playerID, false)) or ""
    if WG and WG.playernames and WG.playernames.getPlayername then
        name = WG.playernames.getPlayername(playerID) or name
    end
    return name
end

local function PlayerTeamColor(playerID)
    local _, _, _, teamID = spGetPlayerInfo(playerID, false)
    if teamID then
        local r, g, b = Spring.GetTeamColor(teamID)
        if r then
            return { r, g, b, 1 }
        end
    end
    return pingWheelPlayerColor or pingWheelColor
end

local function AcceptPingFrom(playerID)
    if playerID == myPlayerID then
        return true
    end
    local _, _, mySpec = spGetPlayerInfo(myPlayerID, false)
    if mySpec then
        return true
    end
    local _, _, theirSpec, _, allyTeamID = spGetPlayerInfo(playerID, false)
    if theirSpec then
        return false
    end
    return allyTeamID == spGetLocalAllyTeamID()
end

local function PrunePings()
    local now = osClock()
    local n = 0
    for i = 1, #activePings do
        local ping = activePings[i]
        if now - ping.t0 < pingFxDuration then
            n = n + 1
            activePings[n] = ping
        end
    end
    for i = n + 1, #activePings do
        activePings[i] = nil
    end
end

local function RememberPingPos(x, z)
    recentPingPos[#recentPingPos + 1] = { x = x, z = z, t = osClock() }
end

local function IsRecentPingPos(x, z)
    local now = osClock()
    local n = 0
    local hit = false
    for i = 1, #recentPingPos do
        local p = recentPingPos[i]
        if now - p.t < recentPingPosTTL then
            n = n + 1
            recentPingPos[n] = p
            local dx, dz = p.x - x, p.z - z
            if dx * dx + dz * dz < 256 then
                hit = true
            end
        end
    end
    for i = n + 1, #recentPingPos do
        recentPingPos[i] = nil
    end
    return hit
end

local function SpawnPing(playerID, opt, x, y, z)
    local gy = spGetGroundHeight(x, z)
    if not gy then
        gy = y
    end
    if #activePings >= pingFxMaxActive then
        table.remove(activePings, 1)
    end
    RememberPingPos(x, z)
    local color = opt.color or pingWheelColor
    activePings[#activePings + 1] = {
        x = x,
        y = gy,
        z = z,
        t0 = osClock(),
        color = color,
        icon = opt.icon,
        label = opt.label or opt.name or "",
        playerName = PlayerDisplayName(playerID),
        playerColor = PlayerTeamColor(playerID),
    }
    if pingSoundReady then
        spPlaySoundFile(soundMapPing, 0.55, x, gy, z, nil, nil, nil, "ui")
        spPlaySoundFile(soundMapPing, 0.22, nil, "ui")
    else
        spPlaySoundFile(soundSetTarget, 0.35, "ui")
    end
end

local function UnitIsCommander(ud)
    if not ud then
        return false
    end
    local cp = ud.customParams
    if cp and (cp.iscommander or cp.commtype or cp.commander) then
        return true
    end
    local n = string.lower(ud.name or "")
    return n == "armcom" or n == "corcom" or n == "legcom"
        or n:find("^armcom") or n:find("^corcom") or n:find("^legcom")
end

local function UnitIsBeingBuilt(unitID)
    local _, _, _, _, buildProgress = Spring.GetUnitHealth(unitID)
    return buildProgress ~= nil and buildProgress < 1
end

local function UnitHumanName(unitID)
    local defID = Spring.GetUnitDefID(unitID)
    local ud = defID and UnitDefs[defID]
    if not ud then
        return L.unit
    end
    if UnitIsCommander(ud) then
        return L.commander
    end
    return ud.translatedHumanName or ud.humanName or ud.tooltip or ud.name or L.unit
end

local function FormatUnitChat(fmt, playerName, unitName)
    if unitName == L.commander then
        fmt = fmt:gsub("the allied %%s", "%%s")
        fmt = fmt:gsub("the %%s", "%%s")
    end
    return string.format(fmt, playerName, unitName)
end

local function UnitSide(unitID)
    local teamID = Spring.GetUnitTeam(unitID)
    local myTeam = Spring.GetMyTeamID()
    if teamID == myTeam then
        return "mine"
    end
    if teamID and Spring.AreTeamsAllied(myTeam, teamID) then
        return "ally"
    end
    return "enemy"
end

local function UnitKind(unitID)
    local defID = Spring.GetUnitDefID(unitID)
    local ud = defID and UnitDefs[defID]
    if ud and (ud.isBuilding or ud.isFactory) then
        return "building"
    end
    return "unit"
end

local function UnitIsNukeSilo(unitID)
    local defID = Spring.GetUnitDefID(unitID)
    local ud = defID and UnitDefs[defID]
    if not ud then
        return false
    end
    local cp = ud.customParams
    if cp and cp.unitgroup == "nuke" then
        return true
    end
    local n = string.lower(ud.name or "")
    if n == "armsilo" or n == "corsilo" or n == "legsilo"
        or n:find("silo_scav", 1, true)
    then
        return true
    end
    if ud.weapons then
        for i = 1, #ud.weapons do
            local wd = WeaponDefs[ud.weapons[i].weaponDef]
            local wcp = wd and wd.customParams
            if wcp and tostring(wcp.nuclear) == "1" and wd.stockpile then
                return true
            end
        end
    end
    return false
end

local function NukeStockpileSeconds(unitID)
    local defID = Spring.GetUnitDefID(unitID)
    local ud = defID and UnitDefs[defID]
    if ud and ud.weapons then
        for i = 1, #ud.weapons do
            local wd = WeaponDefs[ud.weapons[i].weaponDef]
            if wd and wd.stockpile and wd.stockpileTime and wd.stockpileTime > 0 then
                return wd.stockpileTime / ((Game and Game.gameSpeed) or 30)
            end
        end
    end
    return 120
end

local function FriendlyNukeCallout(unitID, playerName, needsScout)
    if UnitIsBeingBuilt(unitID) then
        return
    end
    if UnitSide(unitID) == "enemy" then
        return
    end
    if not UnitIsNukeSilo(unitID) or not Spring.GetUnitStockpile then
        return
    end
    local stocked, _, build = Spring.GetUnitStockpile(unitID)
    if stocked == nil then
        return
    end
    local text
    if stocked >= 1 then
        if stocked == 1 then
            text = string.format(L.nukeReady1, playerName)
        else
            text = string.format(L.nukeReadyN, playerName, stocked)
        end
    else
        local remain = math.ceil((1 - (build or 0)) * NukeStockpileSeconds(unitID))
        if remain < 1 then
            remain = 1
        end
        text = string.format(L.nukeReadyIn, playerName, remain)
    end
    if needsScout then
        text = text .. L.nukeScout
    end
    return text
end

local function UnitChatFormat(chats, unitID)
    local kind = UnitKind(unitID)
    local side = UnitSide(unitID)
    if kind == "building" and side ~= "enemy" and UnitIsBeingBuilt(unitID) then
        if chats.buildingUnfinished then
            return chats.buildingUnfinished
        end
    end
    if side == "enemy" then
        if kind == "building" and chats.enemyBuilding then
            return chats.enemyBuilding
        end
        if kind == "unit" and chats.enemyUnit then
            return chats.enemyUnit
        end
    end
    return chats[kind] or chats[side]
end

local function BestUnitAt(x, y, z)
    local units = Spring.GetUnitsInCylinder(x, z, 200)
    if not units or #units == 0 then
        return
    end
    local bestID, bestDist
    for i = 1, #units do
        local unitID = units[i]
        local ux, uy, uz = Spring.GetUnitPosition(unitID)
        if ux then
            local dx, dy, dz = ux - x, (uy or y) - y, uz - z
            local dist = dx * dx + dy * dy + dz * dz
            if not bestDist or dist < bestDist then
                bestID, bestDist = unitID, dist
            end
        end
    end
    return bestID, bestDist
end

local function FeatureIsWreck(featureID)
    local metal, maxMetal = Spring.GetFeatureResources(featureID)
    return (maxMetal or 0) > 0 or (metal or 0) > 0
end

local function BestWreckAt(x, y, z)
    local feats = Spring.GetFeaturesInCylinder(x, z, 200)
    if not feats or #feats == 0 then
        return
    end
    local bestID, bestDist
    for i = 1, #feats do
        local fid = feats[i]
        if FeatureIsWreck(fid) then
            local fx, fy, fz = Spring.GetFeaturePosition(fid)
            if fx then
                local dx, dy, dz = fx - x, (fy or y) - y, fz - z
                local dist = dx * dx + dy * dy + dz * dz
                if not bestDist or dist < bestDist then
                    bestID, bestDist = fid, dist
                end
            end
        end
    end
    return bestID, bestDist
end

local function ShowSystemLine(text)
    if not text or text == "" then
        return
    end
    local colored = "\255\160\220\255" .. text
    local mySpec = myPlayerID and select(3, spGetPlayerInfo(myPlayerID, false))
    if mySpec and Spring.SendMessageToSpectators then
        Spring.SendMessageToSpectators(colored)
        return
    end
    if not mySpec and Spring.SendMessageToAllyTeam then
        local allyTeam = spGetLocalAllyTeamID()
        if allyTeam then
            Spring.SendMessageToAllyTeam(allyTeam, colored)
            return
        end
    end
    if Spring.SendMessage then
        Spring.SendMessage(colored)
    else
        Spring.Echo(text)
    end
end

local function SendTeamLuaUI(msg)
    if not spSendLuaUIMsg then
        return
    end
    pcall(spSendLuaUIMsg, msg, "allies")
    pcall(spSendLuaUIMsg, msg, "spectators")
end

local function BroadcastSystemLine(text)
    ShowSystemLine(text)
    SendTeamLuaUI("PW1C\t" .. text)
end

local function AnnounceTargetPing(opt, x, y, z)
    local chats = opt.targetChat
    if not chats then
        return
    end
    local playerName = PlayerDisplayName(myPlayerID)
    if playerName == "" then
        playerName = L.player
    end
    local unitID, unitDist = BestUnitAt(x, y, z)
    local wreckID, wreckDist
    if opt.wreckChat then
        wreckID, wreckDist = BestWreckAt(x, y, z)
    end
    local text
    if wreckID and (not unitID or wreckDist <= unitDist) then
        text = string.format(opt.wreckChat, playerName)
    elseif not unitID then
        if opt.emptyChat then
            text = string.format(opt.emptyChat, playerName)
        end
    else
        local isLook = opt == pingLookHere
        local isAssist = opt.id == "ASSIST ME"
        if isLook or isAssist then
            text = FriendlyNukeCallout(unitID, playerName, isAssist)
        end
        if not text then
            local fmt = UnitChatFormat(chats, unitID)
            if fmt then
                text = FormatUnitChat(fmt, playerName, UnitHumanName(unitID))
            end
        end
    end
    if text then
        if opt.icon and opt.icon ~= "" then
            text = opt.icon .. " " .. text
        end
        BroadcastSystemLine(text)
    end
end

local function BroadcastPing(opt, x, y, z)
    local key = opt.id or opt.label or opt.name
    if not key then
        return
    end
    SendTeamLuaUI(string.format("PW1\t%s\t%.1f\t%.1f\t%.1f", key, x, y, z))
    SpawnPing(myPlayerID, opt, x, y, z)
    AnnounceTargetPing(opt, x, y, z)
end

local function PingFade(t)
    if t < 0.62 then
        return 1
    end
    return 1 - (t - 0.62) / 0.38
end

local function PingDrop(age, startScale)
    startScale = startScale or pingFxDropStart
    if age >= pingFxDropTime then
        return 1, 0
    end
    local u = age / pingFxDropTime
    local eased = 1 - (1 - u) * (1 - u) * (1 - u)
    return 1 + (startScale - 1) * (1 - eased), (1 - eased) * 550
end

local function PingPulse(age)
    if age < pingFxDropTime then
        return 1
    end
    local phase = (age - pingFxDropTime) * pingFxPulseSpeed
    local breath = 0.5 - 0.5 * cos(phase)
    return 1 + pingFxPulseAmp * breath
end

local function MiniRot()
    if Spring.GetMiniMapRotation then
        return floor((Spring.GetMiniMapRotation() / pi * 2 + 0.5) % 4)
    end
    return 0
end

local function WorldToMini(x, z, sx, sz)
    local rot = MiniRot()
    if rot == 1 then
        return z / mapSizeZ * sx, x / mapSizeX * sz
    end
    if rot == 2 then
        return sx - x / mapSizeX * sx, z / mapSizeZ * sz
    end
    if rot == 3 then
        return sx - z / mapSizeZ * sx, sz - x / mapSizeX * sz
    end
    return x / mapSizeX * sx, sz - z / mapSizeZ * sz
end

local function Clamp01(v)
    if v < 0 then
        return 0
    end
    if v > 1 then
        return 1
    end
    return v
end

local function RefreshViewSize()
    local vsx, vsy, vpx, vpy = Spring.GetViewGeometry()
    viewSizeX, viewSizeY = vsx or viewSizeX, vsy or viewSizeY
    viewPosX, viewPosY = vpx or 0, vpy or 0
    return viewSizeX, viewSizeY, viewPosX, viewPosY
end

-- Actual map pixels (not the FlowUI frame). py is the bottom edge in mouse coords.
-- px can be 0 (BAR top-left) — never treat 0 as missing.
local function MiniMapMapRect()
    local vsx, vsy, _, vpy = RefreshViewSize()
    if not spGetMiniMapGeometry then
        return
    end
    local px, py, sx, sy, minimized = spGetMiniMapGeometry()
    if minimized or px == nil or py == nil or sx == nil or sy == nil or sx < 8 or sy < 8 then
        return
    end
    local yFromTop = vsy - py - sy
    local expectedBottom = vsy - sy
    local pyBottom
    if math.abs(yFromTop - expectedBottom) <= math.abs(py - expectedBottom) then
        pyBottom = yFromTop
    else
        pyBottom = py
    end
    return px, pyBottom, sx, sy, vpy or 0
end

-- Generous hit: BAR panel in the top-left. Used only to catch the click.
local function MiniMapPanelHit(mx, my)
    local vsx, vsy = RefreshViewSize()
    if WG and WG.minimap and WG.minimap.getHeight then
        local h = WG.minimap.getHeight()
        if h and h > 8 and mx >= 0 and mx <= math.max(h, vsx * 0.32) and my <= vsy and my >= vsy - h then
            return true
        end
        -- Mouse Y from top
        if h and h > 8 and mx >= 0 and mx <= math.max(h, vsx * 0.32) and my >= 0 and my <= h then
            return true
        end
    end
    local px, pyBottom, sx, sy = MiniMapMapRect()
    if px ~= nil and sx and sy then
        if mx >= px and mx <= px + sx and my >= pyBottom and my <= pyBottom + sy then
            return true
        end
    end
    if spIsAboveMiniMap and spIsAboveMiniMap(mx, my) then
        return true
    end
    return false
end

-- UV from the map texture. px == 0 is valid.
local function MiniMapHit(mx, my)
    local px, pyBottom, sx, sy, vpy = MiniMapMapRect()
    if px == nil or sx == nil or sy == nil then
        return
    end
    local x = mx
    local dual = spGetMiniMapDualScreen and spGetMiniMapDualScreen()
    if dual == "left" then
        x = x + sx + px
    end
    local u = (x - px) / sx
    local vUp = (my - pyBottom + (vpy or 0)) / sy
    if u < -0.08 or u > 1.08 or vUp < -0.08 or vUp > 1.08 then
        if not MiniMapPanelHit(mx, my) then
            return
        end
    end
    return Clamp01(u), Clamp01(vUp)
end

local function MiniMapToWorld(mx, my)
    local u, vUp = MiniMapHit(mx, my)
    if u == nil then
        -- Panel click but geometry UV failed: still map through the BAR top-left box.
        if not MiniMapPanelHit(mx, my) then
            return
        end
        local vsx, vsy = RefreshViewSize()
        local h = (WG and WG.minimap and WG.minimap.getHeight and WG.minimap.getHeight()) or (vsy * 0.32)
        local px, pyBottom, sx, sy = MiniMapMapRect()
        local w = (sx and sx >= 8) and sx or h
        local x0 = (px ~= nil) and px or 0
        local y0 = (pyBottom ~= nil) and pyBottom or (vsy - h)
        local rh = (sy and sy >= 8) and sy or h
        u = Clamp01((mx - x0) / math.max(w, 1))
        vUp = Clamp01((my - y0) / math.max(rh, 1))
    end
    mapSizeX = (Game and Game.mapSizeX) or mapSizeX
    mapSizeZ = (Game and Game.mapSizeZ) or mapSizeZ
    local nx, nz = u, 1 - vUp
    local rot = MiniRot()
    if rot == 1 then
        nx, nz = nz, nx
        nx = 1 - nx
    elseif rot == 2 then
        nx, nz = 1 - nx, 1 - nz
    elseif rot == 3 then
        nx, nz = nz, nx
        nz = 1 - nz
    end
    local wx, wz = nx * mapSizeX, nz * mapSizeZ
    if wx < 0 then
        wx = 0
    elseif wx > mapSizeX then
        wx = mapSizeX
    end
    if wz < 0 then
        wz = 0
    elseif wz > mapSizeZ then
        wz = mapSizeZ
    end
    return wx, spGetGroundHeight(wx, wz) or 0, wz
end

local function IsOverMiniMap(mx, my)
    return MiniMapPanelHit(mx, my)
end

local function StripColorCodes(text)
    return (tostring(text or ""):gsub("\255...", ""))
end

local function colourNames(R, G, B)
    local R255 = math.floor(R * 255) --the first \255 is just a tag (not colour setting) no part can end with a zero due to engine limitation (C)
    local G255 = math.floor(G * 255)
    local B255 = math.floor(B * 255)
    if R255 % 10 == 0 then
        R255 = R255 + 1
    end
    if G255 % 10 == 0 then
        G255 = G255 + 1
    end
    if B255 % 10 == 0 then
        B255 = B255 + 1
    end
    return "\255" .. string.char(R255) .. string.char(G255) .. string.char(B255) --works thanks to zwzsg
end

local function SendEnginePing(opt, x, y, z)
    local color = opt.color or pingWheelColor
    Spring.MarkerAddPoint(x, y, z, colourNames(color[1], color[2], color[3]) .. (opt.name or opt.label or ""), false)
end

function widget:Initialize()
    -- add the action handler with argument for press and release using the same function call
    widgetHandler.actionHandler:AddAction(self, "ping_wheel_on", PingWheelAction, { true }, "pR")
    widgetHandler.actionHandler:AddAction(self, "ping_wheel_on", PingWheelAction, { false }, "r")
    myPlayerID = Spring.GetLocalPlayerID()
    mapSizeX = (Game and Game.mapSizeX) or mapSizeX
    mapSizeZ = (Game and Game.mapSizeZ) or mapSizeZ
    pingSoundReady = (VFS and VFS.FileExists and VFS.FileExists(soundMapPing)) or false
    RegisterPingDefs()
    pingWheelPlayerColor = { Spring.GetTeamColor(Spring.GetMyTeamID()) }
    if player_color_mode then
        pingWheelColor = pingWheelPlayerColor
    end

    widgetHandler:DisableWidget("Mouse Buildspacing")
end

function widget:ViewResize(vsx, vsy)
    viewSizeX, viewSizeY = vsx, vsy
    local _
    _, _, viewPosX, viewPosY = Spring.GetViewGeometry()
    viewPosX, viewPosY = viewPosX or 0, viewPosY or 0
    pingWheelRadius = 0.12 * math.min(viewSizeX, viewSizeY)
end

-- when widget exits, re-enable the mouse build spacing widget
function widget:Shutdown()
    activePings = {}
    widgetHandler:EnableWidget("Mouse Buildspacing")
end

local function WheelScale()
    if pingFromMinimap then
        return pingWheelMinimapScale
    end
    return 1
end

local function WheelRadius()
    return pingWheelRadius * WheelScale()
end

-- Store the ping location in pingWorldLocation.
-- Clicks on the minimap use minimap→world coords, never the 3D ray behind the UI.
local function SetPingLocation(mx, my)
    if mx == nil or my == nil then
        mx, my = spGetMouseState()
    end
    local wx, wy, wz = MiniMapToWorld(mx, my)
    if wx ~= nil then
        pingWorldLocation = { wx, wy, wz }
        pingWheelScreenLocation = { x = mx, y = my }
        pingFromMinimap = true
        return true
    end
    if IsOverMiniMap(mx, my) then
        local _, pos = spTraceScreenRay(mx, my, true, true)
        if pos then
            pingWorldLocation = { pos[1], pos[2], pos[3] }
            pingWheelScreenLocation = { x = mx, y = my }
            pingFromMinimap = true
            return true
        end
        return false
    end
    local _, pos = spTraceScreenRay(mx, my, true)
    if pos then
        pingWorldLocation = { pos[1], pos[2], pos[3] }
        pingWheelScreenLocation = { x = mx, y = my }
        pingFromMinimap = false
        return true
    end
    return false
end

local function FadeIn()
    if numFadeInFrames == 0 then return end
    globalFadeIn = numFadeInFrames
    globalFadeOut = 0
end

local function FadeOut()
    if numFadeOutFrames == 0 then return end
    globalFadeIn = 0
    globalFadeOut = numFadeOutFrames
end

local function TurnOn()
    if not pingWorldLocation then
        SetPingLocation()
    end
    if not pingWorldLocation then
        return false
    end
    displayPingWheel = true
    Spring.PlaySoundFile(soundSetTarget, 0.1, 'ui')
    FadeIn()
    return true
end

local function TurnOff()
    local wasOn = displayPingWheel
    displayPingWheel = false
    pingWorldLocation = nil
    pingWheelScreenLocation = nil
    pingFromMinimap = false
    pingWheelSelection = 0
    pendingLmbWheel = false
    return wasOn
end

local function BurstCheck(times, muteUntil)
    local now = osClock()
    if now < muteUntil then
        return false, muteUntil
    end
    local n = 0
    for i = 1, #times do
        if now - times[i] < pingBurstWindow then
            n = n + 1
            times[n] = times[i]
        end
    end
    for i = n + 1, #times do
        times[i] = nil
    end
    if n >= pingBurstMax then
        for i = 1, n do
            times[i] = nil
        end
        return false, now + pingMuteDuration
    end
    times[n + 1] = now
    return true, muteUntil
end

local function WarnMuted()
    local now = osClock()
    if now - lastMuteWarn < 1 then
        return
    end
    lastMuteWarn = now
    local left = math.ceil(pingMuteUntil - now)
    if left < 1 then
        left = 1
    end
    ShowSystemLine(string.format(L.muted, left))
end

local function IssuePing(opt)
    if not opt or not pingWorldLocation then
        return
    end
    local ok
    ok, pingMuteUntil = BurstCheck(recentPingTimes, pingMuteUntil)
    if not ok then
        WarnMuted()
        globalFadeOut = 0
        TurnOff()
        return
    end
    local x, y, z = pingWorldLocation[1], pingWorldLocation[2], pingWorldLocation[3]
    globalFadeIn = 0
    globalFadeOut = 0
    globalDim = 1
    TurnOff()
    if replace_default_ping then
        BroadcastPing(opt, x, y, z)
    end
    if (not replace_default_ping) or backward_compat_pings then
        SendEnginePing(opt, x, y, z)
    end
end

function PingWheelAction(_, _, _, args)
    keyDown = args[1] and true or false
end

function widget:KeyPress(key, mods, isRepeat)
    if not custom_keybind_mode then
        if key == 102 and mods.alt then -- alt + f
            keyDown = true
        end
    end
end

function widget:KeyRelease(key, mods)
    if key == 102 then
        keyDown = false
    end
end

function widget:MousePress(mx, my, button)
    if keyDown or button == 4 or button == 5 then
        -- functionality of mouse build spacing is put in here, sigh
        -- check if alt is pressed
        local alt, ctrl, meta, shift = spGetModKeyState()
        if (button == 4 or button == 5) and alt then
            if button == 4 then
                Spring.SendCommands("buildspacing inc")
            elseif button == 5 then
                Spring.SendCommands("buildspacing dec")
            end
            return
        end

        if button == 1 or button == 4 then
            pingWheel = pingCommands
        elseif enable_ping_messages and (button == 3 or button == 5) then
            pingWheel = pingMessages
        elseif not enable_ping_messages and button == 5 then
            return
        else
            pingWheel = pingCommands
        end
        if button == 1 then
            mousePressTime = osClock()
            if not SetPingLocation(mx, my) then
                if not IsOverMiniMap(mx, my) then
                    return false
                end
            end
            pendingLmbWheel = true
        else
            if not TurnOn() then
                if not IsOverMiniMap(mx, my) then
                    return false
                end
            end
        end
        return true
    else
        FadeOut()
    end
end

local function MouseMovedFromPress(mx, my)
    local origin = pingWheelScreenLocation
    if not origin then
        return false
    end
    local dx = mx - origin.x
    local dy = my - origin.y
    return dx * dx + dy * dy >= lookHereMoveCancel * lookHereMoveCancel
end

local function OpenPendingWheel()
    pendingLmbWheel = false
    TurnOn()
end

-- Mouse movement while LMB is down means they want the wheel, not Look here.
function widget:MouseMove(mx, my, dx, dy, button)
    if pendingLmbWheel and not displayPingWheel and MouseMovedFromPress(mx, my) then
        OpenPendingWheel()
    end
end

-- Still LMB tap (no move): Look here. Hold or drag: wheel; release issues the selected ping.
function widget:MouseRelease(mx, my, button)
    if pendingLmbWheel and button == 1 then
        pendingLmbWheel = false
        if pingWorldLocation and not MouseMovedFromPress(mx, my) then
            IssuePing(pingLookHere)
        end
        return
    end
    if displayPingWheel
        and pingWorldLocation
    then
        if pingWheelSelection > 0 then
            IssuePing(pingWheel[pingWheelSelection])
        else
            FadeOut()
        end
    else
        FadeOut()
    end
end

local function HitTopbarResource(mx, my)
    local tb = WG and WG.topbar
    if not tb or not tb.GetPosition then
        return
    end
    if tb.getResourceBarsVisible and not tb.getResourceBarsVisible() then
        return
    end
    local a, b, c, d = tb.GetPosition()
    local x1, y1, x2, y2
    if type(a) == "table" then
        x1, y1, x2, y2 = a[1], a[2], a[3], a[4]
    else
        x1, y1, x2, y2 = a, b, c, d
    end
    if not x1 then
        return
    end
    if mx < x1 or mx > x2 or my < y1 or my > y2 then
        return
    end
    local totalWidth = x2 - x1
    local width = floor(totalWidth / 4.4)
    local margin = 0
    if WG.FlowUI and WG.FlowUI.elementMargin then
        margin = WG.FlowUI.elementMargin
    end
    if mx <= x1 + width then
        return "metal"
    end
    local e0 = x1 + width + margin
    if mx >= e0 and mx <= e0 + width then
        return "energy"
    end
end

local function AnnounceNeedResource(res)
    local fmt = resNeedChat[res]
    if not fmt then
        return
    end
    local ok
    ok, pingMuteUntil = BurstCheck(recentPingTimes, pingMuteUntil)
    if not ok then
        WarnMuted()
        return
    end
    local playerName = PlayerDisplayName(myPlayerID)
    if playerName == "" then
        playerName = L.player
    end
    BroadcastSystemLine(string.format(fmt, playerName))
end

local function PollTopbarResourceClick()
    if displayPingWheel or keyDown then
        lastLmbDown = select(3, spGetMouseState())
        pendingResClick = nil
        return
    end
    if myPlayerID ~= nil then
        local spec = select(3, spGetPlayerInfo(myPlayerID, false))
        if spec then
            lastLmbDown = select(3, spGetMouseState())
            pendingResClick = nil
            return
        end
    end
    local mx, my, lmb = spGetMouseState()
    if lmb and not lastLmbDown then
        local res = HitTopbarResource(mx, my)
        if res then
            pendingResClick = { res = res, x = mx, y = my }
        else
            pendingResClick = nil
        end
    elseif (not lmb) and lastLmbDown and pendingResClick then
        local dx, dy = mx - pendingResClick.x, my - pendingResClick.y
        if dx * dx + dy * dy < 100 and HitTopbarResource(mx, my) == pendingResClick.res then
            AnnounceNeedResource(pendingResClick.res)
        end
        pendingResClick = nil
    elseif not lmb then
        pendingResClick = nil
    end
    lastLmbDown = lmb and true or false
end

-- BAR minimap (layer 0) gets MousePress first and often eats LMB for camera move.
local function PollMiniMapPingClick()
    local mx, my, lmb = spGetMouseState()
    if displayPingWheel or not keyDown then
        lastMiniPingLmb = lmb and true or false
        return
    end
    if lmb and IsOverMiniMap(mx, my) then
        if not pendingLmbWheel then
            pingWheel = pingCommands
            mousePressTime = osClock()
            SetPingLocation(mx, my)
            pendingLmbWheel = pingWorldLocation ~= nil
            if pendingLmbWheel and widgetHandler then
                widgetHandler.mouseOwner = widget
            end
        end
    end
    lastMiniPingLmb = lmb and true or false
end

local sec, sec2 = 0, 0
function widget:Update(dt)
    PollTopbarResourceClick()
    PollMiniMapPingClick()
    if pendingLmbWheel and not displayPingWheel then
        local mx, my, lmb = spGetMouseState()
        if not lmb then
            pendingLmbWheel = false
            if pingWorldLocation and not MouseMovedFromPress(mx, my) then
                IssuePing(pingLookHere)
            end
        elseif MouseMovedFromPress(mx, my) or (osClock() - mousePressTime) >= lookHereMaxHold then
            OpenPendingWheel()
        end
    end
    if #activePings > 0 then
        PrunePings()
    end
    sec = sec + dt
    -- we need smooth update of fade frames
    if (sec > 0.017) and globalFadeIn > 0 or globalFadeOut > 0 then
        sec = 0
        if globalFadeIn > 0 then
            globalFadeIn = globalFadeIn - 1
            if globalFadeIn < 0 then globalFadeIn = 0 end
            globalDim = 1 - globalFadeIn / numFadeInFrames
        end
        if globalFadeOut > 0 then
            globalFadeOut = globalFadeOut - 1
            if globalFadeOut <= 0 then
                globalFadeOut = 0
                TurnOff()
            end
            globalDim = globalFadeOut / numFadeOutFrames
        end
    end

    sec2 = sec2 + dt
    if (sec2 > 0.03) and displayPingWheel then
        sec2 = 0
        if globalFadeOut == 0 then
            local mx, my = spGetMouseState()
            if not pingWheelScreenLocation then
                return
            end
            -- calculate where the mouse is relative to the pingWheelScreenLocation, remember top is the first selection
            local dx = mx - pingWheelScreenLocation.x
            local dy = my - pingWheelScreenLocation.y
            local angle = math.atan2(dx, dy)
            local angleDeg = floor(angle * 180 / pi + 0.5)
            if angleDeg < 0 then
                angleDeg = angleDeg + 360
            end
            local offset = 360 / #pingWheel / 2
            local selection = (floor((360 + angleDeg + offset) / 360 * #pingWheel)) % #pingWheel + 1
            -- deadzone is no selection
            local dist = sqrt(dx * dx + dy * dy)
            local r = WheelRadius()
            if (dist < deadZoneRadiusRatio * r)
                or (dist > outerLimitRadiusRatio * r)
            then
                pingWheelSelection = 0
            elseif selection ~= pingWheelSelection then
                pingWheelSelection = selection
                Spring.PlaySoundFile(soundDefaultSelect, 0.3, 'ui')
            end
        end
    end
end

local glColor2 = gl.Color
local function MyGLColor(r, g, b, a)
    if type(r) == "table" then
        r, g, b, a = r[1], r[2], r[3], r[4]
    end
    if not r or not g or not b or not a then
        return
    end
    -- new alpha is globalDim * a, clamped between 0 and 1
    local a2 = a * globalDim
    if a2 > 1 then a = 1 end
    if a2 < 0 then a = 0 end
    glColor2(r, g, b, a2)
end

-- GL speedups
local glColor                = MyGLColor
local glLineWidth            = gl.LineWidth
local glPushMatrix           = gl.PushMatrix
local glPopMatrix            = gl.PopMatrix
local glBlending             = gl.Blending
local glBeginEnd             = gl.BeginEnd
local glBeginText            = gl.BeginText
local glEndText              = gl.EndText
local glTexture              = gl.Texture
local glTexRect              = gl.TexRect
local glText                 = gl.Text
local glVertex               = gl.Vertex
local glPointSize            = gl.PointSize
local glTranslate            = gl.Translate
local glScale                = gl.Scale
local glBillboard            = gl.Billboard
local glDepthTest            = gl.DepthTest
local GL_LINES               = GL.LINES
local GL_POINTS              = GL.POINTS
local GL_TRIANGLE_FAN        = GL.TRIANGLE_FAN
local GL_TRIANGLE_STRIP      = GL.TRIANGLE_STRIP
local GL_SRC_ALPHA           = GL.SRC_ALPHA
local GL_ONE_MINUS_SRC_ALPHA = GL.ONE_MINUS_SRC_ALPHA
local GL_ONE                 = GL.ONE

local function DrawFilledCircle(cx, cy, r, steps)
    local function verts()
        glVertex(cx, cy)
        for i = 0, steps do
            local a = i * 2 * pi / steps
            glVertex(cx + r * sin(a), cy + r * cos(a))
        end
    end
    glBeginEnd(GL_TRIANGLE_FAN, verts)
end

local function DrawAnnulusSlice(cx, cy, innerR, outerR, innerA0, innerA1, outerA0, outerA1, steps)
    outerA0 = outerA0 or innerA0
    outerA1 = outerA1 or innerA1
    local function verts()
        for i = 0, steps do
            local t = i / steps
            local ia = innerA0 + (innerA1 - innerA0) * t
            local oa = outerA0 + (outerA1 - outerA0) * t
            glVertex(cx + innerR * sin(ia), cy + innerR * cos(ia))
            glVertex(cx + outerR * sin(oa), cy + outerR * cos(oa))
        end
    end
    glBeginEnd(GL_TRIANGLE_STRIP, verts)
end

local function DrawLine(x1, y1, x2, y2)
    local function verts()
        glVertex(x1, y1)
        glVertex(x2, y2)
    end
    glBeginEnd(GL_LINES, verts)
end

local function DrawEdge(cx, cy, r0, a0, r1, a1, halfW)
    local x0 = cx + r0 * sin(a0)
    local y0 = cy + r0 * cos(a0)
    local x1 = cx + r1 * sin(a1)
    local y1 = cy + r1 * cos(a1)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then
        return
    end
    local nx, ny = -dy / len * halfW, dx / len * halfW
    local function verts()
        glVertex(x0 + nx, y0 + ny)
        glVertex(x0 - nx, y0 - ny)
        glVertex(x1 + nx, y1 + ny)
        glVertex(x1 - nx, y1 - ny)
    end
    glBeginEnd(GL_TRIANGLE_STRIP, verts)
end

local function DrawSliceOutline(cx, cy, innerR, outerR, ia0, ia1, oa0, oa1, steps, cr, cg, cb, alpha)
    glColor(cr, cg, cb, alpha * 0.16)
    DrawAnnulusSlice(cx, cy, outerR - 3.2, outerR + 1.4, oa0, oa1, oa0, oa1, steps)
    DrawAnnulusSlice(cx, cy, innerR - 1.4, innerR + 3.2, ia0, ia1, ia0, ia1, steps)
    DrawEdge(cx, cy, innerR, ia0, outerR, oa0, 2.4)
    DrawEdge(cx, cy, innerR, ia1, outerR, oa1, 2.4)

    glColor(cr, cg, cb, alpha * 0.82)
    DrawAnnulusSlice(cx, cy, outerR - 1.15, outerR + 0.35, oa0, oa1, oa0, oa1, steps)
    DrawAnnulusSlice(cx, cy, innerR - 0.35, innerR + 1.15, ia0, ia1, ia0, ia1, steps)
    DrawEdge(cx, cy, innerR, ia0, outerR, oa0, 1.05)
    DrawEdge(cx, cy, innerR, ia1, outerR, oa1, 1.05)
end

local function DrawThickArc(cx, cy, radius, a0, a1, steps, cr, cg, cb, alpha, halfW)
    glColor(cr, cg, cb, alpha * 0.22)
    DrawAnnulusSlice(cx, cy, radius - halfW * 2.1, radius + halfW * 2.1, a0, a1, a0, a1, steps)
    glColor(cr, cg, cb, alpha)
    DrawAnnulusSlice(cx, cy, radius - halfW, radius + halfW, a0, a1, a0, a1, steps)
end

local function DrawRing(cx, cy, radius, steps, cr, cg, cb, alpha)
    DrawThickArc(cx, cy, radius, 0, 2 * pi, steps, cr, cg, cb, alpha, 0.95)
end

local function DrawPingRipples(baseR, age, fade, cr, cg, cb)
    local function wave(u, r0, r1, a0)
        if u < 0 or u > 1 then
            return
        end
        local r = r0 + (r1 - r0) * u
        local a = fade * a0 * (1 - u) * (1 - u)
        if a < 0.02 then
            return
        end
        glColor2(cr, cg, cb, a * 0.16)
        DrawFilledCircle(0, 0, r, 40)
        DrawThickArc(0, 0, r, 0, 2 * pi, 42, cr, cg, cb, a, 1.3 + u * 2.4)
    end
    local landU = age / (pingFxDropTime + 0.22)
    if landU < 1 then
        wave(landU, baseR * 0.3, baseR * 4.2, 0.95)
    end
    if age >= pingFxDropTime then
        local period = (2 * pi) / pingFxPulseSpeed
        local tBreath = age - pingFxDropTime
        for i = 0, 1 do
            local u = (tBreath / period - i * 0.5) % 1
            wave(u, baseR * 0.9, baseR * 3.5, 0.8)
        end
    end
end

local function DrawThickLine(x1, y1, x2, y2, cr, cg, cb, alpha)
    glColor(cr, cg, cb, alpha * 0.18)
    glLineWidth(5.5)
    DrawLine(x1, y1, x2, y2)
    glColor(cr, cg, cb, alpha * 0.45)
    glLineWidth(3.0)
    DrawLine(x1, y1, x2, y2)
    glColor(cr, cg, cb, alpha)
    glLineWidth(1.6)
    DrawLine(x1, y1, x2, y2)
end

local function DrawWheel(cx, cy)
    local n = #pingWheel
    if n < 1 then
        return
    end
    local r = WheelRadius()
    local textSize = pingWheelTextSize * WheelScale()
    local hubR = r * deadZoneRadiusRatio
    local innerR = hubR * 1.02
    local sliceGap = (2 * pi / n) * 0.02
    local outerGap = (2 * pi / n) * 0.009
    local wedgeSteps = 64

    glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    if gl.Smoothing then
        gl.Smoothing(false, true, false)
    end

    if bgTexture and bgTexture ~= "" then
        glColor(bgTextureColor)
        glTexture(bgTexture)
        local halfSize = r * bgTextureSizeRatio
        glTexRect(cx - halfSize, cy - halfSize, cx + halfSize, cy + halfSize)
        glTexture(false)
    end

    if pingWheelSelection > 0 then
        local mx, my = spGetMouseState()
        local dx, dy = mx - cx, my - cy
        local dist = sqrt(dx * dx + dy * dy)
        if dist > r then
            local nx, ny = dx / dist, dy / dist
            local x0 = cx + r * nx
            local y0 = cy + r * ny
            glColor(1, 1, 1, 0.22)
            glLineWidth(4)
            DrawLine(x0, y0, mx, my)
            glColor(1, 1, 1, 0.7)
            glLineWidth(1.4)
            DrawLine(x0, y0, mx, my)
        end
    end

    for i = 1, n do
        local base0 = (i - 1.5) * 2 * pi / n
        local base1 = (i - 0.5) * 2 * pi / n
        local innerA0 = base0 + sliceGap
        local innerA1 = base1 - sliceGap
        local outerA0 = base0 + outerGap
        local outerA1 = base1 - outerGap
        local selected = (i == pingWheelSelection)
        local fill = selected and wheelBgSel or wheelBg
        glColor(fill)
        DrawAnnulusSlice(cx, cy, innerR, r, innerA0, innerA1, outerA0, outerA1, wedgeSteps)

        local col = pingWheel[i].color or wheelLine
        local accentInner = innerR + (r - innerR) * 0.06
        local accentPad = (innerA1 - innerA0) * 0.06
        local aa0, aa1 = innerA0 + accentPad, innerA1 - accentPad
        DrawThickArc(cx, cy, accentInner, aa0, aa1, wedgeSteps,
            col[1], col[2], col[3], selected and 0.62 or 0.42, selected and 5.2 or 4.6)

        if selected then
            glBlending(GL_SRC_ALPHA, GL_ONE)
            DrawSliceOutline(cx, cy, innerR, r, innerA0, innerA1, outerA0, outerA1, wedgeSteps,
                wheelGlow[1], wheelGlow[2], wheelGlow[3], 0.55)
            glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        end
        DrawSliceOutline(cx, cy, innerR, r, innerA0, innerA1, outerA0, outerA1, wedgeSteps,
            wheelLine[1], wheelLine[2], wheelLine[3], selected and 0.95 or 0.72)
    end

    glColor(wheelHub)
    DrawFilledCircle(cx, cy, hubR * 0.92, 96)
    DrawRing(cx, cy, hubR * 0.92, 96, wheelLine[1], wheelLine[2], wheelLine[3], 0.7)
    local quickHub = (osClock() - mousePressTime) < lookHereMaxHold
    if quickHub then
        glColor(pingLookHere.color)
        DrawFilledCircle(cx, cy, hubR * 0.22, 32)
    else
        local xLen = hubR * 0.34
        DrawThickLine(cx - xLen, cy - xLen, cx + xLen, cy + xLen, wheelX[1], wheelX[2], wheelX[3], 0.88)
        DrawThickLine(cx - xLen, cy + xLen, cx + xLen, cy - xLen, wheelX[1], wheelX[2], wheelX[3], 0.88)
    end

    glBeginText()
    for i = 1, n do
        local opt = pingWheel[i]
        local selected = (i == pingWheelSelection)
        local a = (i - 1) * 2 * pi / n
        local iconR = (innerR + r) * 0.5
        local tx = cx + iconR * sin(a)
        local ty = cy + iconR * cos(a)
        local icon = opt.icon
        if icon then
            local col = opt.color or wheelLine
            local iconCol = { col[1], col[2], col[3], selected and 1 or 0.82 }
            if osClock() < pingMuteUntil and not selected then
                iconCol = pingWheelTextSpamColor
            end
            glColor(iconCol)
            glText(icon, tx, ty, textSize * (selected and 3.55 or 3.15), "cvos")
        end
    end

    local mx, my = spGetMouseState()
    local cursorDist = sqrt((mx - cx) * (mx - cx) + (my - cy) * (my - cy))
    local caption, captionCol
    if osClock() < pingMuteUntil then
        caption = string.format(L.mutedWheel, math.max(1, math.ceil(pingMuteUntil - osClock())))
        captionCol = { 1.00, 0.38, 0.28, 1 }
    elseif pingWheelSelection > 0 then
        local opt = pingWheel[pingWheelSelection]
        caption = opt.label or opt.name
        captionCol = { wheelLine[1], wheelLine[2], wheelLine[3], 1 }
    elseif cursorDist < hubR then
        if (osClock() - mousePressTime) < lookHereMaxHold then
            caption = pingLookHere.label
            captionCol = { (pingLookHere.color or wheelLine)[1], (pingLookHere.color or wheelLine)[2], (pingLookHere.color or wheelLine)[3], 0.95 }
        else
            caption = L.close
            captionCol = { wheelLine[1], wheelLine[2], wheelLine[3], 0.95 }
        end
    end
    if caption then
        glColor(captionCol)
        glText(caption, cx, cy - r - textSize * 2.8, textSize * 2.0, "cvos")
    end
    glEndText()

    glLineWidth(1)
    if gl.Smoothing then
        gl.Smoothing(false, false, false)
    end
    glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
end

local function DrawPingBillboards()
    local now = osClock()
    local cx, cy, cz = spGetCameraPosition()
    glDepthTest(false)
    glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    for i = 1, #activePings do
        local ping = activePings[i]
        local t = (now - ping.t0) / pingFxDuration
        if t >= 0 and t < 1
            and not (Spring.IsSphereInView and not Spring.IsSphereInView(ping.x, ping.y + 40, ping.z, 80))
        then
            local fade = PingFade(t)
            local age = now - ping.t0
            local drop, heightBoost = PingDrop(age)
            local anim = drop * PingPulse(age)
            local dist = sqrt((cx - ping.x) * (cx - ping.x) + (cy - ping.y) * (cy - ping.y) + (cz - ping.z) * (cz - ping.z))
            local scale = math.max(0.7, math.min(2.2, dist / 1400))
            local col = ping.color
            local iconSize = 24 * scale

            glPushMatrix()
            glTranslate(ping.x, ping.y + 40 + heightBoost, ping.z)
            glBillboard()

            glPushMatrix()
            glScale(anim, anim, 1)
            if bgTexture then
                local hs = 38 * scale
                glColor2(col[1], col[2], col[3], fade * 0.38)
                glTexture(bgTexture)
                glTexRect(-hs, -hs, hs, hs)
                glTexture(false)
            end
            if ping.icon then
                glColor2(col[1], col[2], col[3], fade * 0.22)
                DrawFilledCircle(0, 0, iconSize * 1.05, 36)
                glColor2(col[1], col[2], col[3], fade)
                glText(ping.icon, 0, 0, iconSize, "cvos")
            else
                glColor2(col[1], col[2], col[3], fade * 0.35)
                DrawFilledCircle(0, 0, iconSize * 0.85, 32)
                glColor2(col[1], col[2], col[3], fade)
                DrawFilledCircle(0, 0, iconSize * 0.32, 20)
            end
            glPopMatrix()

            DrawPingRipples(iconSize * 1.15, age, fade, col[1], col[2], col[3])
            glPopMatrix()

            glPushMatrix()
            glTranslate(ping.x, ping.y + 40, ping.z)
            glBillboard()
            glColor2(col[1], col[2], col[3], fade * 0.96)
            glText(ping.label, 0, -52, 14, "cvos")
            if ping.playerName ~= "" then
                local pc = ping.playerColor or col
                glColor2(pc[1], pc[2], pc[3], fade * 0.92)
                glText(ping.playerName, 0, -68, 11, "cvos")
            end
            glPopMatrix()
        end
    end

    glColor2(1, 1, 1, 1)
    glDepthTest(true)
end

local function TakeLuaMsg(msg)
    local now = osClock()
    if msg == lastLuaMsg and (now - lastLuaMsgTime) < 0.12 then
        return false
    end
    lastLuaMsg, lastLuaMsgTime = msg, now
    return true
end

function widget:RecvLuaMsg(msg, playerID)
    if type(msg) ~= "string" then
        return
    end
    if msg:sub(1, 5) == "PW1C\t" then
        if playerID ~= myPlayerID and AcceptPingFrom(playerID) and TakeLuaMsg(msg) then
            if (pingRecvMuteUntil[playerID] or 0) <= osClock() then
                ShowSystemLine(msg:sub(6))
            end
        end
        return true
    end
    if msg:sub(1, 4) ~= "PW1\t" then
        return
    end
    if playerID == myPlayerID then
        return
    end
    if not AcceptPingFrom(playerID) then
        return
    end
    if not TakeLuaMsg(msg) then
        return true
    end
    local times = lastPingRecvTimes[playerID]
    if not times then
        times = {}
        lastPingRecvTimes[playerID] = times
    end
    local ok, mute = BurstCheck(times, pingRecvMuteUntil[playerID] or 0)
    pingRecvMuteUntil[playerID] = mute
    if not ok then
        return true
    end
    local key, xs, ys, zs = msg:match("^PW1\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if not key then
        return
    end
    local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
    if not x or not y or not z then
        return
    end
    SpawnPing(playerID, pingDefs[key] or { name = key, label = key, icon = "!", color = pingWheelColor }, x, y, z)
    return true
end

function widget:MapDrawCmd(playerID, cmdType, px, py, pz, label)
    if not replace_default_ping or cmdType ~= "point" then
        return
    end
    if not AcceptPingFrom(playerID) then
        return
    end
    local key = StripColorCodes(label or "")
    if pingDefs[key] or IsRecentPingPos(px, pz) then
        return true
    end
end

function widget:DrawWorld()
    if #activePings == 0 then
        return
    end
    if spIsGUIHidden and spIsGUIHidden() then
        return
    end
    DrawPingBillboards()
end

function widget:DrawInMiniMap(sx, sy)
    if #activePings == 0 or not sx or not sy or sx < 8 or sy < 8 then
        return
    end
    mapSizeX = (Game and Game.mapSizeX) or mapSizeX
    mapSizeZ = (Game and Game.mapSizeZ) or mapSizeZ
    local now = osClock()
    glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    for i = 1, #activePings do
        local ping = activePings[i]
        local t = (now - ping.t0) / pingFxDuration
        if t >= 0 and t < 1 then
            local fade = PingFade(t)
            local mx, my = WorldToMini(ping.x, ping.z, sx, sy)
            local col = ping.color

            if ping.icon then
                local age = now - ping.t0
                local anim = PingDrop(age, pingFxMinimapDropStart) * PingPulse(age)
                glPushMatrix()
                glTranslate(mx, my, 0)
                glScale(anim, anim, 1)
                glColor2(col[1], col[2], col[3], fade * 0.22)
                DrawFilledCircle(0, 0, pingFxMinimapIcon * 1.05, 32)
                glColor2(col[1], col[2], col[3], fade)
                glText(ping.icon, 0, 0, pingFxMinimapIcon, "cvos")
                glPopMatrix()
                glPushMatrix()
                glTranslate(mx, my, 0)
                DrawPingRipples(pingFxMinimapIcon * 1.15, age, fade, col[1], col[2], col[3])
                glPopMatrix()
            else
                local age = now - ping.t0
                local anim = PingDrop(age, pingFxMinimapDropStart) * PingPulse(age)
                local coreR = pingFxMinimapSize * 0.75
                glPushMatrix()
                glTranslate(mx, my, 0)
                glScale(anim, anim, 1)
                glColor2(col[1], col[2], col[3], fade * 0.9)
                DrawFilledCircle(0, 0, coreR, 20)
                glColor2(1, 1, 1, fade * 0.92)
                DrawFilledCircle(0, 0, coreR * 0.38, 14)
                glPopMatrix()
                glPushMatrix()
                glTranslate(mx, my, 0)
                DrawPingRipples(pingFxMinimapIcon * 1.15, age, fade, col[1], col[2], col[3])
                glPopMatrix()
            end
        end
    end

    glColor2(1, 1, 1, 1)
    glLineWidth(1)
end

local function DrawWheelOverlay()
    glPushMatrix()
    if keyDown and not displayPingWheel then
        local mx, my = spGetMouseState()
        glColor2(pingWheelColor)
        glPointSize(centerDotSize)
        glBeginEnd(GL_POINTS, glVertex, mx, my)
        glColor2(1, 1, 1, 1)
        if enable_ping_messages then
            glText(L.hintMsgs, mx + 15, my + 11, 12, "os")
        end
        glText(L.hintCmds, mx - 15, my + 11, 12, "ros")
    end
    if displayPingWheel and pingWheelScreenLocation then
        DrawWheel(pingWheelScreenLocation.x, pingWheelScreenLocation.y)
    end
    glPopMatrix()
end

-- BAR DrawScreen iterates reverse (low layer last = on top), so the minimap
-- (layer 0) would cover this widget (layer 999). DrawScreenPost is after that.
function widget:DrawScreenPost()
    DrawWheelOverlay()
end
