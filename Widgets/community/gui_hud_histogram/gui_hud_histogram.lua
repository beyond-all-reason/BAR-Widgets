-- ffa_timeseries_hud.lua
-- Beyond All Reason — Spectator FFA time-series line chart HUD
-- Tracks ALL active players. Plots top 5 by AV. Catmull-Rom smooth curves.
-- 6 panels (M/s, E/s, BP, MP, AV, DV), last 10 minutes, x-axis = game minutes.
-- Place in: Beyond All Reason/LuaUI/Widgets/

function widget:GetInfo()
    return {
        name    = "FFA Timeseries HUD",
        desc    = "Spectator smooth line chart — top 5 of all FFA players, 6 metrics, 10 min",
        author  = "goddot",
        date    = "2026",
        license = "GNU GPL v2",
        layer   = 0,
        enabled = true,
    }
end

-- ─── Config ───────────────────────────────────────────────────────────────────

local CFG = {
    px             = 0,
    py             = 0,
    w              = 560,
    h              = 340,
    padL           = 36,
    padR           = 10,
    padT           = 12,
    padB           = 28,
    panelGap       = 6,
    panelRows      = 2,
    panelCols      = 3,
    historyMins    = 10,
    maxPlayers     = 5,
    bgAlpha        = 0.84,
    lineAlpha      = 0.90,
    fontSize       = 10,
    labelFs        = 9,
    scaleFs        = 8,
    updateInterval = 5.0,
    curveSegs      = 12,   -- subdivisions per segment for Catmull-Rom
}

local FRAMES_PER_MIN = 30 * 60

-- ─── Metrics ──────────────────────────────────────────────────────────────────

local METRICS = {
    { label = "M/s", key = "metalIncome"  },
    { label = "E/s", key = "energyIncome" },
    { label = "BP",  key = "bp"           },
    { label = "MP",  key = "metalStored"  },
    { label = "AV",  key = "armyValue"    },
    { label = "DV",  key = "defValue"     },
}
local NUM_METRICS = #METRICS

-- ─── Player colours ───────────────────────────────────────────────────────────

local PLAYER_COLORS = {
    { 0.25, 0.50, 1.00 },
    { 0.15, 0.85, 0.75 },
    { 0.80, 0.30, 0.90 },
    { 0.90, 0.75, 0.10 },
    { 0.95, 0.20, 0.20 },
}

-- ─── Spring API locals ────────────────────────────────────────────────────────

local spGetAllUnits      = Spring.GetAllUnits
local spGetUnitDefID     = Spring.GetUnitDefID
local spGetUnitTeam      = Spring.GetUnitTeam
local spGetUnitHealth    = Spring.GetUnitHealth
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamList      = Spring.GetTeamList
local spGetPlayerList    = Spring.GetPlayerList
local spGetPlayerInfo    = Spring.GetPlayerInfo
local spGetTeamInfo      = Spring.GetTeamInfo
local spGetGameFrame     = Spring.GetGameFrame

local glColor       = gl.Color
local glVertex      = gl.Vertex
local glBeginEnd    = gl.BeginEnd
local glText        = gl.Text
local glRect        = gl.Rect
local GL_LINE_LOOP  = GL.LINE_LOOP
local GL_LINES      = GL.LINES
local GL_LINE_STRIP = GL.LINE_STRIP

local mfloor = math.floor
local mmax   = math.max
local mmin   = math.min
local mpi    = math.pi
local mcos   = math.cos
local msin   = math.sin

-- ─── Unit def cache ───────────────────────────────────────────────────────────

local udCache = {}

local function classifyUnitDefs()
    for udid, ud in pairs(UnitDefs) do
        local cost = ud.metalCost or 0
        local isBP, isArmy, isDef = false, false, false
        local bp = 0
        if ud.buildSpeed and ud.buildSpeed > 0 then isBP = true; bp = ud.buildSpeed end
        local canAttack = ud.weapons and #ud.weapons > 0
        local isStatic  = (not ud.canMove) or (ud.speed == 0)
        if canAttack and isStatic and not isBP then isDef = true end
        if canAttack and ud.canMove and ud.speed and ud.speed > 0 then isArmy = true end
        if cost > 0 and (isBP or isArmy or isDef) then
            udCache[udid] = { cost=cost, isBP=isBP, isArmy=isArmy, isDef=isDef, bp=bp }
        end
    end
