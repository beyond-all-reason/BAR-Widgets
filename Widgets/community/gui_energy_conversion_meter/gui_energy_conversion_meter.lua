local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Energy Conversion Meter",
        desc = "9-bar meter next to the top bar showing your energy<->converter balance: green center = balanced, bars ramp yellow -> red as the imbalance grows. Right = energy going unconverted (OVERFLOWING), left = converter capacity starved (IDLE CONVERTERS). Severity is relative to your E income; shows the E/s value and a hint label. Energy/converters actively under construction already count as fixed (blueprints don't). Holding 3+ bars for ~5s pops an on-screen alert; pinned at 4 bars it repeats every 20s and the side icon + label pulse red. Ctrl + left-click drag repositions the meter (saved).",
        author = "Egzothicki",
        date = "July 2026",
        license = "GNU GPL, v2 or later",
        layer = 100,
        enabled = true,
    }
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local SIZE_FRAC = 0.98 -- meter height as fraction of top bar height
local ANCHOR_MARGIN = 12 -- default-position gap after the top bar's last element

local CONV_EXCESS_MIN = 70 -- E/s of net income before the excess side shows
local CONV_DEFICIT_MIN = 70 -- E/s of idle capacity before the deficit side shows
-- meter severity is RELATIVE to current E income (3k excess on 5k income = huge,
-- on 100k income = mild). Level 1 = any qualifying amount, then:
local CONV_RATIO_TIERS = { 0.10, 0.30, 0.60 } -- value/income fractions for levels 2..4
-- ...but a huge ABSOLUTE amount is severe even on a huge income (120k excess on
-- 400k income is 20 epic converters, not "2 bars") — level is the max of both.
-- Floors are per-side, equalized by METAL COST TO FIX (~4k/10k/19k M): fixing
-- 1 E/s of deficit with afus (9700M/3000E) costs ~5x more than with adv
-- converters (380M/600E), so the deficit floors are ~5x lower:
local CONV_ABS_TIERS_EXCESS = { 6000, 15000, 30000 } -- E/s floors, levels 2..4
local CONV_ABS_TIERS_DEFICIT = { 1200, 3000, 6000 }
local CONV_ALPHA = 0.22 -- EMA weight per 0.5s poll (~2s time constant)
local CONV_STABLE_TICKS = 3 -- polls a mode must hold before the display switches
-- Colors: the meter shows IMBALANCE, not sides — green center = balanced, then
-- a traffic-light ramp outward on BOTH sides. Which side tells you WHAT to add
-- (direction, end icons, text); color only tells you HOW BAD.
local CONV_OK_COLOR = { 0.35, 1.0, 0.45 } -- center bar while balanced
local CONV_BAR_COLORS = { -- by bar position 1..4, either side
    { 1.0, 0.85, 0.15 }, -- 1: yellow
    { 1.0, 0.60, 0.10 }, -- 2: orange
    { 1.0, 0.33, 0.08 }, -- 3: orange-red (alert territory starts here)
    { 1.0, 0.12, 0.08 }, -- 4: red
}
-- Sustained-severity notifications: the meter can bounce even -4 -> +4 during
-- building bursts, so a level only alerts after it HOLDS. |level| >= 3 held for
-- CONV_NOTIF_SUSTAIN fires one notification per episode (re-arms once it drops
-- below 3); |level| = 4 held fires a stronger pulsing one that repeats every
-- CONV_NOTIF4_REPEAT while it stays pinned. A side flip resets the timers.
local CONV_NOTIF_SUSTAIN = 4.5 -- seconds a level must hold before it alerts
local CONV_NOTIF4_REPEAT = 20 -- seconds between repeats while pinned at 4
local CONV_NOTIF_COOLDOWN = 30 -- min seconds between level-3 alerts (2<->3 bounce guard)
local CONV_NOTIF_SECONDS = 4 -- level-3 notification hold time
local CONV_NOTIF4_SECONDS = 6 -- level-4 notification hold time
-- an eco construction still counts as "being built" this many seconds after its
-- last build progress (rides builder swaps / short stalls); an untouched
-- blueprint never gets progress, so it never counts
local BUILD_ACTIVE_GRACE = 3

--------------------------------------------------------------------------------
local glColor = gl.Color
local glRect = gl.Rect
local glText = gl.Text
local glTexture = gl.Texture
local glTexRect = gl.TexRect

local vsx, vsy = 1920, 1080
local convText, convColor = nil, CONV_BAR_COLORS[1] -- value line ("+3k")
local convAction = nil -- action line below, smaller ("OVERFLOWING"/"IDLE CONVERTERS")
local convLevel = 0 -- meter position: -4 (converters starved) .. +4 (energy unconverted)
local convPos = { x = -9999, y = 0, s = 34, w = 0 }
local convDrag = nil -- {grabDX, grabDY} while the meter is being Ctrl-dragged
local convUserPos = nil -- {xFrac, yFrac} user-chosen position (screen fractions, saved); nil = auto
local emaInc, emaExp, emaUse
local convMode, convCandidate, convTicks = nil, nil, 0
local sinceRefresh = 1
local convNotifText, convNotifUntil, convNotifStrong, convNotifColor = nil, 0, false, nil
local conv3Since, conv4Since = nil, nil -- os.clock() when |level| continuously reached 3 / 4
local convSide = 0 -- sign of the level the sustain timers are tracking
local conv3Fired = false -- level-3 alert already fired this episode
local conv3LastAt, conv4LastAt = -999, -999
-- bar-4 pulse for the pinned side's icon + the action label: same blink shape as
-- gui_top_bar's overflow flash (fast dt*9 attack, eased ~0.75s decay, ~0.86s/cycle)
local convBlink, convBlinkDir = 0, true

-- end-cap icons: wind (energy) on the IDLE CONVERTERS side, converter on the
-- OVERFLOWING side — engine MAP ICONS (white shapes), with buildpic fallback if
-- the icontypes lookup fails
local convEnergyIcon, convMakerIcon
do
    local ok, iconTypes = pcall(VFS.Include, "gamedata/icontypes.lua")
    local function iconOf(name)
        local ud = UnitDefNames[name]
        if not ud then return nil end
        local it = ok and iconTypes and ud.iconType and iconTypes[ud.iconType]
        return (it and it.bitmap and (":l:" .. it.bitmap)) or ("#" .. ud.id)
    end
    convEnergyIcon = iconOf("armwin") or iconOf("corwin")
    convMakerIcon = iconOf("armmakr") or iconOf("cormakr")
end

-- eco under construction: if the user is already ACTIVELY building energy (or
-- converters), don't nag them to add more — the finished output of actively-
-- built sites is deducted from the deficit (or excess) before the meter/alerts
-- see it. "Actively" = build progress advanced within BUILD_ACTIVE_GRACE; a
-- placed-but-untouched blueprint never counts.
local convCapOf = {} -- unitDefID -> converter capacity once finished
local energyOutOf = {} -- unitDefID -> E/s once finished (immobile producers)
local ecoDefIDList = {} -- both of the above, for GetTeamUnitsByDefs
local buildTrack = {} -- under-construction eco unitID -> { p = progress, at = last progress time }