end

-- ─── State ────────────────────────────────────────────────────────────────────

local screenW = 1280
local screenH = 768
local timer   = 0

-- allPlayers: keyed by teamID — tracks every non-dead player across the whole game
-- allPlayers[tid] = { teamID, name, color, history={[min]=snap}, minutes={} }
local allPlayers = {}

-- top5: ordered list of up to 5 player entries (references into allPlayers)
-- rebuilt each refresh by sorting on current AV
local top5 = {}

-- Per-panel y-axis max (only over top5 history to keep scale relevant)
local panelMax = {}
for i = 1, NUM_METRICS do panelMax[i] = 1 end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function currentMinute()
    return mfloor((spGetGameFrame and spGetGameFrame() or 0) / FRAMES_PER_MIN)
end

local function fmtVal(v)
    if v >= 10000 then return string.format("%.0fk", v/1000)
    elseif v >= 1000 then return string.format("%.1fk", v/1000)
    elseif v >= 10   then return string.format("%.0f",  v)
    else                  return string.format("%.1f",  v) end
end

-- ─── Roster: sync allPlayers with current live teams ─────────────────────────

local function syncRoster()
    local teams = spGetTeamList()
    if not teams then return end
    for _, tid in ipairs(teams) do
        local tInfo  = { spGetTeamInfo(tid) }
        local isDead = tInfo and tInfo[3]
        if not isDead and not allPlayers[tid] then
            local name    = "Team " .. tid
            local players = spGetPlayerList(tid, false) or {}
            if #players > 0 then
                local n = spGetPlayerInfo(players[1], false)
                if n then name = n end
            end
            local r, g, b  = Spring.GetTeamColor(tid)
            local colorIdx = 0
            for _ in pairs(allPlayers) do colorIdx = colorIdx + 1 end
            local col = (r and g and b)
                and { r, g, b }
                or  PLAYER_COLORS[(colorIdx % #PLAYER_COLORS) + 1]
            allPlayers[tid] = {
                teamID  = tid,
                name    = name,
                color   = col,
                history = {},
                minutes = {},
            }
        end
    end
end

-- ─── Single-pass unit scan: returns per-team bp/army/def ─────────────────────

local function scanUnits()
    local bp   = {}
    local army = {}
    local def  = {}
    local units = spGetAllUnits()
    for i = 1, #units do
        local uid  = units[i]
        local tid  = spGetUnitTeam(uid)
        local info = udCache[spGetUnitDefID(uid)]
        if info then
            local hp, maxHp = spGetUnitHealth(uid)
            local frac = (hp and maxHp and maxHp > 0) and (hp / maxHp) or 1.0
            if info.isBP   then bp[tid]   = (bp[tid]   or 0) + info.bp end
            if info.isArmy then army[tid] = (army[tid] or 0) + mfloor(info.cost * frac) end
            if info.isDef  then def[tid]  = (def[tid]  or 0) + mfloor(info.cost * frac) end
        end
    end
    return bp, army, def
end

-- ─── Snapshot all players in one pass, store into history ────────────────────

local function appendHistory(p, snap, minute)
    local cutoff = minute - CFG.historyMins
    -- Overwrite or add this minute's entry
    p.history[minute] = snap
    -- Rebuild minutes list: insert if not present, always sorted ascending
    local found = false
    for _, m in ipairs(p.minutes) do
        if m == minute then found = true; break end
    end
    if not found then
        p.minutes[#p.minutes + 1] = minute
        table.sort(p.minutes)
    end
    -- Prune old entries
    local kept = {}
    for _, m in ipairs(p.minutes) do
        if m >= cutoff then kept[#kept + 1] = m
        else p.history[m] = nil end
    end
    p.minutes = kept
end

local function snapshotAll(bpMap, armyMap, defMap, minute)
    for tid, p in pairs(allPlayers) do
        local mCur, _, _, mInc = spGetTeamResources(tid, "metal")
        local _,   _, _, eInc  = spGetTeamResources(tid, "energy")
        local snap = {
            metalIncome  = mfloor((mInc or 0) * 10) / 10,
            energyIncome = mfloor((eInc or 0) * 10) / 10,
            bp           = mfloor(bpMap[tid]   or 0),
            metalStored  = mfloor(mCur         or 0),
            armyValue    = armyMap[tid]         or 0,
            defValue     = defMap[tid]          or 0,
        }
        appendHistory(p, snap, minute)
    end
end

-- ─── Pick top 5 by current AV and recompute panelMax ─────────────────────────

local function pickTop5AndMaxima(minute)
    -- Collect all players that have a snapshot for the current minute
    local candidates = {}
    for tid, p in pairs(allPlayers) do
        local snap = p.history[minute]
        local av   = snap and snap.armyValue or 0
        candidates[#candidates + 1] = { p = p, av = av }
    end
    table.sort(candidates, function(a, b) return a.av > b.av end)

    top5 = {}
    for i = 1, mmin(CFG.maxPlayers, #candidates) do
        top5[i] = candidates[i].p
    end

    -- Recompute panelMax over top5 history only
    for mi, metric in ipairs(METRICS) do
        local mx = 1
        for _, p in ipairs(top5) do
            for _, m in ipairs(p.minutes) do
                local snap = p.history[m]
                if snap then
                    local v = snap[metric.key] or 0
                    if v > mx then mx = v end
                end
            end
        end
        panelMax[mi] = mx
    end
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

local function refreshData()
    syncRoster()
    if not next(allPlayers) then return end
    local bp, army, def = scanUnits()
    local minute = currentMinute()
    snapshotAll(bp, army, def, minute)
    pickTop5AndMaxima(minute)
end

-- ─── Catmull-Rom spline ───────────────────────────────────────────────────────
-- Given 4 control points (x0,y0)..(x3,y3) and t in [0,1],
-- returns the interpolated point on the segment between p1 and p2.

local function catmullRomPoint(x0,y0, x1,y1, x2,y2, x3,y3, t)
    local t2 = t*t
    local t3 = t2*t
    local rx = 0.5*((-x0+3*x1-3*x2+x3)*t3 + (2*x0-5*x1+4*x2-x3)*t2
                    + (-x0+x2)*t + 2*x1)
    local ry = 0.5*((-y0+3*y1-3*y2+y3)*t3 + (2*y0-5*y1+4*y2-y3)*t2
                    + (-y0+y2)*t + 2*y1)
    return rx, ry
end

-- Emit a smooth Catmull-Rom curve through a list of (lx,ly) screen points.
-- Phantom points are added at each end by mirroring to handle endpoints cleanly.
local function drawSmoothedLine(pts, segs)
    local n = #pts
    if n < 2 then return end
    if n == 2 then
        -- Only 2 points: just draw a straight line, no curve needed
        glBeginEnd(GL_LINE_STRIP, function()
            glVertex(pts[1][1], pts[1][2])
            glVertex(pts[2][1], pts[2][2])
        end)
        return
    end

    -- Build extended point list with phantom endpoints
    -- p0 = mirror of p1 around p0; pN+1 = mirror of pN around pN+1
    local ext = {}
    ext[1] = { 2*pts[1][1]-pts[2][1], 2*pts[1][2]-pts[2][2] }
    for i = 1, n do ext[i+1] = pts[i] end
    ext[n+2] = { 2*pts[n][1]-pts[n-1][1], 2*pts[n][2]-pts[n-1][2] }

    glBeginEnd(GL_LINE_STRIP, function()
        -- Iterate over each real segment (between ext[2] and ext[n+1])
        for i = 1, n - 1 do
            local p0 = ext[i]
            local p1 = ext[i+1]
            local p2 = ext[i+2]
            local p3 = ext[i+3]
            for s = 0, segs do
                local t = s / segs
                local rx, ry = catmullRomPoint(
                    p0[1],p0[2], p1[1],p1[2],
                    p2[1],p2[2], p3[1],p3[2], t)
                glVertex(rx, ry)
            end
        end
    end)
end

-- ─── Panel layout ─────────────────────────────────────────────────────────────

local function panelRect(col, row)
    local totalW = CFG.w - CFG.padL - CFG.padR
    local totalH = CFG.h - CFG.padT - CFG.padB
    local pw     = (totalW - (CFG.panelCols-1)*CFG.panelGap) / CFG.panelCols
    local ph     = (totalH - (CFG.panelRows-1)*CFG.panelGap) / CFG.panelRows
    local px     = CFG.px + CFG.padL + (col-1)*(pw+CFG.panelGap)
    local py     = CFG.py + CFG.padB + (row-1)*(ph+CFG.panelGap)
    return px, py, pw, ph
end

-- ─── Draw ─────────────────────────────────────────────────────────────────────

local function drawWidget()
    local x0 = CFG.px
    local y0 = CFG.py
    local W  = CFG.w
    local H  = CFG.h

    -- Background
    glColor(0.04, 0.05, 0.08, CFG.bgAlpha)
    glRect(x0, y0, x0+W, y0+H)

    -- Border
    glColor(0.28, 0.48, 0.78, 0.40)
    gl.LineWidth(1.0)
    glBeginEnd(GL_LINE_LOOP, function()
        glVertex(x0,   y0);   glVertex(x0+W, y0)
        glVertex(x0+W, y0+H); glVertex(x0,   y0+H)
    end)

    if #top5 < 2 then
        glColor(0.55, 0.58, 0.65, 0.75)
        glText("FFA Timeseries: waiting for 2+ players...",
               x0+12, y0+H*0.5, CFG.fontSize, "o")
        -- still draw watermark
        glColor(0.52, 0.55, 0.60, 0.65)
        glText("goddot", x0+W-CFG.padR, y0+2, CFG.scaleFs, "or")
        return
    end

    local nowMin = currentMinute()
    local oldMin = mmax(0, nowMin - CFG.historyMins)
    local spanMin = nowMin - oldMin   -- could be 0 at game start

    for mi, metric in ipairs(METRICS) do
        local col     = ((mi-1) % CFG.panelCols) + 1
        local row     = mfloor((mi-1) / CFG.panelCols) + 1
        local drawRow = CFG.panelRows - row + 1
        local px, py, pw, ph = panelRect(col, drawRow)
        local mx = panelMax[mi]

        -- Panel bg + border
        glColor(0.07, 0.08, 0.11, 0.70)
        glRect(px, py, px+pw, py+ph)
        glColor(0.22, 0.30, 0.42, 0.50)
        glBeginEnd(GL_LINE_LOOP, function()
            glVertex(px,    py);    glVertex(px+pw, py)
            glVertex(px+pw, py+ph); glVertex(px,    py+ph)
        end)

        -- Y grid lines
        for t = 1, 4 do
            local gy = py + (t/4)*ph
            glColor(1, 1, 1, t==4 and 0.12 or 0.06)
            glBeginEnd(GL_LINES, function()
                glVertex(px, gy); glVertex(px+pw, gy)
            end)
        end

        -- X grid lines (one per minute in window)
        for t = 0, CFG.historyMins do
            local frac = spanMin > 0 and (t / CFG.historyMins) or 0
            local gx   = px + frac*pw
            glColor(1, 1, 1, 0.05)
            glBeginEnd(GL_LINES, function()
                glVertex(gx, py); glVertex(gx, py+ph)
            end)
        end

        -- X-axis minute labels (bottom row only)
        if drawRow == 1 then
            local step = CFG.historyMins <= 5 and 1 or 2
            for t = 0, CFG.historyMins, step do
                local frac   = t / CFG.historyMins
                local lx     = px + frac*pw
                local absMin = oldMin + t
                glColor(0.50, 0.53, 0.58, 0.80)
                glText(absMin.."m", lx, y0+4, CFG.scaleFs, "oc")
            end
        end

        -- Y max label + metric label
        glColor(0.55, 0.58, 0.62, 0.80)
        glText(fmtVal(mx), px+2, py+ph-1, CFG.scaleFs, "ol")
        glColor(0.80, 0.84, 0.92, 1.0)
        glText(metric.label, px+pw*0.5, py+ph-1, CFG.fontSize, "oc")

        -- ── Smooth player curves ──
        for _, p in ipairs(top5) do
            if #p.minutes > 0 then
                local col3 = p.color

                -- Build screen-space point list aligned to the shared x window
                local pts = {}
                for _, m in ipairs(p.minutes) do
                    local snap = p.history[m]
                    if snap then
                        local v     = snap[metric.key] or 0
                        local xfrac = spanMin > 0
                                      and mmin((m - oldMin) / spanMin, 1.0)
                                      or 1.0
                        if xfrac >= 0 then
                            local yfrac = mx > 0 and mmin(v/mx, 1.0) or 0
                            pts[#pts+1] = { px + xfrac*pw, py + yfrac*ph }
                        end
                    end
                end

                if #pts >= 1 then
                    gl.LineWidth(1.5)
                    glColor(col3[1], col3[2], col3[3], CFG.lineAlpha)
                    drawSmoothedLine(pts, CFG.curveSegs)
                    gl.LineWidth(1.0)

                    -- Dot at latest point
                    local lp = pts[#pts]
                    glColor(col3[1], col3[2], col3[3], 1.0)
                    glBeginEnd(GL_LINE_LOOP, function()
                        for s = 0, 7 do
                            local a = s*mpi/4
                            glVertex(lp[1]+mcos(a)*2.5, lp[2]+msin(a)*2.5)
                        end
                    end)
                end
            end
        end
    end

    -- ── Player name legend ──
    local legendW = CFG.w - CFG.padL - CFG.padR
    local slotW   = legendW / #top5
    for pi, p in ipairs(top5) do
        local col3 = p.color
        local nx   = CFG.px + CFG.padL + (pi-1)*slotW + slotW*0.5
        local ny   = y0 + 13
        glColor(col3[1], col3[2], col3[3], 0.9)
        glBeginEnd(GL_LINES, function()
            glVertex(nx-14, ny+4); glVertex(nx-4, ny+4)
        end)
        glColor(0, 0, 0, 0.55)
        glText(p.name, nx+1, ny,   CFG.labelFs, "oc")
        glColor(col3[1], col3[2], col3[3], 1.0)
        glText(p.name, nx,   ny+1, CFG.labelFs, "oc")
    end

    -- ── goddot watermark ──
    glColor(0, 0, 0, 0.45)
    glText("goddot", x0+W-CFG.padR-1, y0+1, CFG.scaleFs, "or")
    glColor(0.52, 0.55, 0.60, 0.65)
    glText("goddot", x0+W-CFG.padR,   y0+2, CFG.scaleFs, "or")
end

-- ─── Widget callbacks ─────────────────────────────────────────────────────────

local function updateLayout()
    CFG.px = screenW - CFG.w - 10
    CFG.py = mfloor(screenH*0.5) - mfloor(CFG.h*0.5)
end

function widget:Initialize()
    local info = { Spring.GetViewGeometry() }
    if info[3] and info[3] > 100 then screenW=info[3]; screenH=info[4] end
    classifyUnitDefs()
    updateLayout()
    refreshData()
end

function widget:ViewResize(vw, vh)
    screenW=vw; screenH=vh; updateLayout()
end

function widget:Update(dt)
    timer = timer + dt
    if timer >= CFG.updateInterval then timer=0; refreshData() end
end

function widget:DrawScreen()
    drawWidget()
end

-- ─── Dragging ─────────────────────────────────────────────────────────────────

local dragging, dragOffX, dragOffY = false, 0, 0

local function inWidget(mx, my)
    return mx>=CFG.px and mx<=CFG.px+CFG.w and my>=CFG.py and my<=CFG.py+CFG.h
end

function widget:MousePress(mx, my, btn)
    if btn~=1 then return false end
    if inWidget(mx,my) then
        dragging=true; dragOffX=mx-CFG.px; dragOffY=my-CFG.py; return true
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if dragging then CFG.px=mx-dragOffX; CFG.py=my-dragOffY end
end

function widget:MouseRelease(mx, my, btn)
    if btn==1 then dragging=false end
end