local function BuildEcoDefs()
    local avgWind = ((Game.windMin or 0) + (Game.windMax or 0)) * 0.5
    local tidal = Game.tidal or 0
    for udid, ud in pairs(UnitDefs) do
        local cp = ud.customParams
        local cap = cp and tonumber(cp.energyconv_capacity)
        if cap and cap > 0 then
            convCapOf[udid] = cap
            ecoDefIDList[#ecoDefIDList + 1] = udid
        elseif ud.isImmobile then
            -- solars produce via NEGATIVE energyUpkeep (so they can be toggled off)
            local e = (ud.energyMake or 0) + math.max(0, -(ud.energyUpkeep or 0))
            if (ud.windGenerator or 0) > 0 then
                e = e + math.min(avgWind, ud.windGenerator)
            end
            e = e + (ud.tidalGenerator or 0) * tidal
            if e >= 15 then
                energyOutOf[udid] = e
                ecoDefIDList[#ecoDefIDList + 1] = udid
            end
        end
    end
end

-- finished E/s + converter capacity of eco sites actively being built
local function PendingEcoRates()
    local now = os.clock()
    local pendE, pendCap = 0, 0
    local units = Spring.GetTeamUnitsByDefs(Spring.GetMyTeamID(), ecoDefIDList)
    local seen = {}
    for i = 1, #units do
        local uid = units[i]
        if Spring.GetUnitIsBeingBuilt(uid) then
            seen[uid] = true
            local progress = select(5, Spring.GetUnitHealth(uid)) or 0
            local tr = buildTrack[uid]
            if not tr then
                tr = { p = progress, at = -999 }
                buildTrack[uid] = tr
            elseif progress > tr.p + 1e-4 then
                tr.p = progress
                tr.at = now
            end
            if now - tr.at <= BUILD_ACTIVE_GRACE then
                local did = Spring.GetUnitDefID(uid)
                pendE = pendE + (energyOutOf[did] or 0)
                pendCap = pendCap + (convCapOf[did] or 0)
            end
        end
    end
    for uid in pairs(buildTrack) do
        if not seen[uid] then buildTrack[uid] = nil end
    end
    return pendE, pendCap
end

local function FormatE(v)
    if string.formatSI then return string.formatSI(math.floor(v)) end
    return v >= 1000 and string.format("%.1fk", v / 1000) or tostring(math.floor(v))
end

local function TierLevel(v, income, absTiers)
    local ratio = v / math.max(income or 0, 1)
    local lvl = 1 -- reaching the meter at all = at least mild
    for i = 1, #CONV_RATIO_TIERS do
        if ratio >= CONV_RATIO_TIERS[i] then lvl = i + 1 end
    end
    for i = 1, #absTiers do
        if v >= absTiers[i] and (i + 1) > lvl then lvl = i + 1 end
    end
    return lvl
end

local function UpdateConversionInfo()
    local teamID = Spring.GetMyTeamID()
    local _, _, _, eInc, eExp = Spring.GetTeamResources(teamID, "energy")
    if not eInc then
        convText, convAction, convLevel = nil, nil, 0
        return
    end
    -- mmUse/mmCapacity: set by the game's energy conversion gadget (same source
    -- the top bar uses) — actual converted E/s and total converter capacity
    local mmUse = Spring.GetTeamRulesParam(teamID, "mmUse") or 0
    local mmCap = Spring.GetTeamRulesParam(teamID, "mmCapacity") or 0
    emaInc = emaInc and (emaInc + CONV_ALPHA * (eInc - emaInc)) or eInc
    emaExp = emaExp and (emaExp + CONV_ALPHA * (eExp - emaExp)) or eExp
    emaUse = emaUse and (emaUse + CONV_ALPHA * (mmUse - emaUse)) or mmUse

    local net = emaInc - emaExp
    local idle = mmCap - emaUse
    -- eco already being built counts as handled: actively-built converters will
    -- absorb the excess, actively-built energy will feed the idle converters
    local pendE, pendCap = PendingEcoRates()
    net = net - pendCap
    idle = idle - pendE
    -- excess only counts when existing converters are already ~saturated (else the
    -- conversion gadget will absorb it by itself once storage passes the slider level);
    -- expense already includes conversion drain, so positive net = true overflow
    local mode
    if net >= CONV_EXCESS_MIN and (mmCap <= 0 or emaUse >= 0.9 * mmCap) then
        mode = "excess"
    elseif idle >= CONV_DEFICIT_MIN then
        mode = "deficit"
    end

    -- mode hysteresis: hold CONV_STABLE_TICKS polls before the display flips
    if mode ~= convCandidate then
        convCandidate, convTicks = mode, 1
    else
        convTicks = convTicks + 1
    end
    if convTicks >= CONV_STABLE_TICKS then
        convMode = mode
    end

    if convMode == nil or convMode ~= mode then
        if convMode == nil then
            convText, convAction, convLevel = nil, nil, 0
        end
        return -- keep last display while a flip is pending
    end

    if convMode == "excess" then
        convText = "+" .. FormatE(net)
        convAction = "OVERFLOWING"
        convLevel = TierLevel(net, emaInc, CONV_ABS_TIERS_EXCESS)
        convColor = CONV_BAR_COLORS[convLevel]
    else
        convText = "-" .. FormatE(idle)
        convAction = "IDLE CONVERTERS"
        convLevel = -TierLevel(idle, emaInc, CONV_ABS_TIERS_DEFICIT)
        convColor = CONV_BAR_COLORS[-convLevel]
    end
end

-- runs on the same 0.5s poll as UpdateConversionInfo, on the DISPLAYED level
-- (post-EMA, post-hysteresis) — what the user sees is what gets timed
local function UpdateConvNotify()
    local now = os.clock()
    local side = (convLevel > 0 and 1) or (convLevel < 0 and -1) or 0
    if side ~= convSide or math.abs(convLevel) < 3 then
        conv3Since, conv4Since, conv3Fired = nil, nil, false
        convSide = side
        return
    end
    conv3Since = conv3Since or now
    if math.abs(convLevel) >= 4 then
        conv4Since = conv4Since or now
    else
        conv4Since = nil
    end

    local excess = side > 0
    if conv4Since and (now - conv4Since) >= CONV_NOTIF_SUSTAIN
        and (now - conv4LastAt) >= CONV_NOTIF4_REPEAT then
        conv4LastAt = now
        conv3Fired = true -- the strong alert covers the mild one
        convNotifText = (convText and (convText .. "  ") or "")
            .. (excess and "OVERFLOWING" or "IDLE CONVERTERS")
        convNotifStrong = true
        convNotifUntil = now + CONV_NOTIF4_SECONDS
        convNotifColor = convColor
        Spring.PlaySoundFile("beep4", 0.75, "ui")
    elseif not conv3Fired and (now - conv3Since) >= CONV_NOTIF_SUSTAIN
        and (now - conv3LastAt) >= CONV_NOTIF_COOLDOWN then
        conv3Fired = true
        conv3LastAt = now
        convNotifText = (convText and (convText .. "  ") or "")
            .. (excess and "OVERFLOWING" or "IDLE CONVERTERS")
        convNotifStrong = false
        convNotifUntil = now + CONV_NOTIF_SECONDS
        convNotifColor = convColor
        Spring.PlaySoundFile("beep4", 0.35, "ui")
    end
end

local function UpdatePos()
    local tb = WG['topbar'] and WG['topbar'].GetPosition and WG['topbar'].GetPosition()
    local free = WG['topbar'] and WG['topbar'].GetFreeArea and WG['topbar'].GetFreeArea()
    if tb and free then
        local h = vsy - tb[2]
        convPos.s = math.floor(h * SIZE_FRAC)
        convPos.y = math.floor(tb[2] + (h - convPos.s) * 0.5)
        -- anchor after the LAST thing that actually draws in the bar's free-area
        -- tail: the stock Converter Usage box (it publishes its rect; zero rect
        -- while hidden = no converters yet)
        local baseX = free[1]
        local cu = WG['converter_usage'] and WG['converter_usage'].GetPosition and WG['converter_usage'].GetPosition()
        if cu and cu[3] and cu[3] > baseX then
            baseX = cu[3]
        end
        convPos.x = math.floor(baseX + ANCHOR_MARGIN)
    else
        convPos.s = math.floor(34 * math.max(0.7, vsy / 1080))
        convPos.y = vsy - convPos.s - 4
        convPos.x = math.floor(vsx * 0.72)
    end

    -- user-dragged position override (Ctrl+drag), stored as screen fractions
    if convUserPos then
        local w = convPos.w > 0 and convPos.w or 200
        convPos.x = math.floor(math.max(0, math.min(convUserPos[1] * vsx, vsx - w)))
        convPos.y = math.floor(math.max(0, math.min(convUserPos[2] * vsy, vsy - convPos.s)))
    end
end

function widget:ViewResize(x, y)
    vsx, vsy = x, y
    UpdatePos()
end

function widget:Initialize()
    BuildEcoDefs()
    local x, y = Spring.GetViewGeometry()
    widget:ViewResize(x, y)
    UpdateConversionInfo()
end

function widget:PlayerChanged()
    emaInc, emaExp, emaUse = nil, nil, nil
    convMode, convCandidate, convTicks = nil, nil, 0
    convText, convAction, convLevel = nil, nil, 0
    convNotifText, conv3Since, conv4Since, convSide, conv3Fired = nil, nil, nil, 0, false
    buildTrack = {}
end

function widget:Update(dt)
    sinceRefresh = sinceRefresh + dt
    if sinceRefresh > 0.5 then
        sinceRefresh = 0
        UpdateConversionInfo()
        UpdateConvNotify()
    end

    -- drive the bar-4 red pulse (blink shape copied from gui_top_bar)
    if convLevel >= 4 or convLevel <= -4 then
        if convBlinkDir then
            convBlink = convBlink + (dt * 9)
            if convBlink > 1 then
                convBlink = 1
                convBlinkDir = false
            end
        else
            convBlink = convBlink - (dt / (convBlink * 1.5))
            if convBlink < 0 then
                convBlink = 0
                convBlinkDir = true
            end
        end
    elseif convBlink ~= 0 then
        convBlink, convBlinkDir = 0, true -- re-arm so each episode opens with the attack ramp
    end
end

local CONV_TIP_TITLE = "Energy Conversion Meter"
local function ConvTooltipText()
    return "Shows you how much out of balance you are for Energy production"
        .. " and Energy Conversion (Overflowing vs Idle Converters)"
end

function widget:DrawScreen()
    if Spring.IsGUIHidden() then return end
    UpdatePos()

    -- 9 vertical bars, -4 (left: converters starved) .. 0 (center, green when
    -- balanced) .. +4 (right: energy going unconverted), traffic-light severity
    -- ramp, on a FlowUI panel
    local s = convPos.s
    local barW = math.max(3, math.floor(s * 0.11))
    local barGap = math.max(2, math.floor(s * 0.055))
    local pad = math.max(3, math.floor(s * 0.16))
    local totalW = 9 * barW + 8 * barGap
    local fs = s * 0.34
    local fs2 = s * 0.26
    local textGap = math.floor(s * 0.22)
    local textW = convText and math.ceil((gl.GetTextWidth(convText) or 0) * fs) or 0
    local actionW = convAction and math.ceil((gl.GetTextWidth(convAction) or 0) * fs2) or 0
    local iconS = math.floor(s * 0.46)
    local iconGap = math.max(2, math.floor(s * 0.06))
    local iconsW = (convEnergyIcon and (iconS + iconGap) or 0) + (convMakerIcon and (iconS + iconGap) or 0)
    local rowW = iconsW + totalW + (convText and (textGap + textW) or 0)
    local panelW = pad + math.max(rowW, actionW) + pad
    local x1, y1 = convPos.x, convPos.y
    local fui = WG.FlowUI and WG.FlowUI.Draw
    if fui and fui.RectRound then
        fui.RectRound(x1, y1, x1 + panelW, y1 + s, math.floor(s * 0.16), 1, 1, 1, 1,
            { 0, 0, 0, 0.62 }, { 0.14, 0.14, 0.14, 0.62 })
    else
        glColor(0, 0, 0, 0.55)
        glRect(x1, y1, x1 + panelW, y1 + s)
    end
    -- top line: [E icon] bars [conv icon] + value; bottom line: action, smaller
    local cyMid = convAction and (y1 + s * 0.66) or (y1 + s * 0.5)
    local barMult = convAction and 0.78 or 1
    local barsX = x1 + pad + (convEnergyIcon and (iconS + iconGap) or 0)
    for i = -4, 4 do
        local bx = barsX + (i + 4) * (barW + barGap)
        local bh = barMult * s * (0.18 + 0.085 * math.abs(i))
        local filled = (convLevel > 0 and i > 0 and i <= convLevel)
            or (convLevel < 0 and i < 0 and i >= convLevel)
        if i == 0 then
            if convLevel == 0 then
                glColor(CONV_OK_COLOR[1], CONV_OK_COLOR[2], CONV_OK_COLOR[3], 0.9)
            else
                glColor(0.85, 0.85, 0.85, 0.45)
            end
        elseif filled then
            local c = CONV_BAR_COLORS[math.abs(i)] -- severity ramp
            glColor(c[1], c[2], c[3], 0.95)
        else
            glColor(0.55, 0.55, 0.55, 0.25)
        end
        glRect(bx, cyMid - bh * 0.5, bx + barW, cyMid + bh * 0.5)
    end
    if convEnergyIcon then
        if convLevel <= -4 then
            glColor(1, 0.16, 0.12, 0.35 + 0.65 * convBlink) -- bar 4 hit: pulsing red
        else
            glColor(0.85, 0.85, 0.85, 0.9) -- neutral: color means severity only
        end
        glTexture(convEnergyIcon)
        glTexRect(x1 + pad, cyMid - iconS * 0.5, x1 + pad + iconS, cyMid + iconS * 0.5)
        glTexture(false)
    end
    if convMakerIcon then
        if convLevel >= 4 then
            glColor(1, 0.16, 0.12, 0.35 + 0.65 * convBlink) -- bar 4 hit: pulsing red
        else
            glColor(0.85, 0.85, 0.85, 0.9) -- neutral: color means severity only
        end
        glTexture(convMakerIcon)
        local ix = barsX + totalW + iconGap
        glTexRect(ix, cyMid - iconS * 0.5, ix + iconS, cyMid + iconS * 0.5)
        glTexture(false)
    end
    if convText then
        glColor(convColor[1], convColor[2], convColor[3], 0.95)
        local textX = barsX + totalW + (convMakerIcon and (iconGap + iconS) or 0) + textGap
        glText(convText, textX, cyMid - fs * 0.36, fs, "o")
    end
    if convAction then
        local a = 0.9
        if convLevel >= 4 or convLevel <= -4 then
            a = 0.35 + 0.65 * convBlink -- bar 4 hit: pulse with the icon
        end
        glColor(convColor[1], convColor[2], convColor[3], a)
        glText(convAction, x1 + panelW * 0.5, y1 + s * 0.06, fs2, "oc")
    end
    convPos.w = panelW

    -- hover tooltip goes through BAR's tooltip widget (the engine GetTooltip
    -- callin is not rendered as a cursor tooltip); area refreshed every frame
    if WG['tooltip'] and WG['tooltip'].AddTooltip and convPos.w > 0 then
        WG['tooltip'].AddTooltip('energyconvmeter',
            { convPos.x, convPos.y, convPos.x + convPos.w, convPos.y + convPos.s },
            ConvTooltipText(), nil, CONV_TIP_TITLE)
    end

    -- sustained-severity notification, side-colored, upper-center;
    -- level 4 = bigger and pulsing, level 3 = steady and smaller
    if convNotifText and os.clock() < convNotifUntil then
        local c = convNotifColor or CONV_BAR_COLORS[4]
        local a = 0.9
        if convNotifStrong then
            local pulse = 0.5 + 0.5 * math.sin(os.clock() * 2 * math.pi * 1.6)
            a = 0.55 + 0.45 * pulse
        end
        local nscale = math.max(0.7, vsy / 1080)
        glColor(c[1], c[2], c[3], a)
        glText(convNotifText, vsx * 0.5, vsy * 0.74,
            math.floor((convNotifStrong and 26 or 19) * nscale), "oc")
    end
    glColor(1, 1, 1, 1)
end

function widget:IsAbove(mx, my)
    -- tooltip + Ctrl-drag; plain clicks still pass through (MousePress only
    -- grabs the panel when Ctrl is held)
    return convPos.w > 0 and mx >= convPos.x and mx <= convPos.x + convPos.w
        and my >= convPos.y and my <= convPos.y + convPos.s
end

function widget:MousePress(mx, my, button)
    if button ~= 1 or Spring.IsGUIHidden() then return false end
    if self:IsAbove(mx, my) then
        local _, ctrl = Spring.GetModKeyState()
        if ctrl then
            convDrag = { mx - convPos.x, my - convPos.y }
            return true
        end
    end
    return false
end

function widget:MouseMove(mx, my)
    if convDrag then
        convUserPos = { (mx - convDrag[1]) / vsx, (my - convDrag[2]) / vsy }
        return true
    end
end

function widget:MouseRelease(mx, my, button)
    if convDrag then
        convDrag = nil
    end
    return false
end

function widget:GetConfigData()
    return { convUserPos = convUserPos }
end

function widget:SetConfigData(data)
    if data and type(data.convUserPos) == "table" and tonumber(data.convUserPos[1]) and tonumber(data.convUserPos[2]) then
        convUserPos = { data.convUserPos[1], data.convUserPos[2] }
    end
end

function widget:GetTooltip(mx, my)
    if self:IsAbove(mx, my) then
        return CONV_TIP_TITLE .. "\n" .. ConvTooltipText()
    end
    return nil
end

function widget:Shutdown()
    if WG['tooltip'] and WG['tooltip'].RemoveTooltip then
        WG['tooltip'].RemoveTooltip('energyconvmeter')
    end
end
