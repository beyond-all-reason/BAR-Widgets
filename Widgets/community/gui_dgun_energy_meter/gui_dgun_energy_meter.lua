function widget:GetInfo()
  return {
    name      = "D-Gun Energy Meter",
    desc      = "Small gas-tank-shaped meter next to your commander that shows up while its D-Gun (Disintegrator) is armed -- select the commander, press D -- fills toward the shot's exact energy cost: red if you can't afford to fire yet, green once you can. Fades out over 2 seconds after you fire or disarm.",
    author    = "Armis71 + Claude AI",
    date      = "2026",
    license   = "GPL",
    layer     = 0,
    enabled   = true,
  }
end

------------------------------------------------------------
-- SIZE -- 0 = smallest (the meter's original/default size), 100 =
-- largest allowed. Anything outside 0-100 just clamps to that range.
------------------------------------------------------------

local userBarWidthPercent  = 40   -- 0-100
local userBarHeightPercent = 20   -- 0-100

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local MIN_BAR_WIDTH,  MAX_BAR_WIDTH  = 10 * (4 / 3), 30   -- ~13.3 .. 30
local MIN_BAR_HEIGHT, MAX_BAR_HEIGHT = 44, 90              -- 44 .. 90

local function percentToSize(percent, minSize, maxSize)
  percent = math.min(100, math.max(0, percent))
  return minSize + (maxSize - minSize) * (percent / 100)
end

local barWidth  = percentToSize(userBarWidthPercent, MIN_BAR_WIDTH, MAX_BAR_WIDTH)
local barHeight = percentToSize(userBarHeightPercent, MIN_BAR_HEIGHT, MAX_BAR_HEIGHT)
-- The tank's anchor point is offset from the unit in WORLD space (not
-- screen pixels) -- added to the unit's position before projecting to
-- screen. A fixed pixel offset would stay the same size on screen at
-- any zoom, so zooming out (unit shrinks) makes it look like it's
-- drifted away; a world-space offset shrinks right along with the
-- unit, so it stays visually "attached" at any zoom level.
-- worldOffsetRight/worldOffsetUp are in world units, roughly along
-- screen right/up for BAR's standard top-down-ish camera.
local worldOffsetRight = 32
local worldOffsetUp    = 55
-- Small residual screen-space nudge (px) applied after projection, so
-- the tank doesn't sit exactly on the anchor point. Shifted up by one
-- full tank-length (barHeight) on top of the world-space anchor.
local barOffsetY     = barHeight
-- Shifted right by three full tank widths. Screen-space (not world-
-- space) on purpose: the tank itself is drawn at a fixed pixel size
-- regardless of zoom, so a fixed pixel offset keeps the gap looking
-- like exactly 3 tanks at every zoom level. A world-space shift would
-- shrink as you zoom out and the gap would visibly close up.
local barOffsetX     = barWidth * 1
-- The world-space offset above shrinks on screen as you zoom out
-- (that's what keeps it glued to the unit), but the player nametag is
-- drawn with roughly fixed screen-space clearance above the unit --
-- so past a certain zoom-out level the shrinking world offset stops
-- being enough and the tank starts sliding down onto the name. These
-- are a floor: if the world offset's screen-space rise/shift ever
-- drops below these pixel minimums, extra screen-space distance gets
-- added to top it back up. When zoomed in enough that the world
-- offset alone already clears them, nothing changes.
local minScreenClearUp    = 60
local minScreenClearRight = 30
local borderColor    = {0, 0, 0, 0.9}
local bgColor        = {0.12, 0.12, 0.12, 0.65}
local readyColor     = {0.25, 0.95, 0.35, 0.95}   -- full: enough energy to fire right now
local lowColor       = {0.95, 0.25, 0.2, 0.95}     -- under half: can't afford it
local midColor       = {0.95, 0.7, 0.15, 0.95}     -- half to full: getting there

-- Pseudo-3D shading: a drop shadow behind the whole tank, plus a
-- lighter sheen strip down the left side to fake a cylindrical highlight.
local shadowColor    = {0, 0, 0, 0.45}
local shadowOffsetX  = 2.5
local shadowOffsetY  = -3
local sheenColor     = {1, 1, 1, 0.22}
local aoColor        = {0, 0, 0, 0.28}   -- ambient-occlusion darkening at the base

-- How long the meter takes to fully disappear once it's no longer
-- needed, in real seconds. It does NOT fade while the commander is
-- selected and doesn't have enough energy to fire yet (that's the one
-- moment you most need to see it) -- only once it's topped back up,
-- or once you deselect/re-arm elsewhere.
--   fadeDurationReady: nothing queued and it's full/green -- lingers
--     longer so you actually get to see "yes, you're ready" before it
--     goes away.
--   fadeDuration: every other exit (deselected while still short on
--     energy, etc.) -- quicker, since there's nothing useful left to
--     show.
local fadeDurationReady = 7.0
local fadeDuration      = 2.0

-- Tank-body geometry: the two long sides are straight, both ends are
-- fully rounded (a "capsule"/pill shape) so it reads as a small
-- cylindrical gas tank rather than a plain rectangle.
local tankRadius     = barWidth / 2
local capsuleSegments = 8

-- Charging effect: plays while a D-Gun shot is queued (armed) and the
-- tank isn't full yet -- a pulsing outer glow plus a traveling
-- scanline through the current fill, so it visibly reads as "actively
-- charging" rather than a static bar. Stops automatically once it
-- hits 100% (green/ready).
local chargeGlowColor  = {1, 1, 1, 1}
local chargePulseHz    = 1.6   -- glow pulses per second
local chargeScanHz     = 0.9   -- scanline sweeps per second
local chargeScanColor  = {1, 1, 1, 0.85}

-- Jagged lightning bolts crackling around the tank while charging --
-- much more noticeable than the soft glow/scanline alone, especially
-- at small on-screen sizes.
local lightningCoreColor = {1, 1, 1, 1}
local lightningGlowColor = {0.55, 0.85, 1, 1}
local lightningSegments  = 6
local lightningAmplitude = 4.5
local lightningOffset    = 4      -- how far out from the tank edge the bolts sit
local lightningBoltCount = 3      -- redrawn fresh (re-randomized) every frame

------------------------------------------------------------
-- STATE
------------------------------------------------------------

-- [unitID] = { weaponNum = <slot on the unit>, energyCost = <energyPerShot> }
local trackedCommanders = {}

-- Meters currently visible or fading out.
-- [unitID] = { sx=, sy=, fraction=, fadeStart=<Spring.GetTimer() or nil> }
-- fadeStart is nil while still actively armed; it gets set the instant
-- a meter stops being armed, and the meter is drawn at decreasing
-- alpha (frozen at its last known position/fraction) until fadeDuration
-- real seconds have passed, then it's dropped.
local activeMeters = {}

-- Per-unitDefID cache so re-scanning a unit's weapon list only happens
-- once per commander level, not every time a new commander unit shows
-- up (evolution creates a fresh unitID at each level).
local dgunInfoByDefID = {}

local myTeamID = nil

-- Fixed reference point for the charging animation's clock -- real
-- elapsed seconds since this, via Spring.DiffTimers, drives the pulse
-- and scanline regardless of game speed.
local animStartTimer = nil

------------------------------------------------------------
-- TEMP DEBUG -- prints to the in-game console / infolog.txt. Flip to
-- true if you need to troubleshoot detection again.
------------------------------------------------------------
local DEBUG_DGUN_METER = false
local function debugLog(fmt, ...)
  if DEBUG_DGUN_METER then
    Spring.Echo(("[DGunMeter] " .. fmt):format(...))
  end
end

------------------------------------------------------------
-- D-GUN LOOKUP
------------------------------------------------------------

-- Finds which weapon slot on this commander def is the D-Gun and what
-- it costs per shot.
--
-- Confirmed against the engine source (LuaWeaponDefs.cpp / WeaponDef.cpp):
-- the runtime WeaponDefs table does NOT expose "weaponType" or
-- "energyPerShot" -- those are only the authoring-time tag names in the
-- source .lua unit defs. The actual runtime fields are:
--   wd.manualFire  -- top-level boolean, true for the D-Gun/manual-fire
--                     weapon slot (reliable detection signal)
--   wd.energyCost  -- top-level number, energy cost per shot
--   wd.type        -- top-level string, e.g. "DGun" (cosmetic only,
--                     kept here as a fallback signal, not primary)
local function getDGunInfo(unitDefID)
  local cached = dgunInfoByDefID[unitDefID]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end

  local ud = UnitDefs[unitDefID]
  local info = nil
  if ud and ud.weapons then
    if DEBUG_DGUN_METER then
      debugLog("scanning weapons for %s (%d weapon slot(s)):", ud.name, #ud.weapons)
    end
    for weaponNum, w in ipairs(ud.weapons) do
      local wd = WeaponDefs[w.weaponDef]
      if wd then
        local isDGun = wd.manualFire == true

        debugLog("  slot %d: %s (manualFire=%s type=%s energyCost=%s)",
          weaponNum, wd.name or "?", tostring(wd.manualFire), tostring(wd.type), tostring(wd.energyCost))

        if isDGun then
          info = { weaponNum = weaponNum, energyCost = tonumber(wd.energyCost) or 0 }
        end
      else
        debugLog("  slot %d: WeaponDefs[%s] was nil", weaponNum, tostring(w.weaponDef))
      end
    end
  elseif ud then
    debugLog("unit %s has no ud.weapons table at all", ud.name)
  else
    debugLog("UnitDefs[%s] was nil", tostring(unitDefID))
  end

  debugLog("getDGunInfo(%s) -> %s", ud and ud.name or tostring(unitDefID),
    info and ("found, cost=" .. tostring(info.energyCost)) or "NOT FOUND")

  dgunInfoByDefID[unitDefID] = info or false
  return info
end

------------------------------------------------------------
-- TRACKING (own commander(s) only -- "can I afford this" only means
-- anything for units you actually control)
------------------------------------------------------------

local function tryTrack(unitID, unitDefID, unitTeam)
  if unitTeam ~= myTeamID then
    debugLog("tryTrack unit=%d skipped: unitTeam=%s ~= myTeamID=%s", unitID, tostring(unitTeam), tostring(myTeamID))
    return
  end

  local ud = UnitDefs[unitDefID]
  if not (ud and ud.customParams and ud.customParams.iscommander) then
    debugLog("tryTrack unit=%d skipped: defName=%s is not iscommander", unitID, ud and ud.name or tostring(unitDefID))
    return
  end

  local dgun = getDGunInfo(unitDefID)
  if not dgun then
    debugLog("tryTrack unit=%d (%s) skipped: no D-Gun found on this def", unitID, ud.name)
    return
  end

  trackedCommanders[unitID] = dgun
  debugLog("tryTrack unit=%d (%s) TRACKED: weaponNum=%d energyCost=%d", unitID, ud.name, dgun.weaponNum, dgun.energyCost)
end

local function refreshMyTeamID()
  if Spring.GetSpectatingState() then
    myTeamID = nil
  else
    myTeamID = Spring.GetMyTeamID()
  end
  debugLog("refreshMyTeamID -> myTeamID=%s (spectating=%s)", tostring(myTeamID), tostring(Spring.GetSpectatingState()))
end

local function rescanOwnCommanders()
  trackedCommanders = {}
  if not myTeamID then
    debugLog("rescanOwnCommanders: myTeamID is nil, nothing to scan")
    return
  end

  local units = Spring.GetTeamUnits(myTeamID)
  debugLog("rescanOwnCommanders: team=%d has %d unit(s) total", myTeamID, #units)
  for _, unitID in ipairs(units) do
    local unitDefID = Spring.GetUnitDefID(unitID)
    if unitDefID then
      tryTrack(unitID, unitDefID, myTeamID)
    end
  end
  local trackedCount = 0
  for _ in pairs(trackedCommanders) do trackedCount = trackedCount + 1 end
  debugLog("rescanOwnCommanders: finished, %d commander(s) tracked", trackedCount)
end

function widget:Initialize()
  debugLog("widget:Initialize called")
  animStartTimer = Spring.GetTimer()
  refreshMyTeamID()
  rescanOwnCommanders()
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
  tryTrack(unitID, unitDefID, unitTeam)
end

function widget:UnitGiven(unitID, unitDefID, unitTeam)
  tryTrack(unitID, unitDefID, unitTeam)
end

function widget:UnitDestroyed(unitID)
  trackedCommanders[unitID] = nil
  activeMeters[unitID] = nil
end

function widget:UnitTaken(unitID)
  trackedCommanders[unitID] = nil
  activeMeters[unitID] = nil
end

-- Covers switching which player you're following while spectating, or
-- the match handing you a team, without needing to catch every
-- individual engine event that could change it.
function widget:PlayerChanged(playerID)
  local myPlayerID = Spring.GetMyPlayerID()
  if playerID == myPlayerID then
    refreshMyTeamID()
    rescanOwnCommanders()
  end
end

------------------------------------------------------------
-- DRAW
------------------------------------------------------------

-- Builds the outline of a vertical capsule ("pill"/gas-cylinder shape):
-- straight sides, fully rounded top and bottom. Points run counter-
-- clockwise starting at the rightmost point of the top arc, so the
-- list can be used directly as a LINE_LOOP border or fanned out from
-- the shape's centroid for a filled TRIANGLE_FAN.
local function buildCapsuleOutline(x1, y1, x2, y2)
  local r = math.min(tankRadius, (x2 - x1) / 2, (y2 - y1) / 2)
  local cx = (x1 + x2) / 2
  local topCY = y2 - r
  local botCY = y1 + r

  local points = {}
  for i = 0, capsuleSegments do
    local deg = 0 + (180 - 0) * (i / capsuleSegments)
    local rad = math.rad(deg)
    points[#points + 1] = { cx + r * math.cos(rad), topCY + r * math.sin(rad) }
  end
  for i = 0, capsuleSegments do
    local deg = 180 + (360 - 180) * (i / capsuleSegments)
    local rad = math.rad(deg)
    points[#points + 1] = { cx + r * math.cos(rad), botCY + r * math.sin(rad) }
  end
  return points
end

local function drawCapsuleFilled(outline, x1, y1, x2, y2)
  local cx = (x1 + x2) / 2
  local cy = (y1 + y2) / 2
  gl.BeginEnd(GL.TRIANGLE_FAN, function()
    gl.Vertex(cx, cy)
    for _, p in ipairs(outline) do
      gl.Vertex(p[1], p[2])
    end
    gl.Vertex(outline[1][1], outline[1][2])
  end)
end

local function drawCapsuleOutline(outline)
  gl.BeginEnd(GL.LINE_LOOP, function()
    for _, p in ipairs(outline) do
      gl.Vertex(p[1], p[2])
    end
  end)
end

-- Builds a jagged lightning-bolt point list from (x1,y1) to (x2,y2)
-- using iterative midpoint displacement: each interior point is
-- nudged perpendicular to the bolt's direction by a random amount,
-- tapered toward zero at both ends so it still lands on its anchors.
-- Called fresh every frame with a new math.random() draw, so bolts
-- crackle/flicker rather than sitting static.
local function buildLightningPoints(x1, y1, x2, y2, segments, amplitude)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  local nx, ny = 0, 0
  if len > 0.0001 then
    nx, ny = -dy / len, dx / len
  end

  local points = { { x1, y1 } }
  for i = 1, segments - 1 do
    local t = i / segments
    local baseX = x1 + dx * t
    local baseY = y1 + dy * t
    local taper = math.sin(t * math.pi)
    local jitter = (math.random() * 2 - 1) * amplitude * taper
    points[#points + 1] = { baseX + nx * jitter, baseY + ny * jitter }
  end
  points[#points + 1] = { x2, y2 }
  return points
end

-- Draws one crackling lightning bolt: a soft translucent glow pass
-- (thicker line) plus a bright white core pass (thin line) on top, to
-- fake a glowing electric arc without needing shaders.
local function drawLightningBolt(x1, y1, x2, y2, alpha)
  local pts = buildLightningPoints(x1, y1, x2, y2, lightningSegments, lightningAmplitude)

  gl.LineWidth(3.5)
  gl.Color(lightningGlowColor[1], lightningGlowColor[2], lightningGlowColor[3], lightningGlowColor[4] * 0.4 * alpha)
  gl.BeginEnd(GL.LINE_STRIP, function()
    for _, p in ipairs(pts) do
      gl.Vertex(p[1], p[2])
    end
  end)

  gl.LineWidth(1.3)
  gl.Color(lightningCoreColor[1], lightningCoreColor[2], lightningCoreColor[3], lightningCoreColor[4] * alpha)
  gl.BeginEnd(GL.LINE_STRIP, function()
    for _, p in ipairs(pts) do
      gl.Vertex(p[1], p[2])
    end
  end)
end

-- Draws one straight vertical pipe stub (like the muffler-icon pipes,
-- but unbent) as a thin rounded capsule: shadow, metal fill, border.
-- Sits flush against the tank body so it reads as plumbing coming out
-- either end, and is never touched by the energy fill/sheen/AO passes,
-- which are scissored to the body box only.
local function drawPipeStub(cx, yFrom, yTo, width, alpha)
  local px1 = cx - width / 2
  local px2 = px1 + width
  local py1 = math.min(yFrom, yTo)
  local py2 = math.max(yFrom, yTo)
  local outline = buildCapsuleOutline(px1, py1, px2, py2)

  local ssx1, ssy1 = px1 + shadowOffsetX, py1 + shadowOffsetY
  local ssx2, ssy2 = px2 + shadowOffsetX, py2 + shadowOffsetY
  local shadowOutline = buildCapsuleOutline(ssx1, ssy1, ssx2, ssy2)
  gl.Color(shadowColor[1], shadowColor[2], shadowColor[3], shadowColor[4] * alpha)
  drawCapsuleFilled(shadowOutline, ssx1, ssy1, ssx2, ssy2)

  gl.Color(bgColor[1], bgColor[2], bgColor[3], bgColor[4] * alpha)
  drawCapsuleFilled(outline, px1, py1, px2, py2)

  gl.Scissor(px1 + 1, py1 + 1, (px2 - px1) * 0.4, (py2 - py1) - 2)
  gl.Color(sheenColor[1], sheenColor[2], sheenColor[3], sheenColor[4] * alpha)
  drawCapsuleFilled(outline, px1, py1, px2, py2)
  gl.Scissor(false)

  gl.Color(borderColor[1], borderColor[2], borderColor[3], borderColor[4] * alpha)
  gl.LineWidth(1.5)
  drawCapsuleOutline(outline)
end

-- alpha: 0-1 multiplier applied to every color, used for the fade-out
-- after the D-Gun stops being armed.
-- charging: true while a shot is queued (armed) and fraction < 1 --
-- drives the pulsing glow + traveling scanline effect.
local function drawMeter(sx, sy, fraction, alpha, charging)
  -- Offsets describe the tank's CENTER.
  local cxScreen = sx + barOffsetX
  local cyScreen = sy + barOffsetY
  local x1 = cxScreen - barWidth / 2
  local x2 = x1 + barWidth
  local y1 = cyScreen - barHeight / 2
  local y2 = y1 + barHeight

  local pipeWidth  = barWidth * 0.4
  local pipeLength = 7

  gl.Texture(false)

  local outline = buildCapsuleOutline(x1, y1, x2, y2)

  local t = animStartTimer and Spring.DiffTimers(Spring.GetTimer(), animStartTimer) or 0

  -- Straight vertical pipe stubs top and bottom, drawn first/behind
  -- the body so their shadows read as coming out from underneath it.
  drawPipeStub(cxScreen, y2, y2 + pipeLength, pipeWidth, alpha)
  drawPipeStub(cxScreen, y1, y1 - pipeLength, pipeWidth, alpha)

  -- Charging glow: a soft pulsing halo drawn behind the body, only
  -- while actively charging toward a queued shot.
  if charging then
    local pulse = 0.5 + 0.5 * math.sin(t * chargePulseHz * 2 * math.pi)
    for ring = 3, 1, -1 do
      local d = ring * 1.6
      local glowOutline = buildCapsuleOutline(x1 - d, y1 - d, x2 + d, y2 + d)
      local ringAlpha = chargeGlowColor[4] * (0.14 - ring * 0.03) * (0.4 + 0.6 * pulse)
      gl.Color(chargeGlowColor[1], chargeGlowColor[2], chargeGlowColor[3], ringAlpha * alpha)
      drawCapsuleFilled(glowOutline, x1 - d, y1 - d, x2 + d, y2 + d)
    end
  end

  -- Drop shadow: a dark offset copy of the tank body's own silhouette,
  -- drawn before the body so everything else sits on top of it.
  local sx1, sy1 = x1 + shadowOffsetX, y1 + shadowOffsetY
  local sx2, sy2 = x2 + shadowOffsetX, y2 + shadowOffsetY
  local shadowOutline = buildCapsuleOutline(sx1, sy1, sx2, sy2)
  gl.Color(shadowColor[1], shadowColor[2], shadowColor[3], shadowColor[4] * alpha)
  drawCapsuleFilled(shadowOutline, sx1, sy1, sx2, sy2)

  -- Tank body background
  gl.Color(bgColor[1], bgColor[2], bgColor[3], bgColor[4] * alpha)
  drawCapsuleFilled(outline, x1, y1, x2, y2)

  -- Fill, bottom-up, clipped to the tank silhouette with a scissor so
  -- the rounded ends stay correct at any fill level.
  local fillH = (y2 - y1) * math.min(1, math.max(0, fraction))
  if fillH > 0 then
    local c = readyColor
    if fraction < 0.5 then
      c = lowColor
    elseif fraction < 1 then
      c = midColor
    end
    gl.Scissor(x1, y1, x2 - x1, fillH)
    gl.Color(c[1], c[2], c[3], c[4] * alpha)
    drawCapsuleFilled(outline, x1, y1, x2, y2)
    gl.Scissor(false)

    -- Charging scanline: a bright band sweeping up through the
    -- accumulated charge and looping, like energy flowing into the
    -- tank as it fills.
    if charging then
      local travel = t * chargeScanHz
      travel = travel - math.floor(travel)
      local scanY = y1 + travel * fillH
      local scanHalf = 2.5
      gl.Scissor(x1, math.max(y1, scanY - scanHalf), x2 - x1, scanHalf * 2)
      gl.Color(chargeScanColor[1], chargeScanColor[2], chargeScanColor[3], chargeScanColor[4] * alpha)
      drawCapsuleFilled(outline, x1, y1, x2, y2)
      gl.Scissor(false)
    end
  end

  -- Ambient-occlusion darkening near the base, for depth.
  gl.Scissor(x1, y1, x2 - x1, barHeight * 0.22)
  gl.Color(aoColor[1], aoColor[2], aoColor[3], aoColor[4] * alpha)
  drawCapsuleFilled(outline, x1, y1, x2, y2)
  gl.Scissor(false)

  -- Cylindrical sheen: a soft light strip down the left third, over
  -- everything else, to sell the rounded/3D look.
  gl.Scissor(x1 + 1, y1 + 1, (x2 - x1) * 0.32, (y2 - y1) - 2)
  gl.Color(sheenColor[1], sheenColor[2], sheenColor[3], sheenColor[4] * alpha)
  drawCapsuleFilled(outline, x1, y1, x2, y2)
  gl.Scissor(false)

  -- Border, drawn last so the silhouette stays crisp over the fill.
  -- While charging, the border pulses in step with the glow.
  local bc = borderColor
  if charging then
    local pulse = 0.5 + 0.5 * math.sin(t * chargePulseHz * 2 * math.pi)
    bc = {
      borderColor[1] + (chargeGlowColor[1] - borderColor[1]) * pulse * 0.5,
      borderColor[2] + (chargeGlowColor[2] - borderColor[2]) * pulse * 0.5,
      borderColor[3] + (chargeGlowColor[3] - borderColor[3]) * pulse * 0.5,
      borderColor[4],
    }
  end
  gl.Color(bc[1], bc[2], bc[3], bc[4] * alpha)
  gl.LineWidth(charging and 2 or 1.5)
  drawCapsuleOutline(outline)

  -- Crackling lightning caging the tank -- drawn last, on top of
  -- everything, so it reads clearly even at small sizes. Bolts run
  -- top-to-bottom just outside each side, plus one arcing across the
  -- very top between the pipe stubs; re-randomized every frame.
  if charging then
    local topY = y2 + pipeLength * 0.6
    local botY = y1 - pipeLength * 0.6
    drawLightningBolt(x1 - lightningOffset, topY, x1 - lightningOffset, botY, alpha)
    drawLightningBolt(x2 + lightningOffset, topY, x2 + lightningOffset, botY, alpha)
    if lightningBoltCount > 2 then
      drawLightningBolt(x1 - lightningOffset * 0.5, topY + 3, x2 + lightningOffset * 0.5, topY + 3, alpha)
    end
  end

  gl.Color(1, 1, 1, 1)
end

-- Throttled so this doesn't spam the console every single frame --
-- logs at most once every ~2 seconds while DEBUG_DGUN_METER is on.
local lastDrawDebugFrame = -999999
local function drawDebugThrottled(fmt, ...)
  local frame = Spring.GetGameFrame()
  if frame - lastDrawDebugFrame >= 60 then
    lastDrawDebugFrame = frame
    debugLog(fmt, ...)
  end
end

-- True if this unit has a manual-fire (D-Gun) order sitting in its
-- command queue that hasn't executed yet. Clicking to fire the D-Gun
-- issues a CMD.MANUALFIRE order and the active-command crosshair mode
-- immediately reverts to normal -- but the engine keeps that order in
-- the unit's commandQue, waiting on preconditions (energy, reload),
-- until it actually fires. So this is what tells us "still waiting to
-- shoot" after the initial click, not just "crosshair currently up".
local function unitHasQueuedManualFire(unitID)
  local commands = Spring.GetUnitCommands(unitID, 5)
  if type(commands) ~= "table" then
    return false
  end
  for _, cmd in ipairs(commands) do
    if cmd.id == CMD.MANUALFIRE then
      return true
    end
  end
  return false
end

-- Per the actual in-game flow: select the commander, press D (arms
-- CMD.MANUALFIRE -- 105, the same ID the old CMD.DGUN alias points at)
-- to bring up the D-Gun crosshair, click to queue the shot -- which
-- then waits for enough energy/reload before it actually fires. This
-- returns every selected tracked commander that's either mid-crosshair
-- or has that queued order still pending.
local function getArmedSelectedCommanders()
  local _, cmdID = Spring.GetActiveCommand()
  local crosshairUp = cmdID == CMD.MANUALFIRE

  local armed = nil
  for _, unitID in ipairs(Spring.GetSelectedUnits()) do
    local dgun = trackedCommanders[unitID]
    if dgun and (crosshairUp or unitHasQueuedManualFire(unitID)) then
      armed = armed or {}
      armed[unitID] = dgun
    end
  end
  return armed
end

-- Narrower than getArmedSelectedCommanders(): true only once a shot
-- has actually been QUEUED (you clicked a target after pressing D),
-- not merely while the D-Gun crosshair is up. Pressing D alone just
-- arms the cursor -- the commander is still under full manual control
-- and nothing is committed to fire yet, so the charging effect
-- shouldn't play for that state.
local function getQueuedSelectedCommanders()
  local queued = nil
  for _, unitID in ipairs(Spring.GetSelectedUnits()) do
    local dgun = trackedCommanders[unitID]
    if dgun and unitHasQueuedManualFire(unitID) then
      queued = queued or {}
      queued[unitID] = dgun
    end
  end
  return queued
end

local function getSelectedTrackedSet()
  local set = nil
  for _, unitID in ipairs(Spring.GetSelectedUnits()) do
    if trackedCommanders[unitID] then
      set = set or {}
      set[unitID] = true
    end
  end
  return set
end

-- Projects the meter's anchor point for a unit: its world position
-- nudged by worldOffsetRight/worldOffsetUp (so the anchor scales with
-- zoom like the unit itself), then converted to screen coords -- with
-- a screen-space floor topped up on top of that so it never creeps
-- back down onto the nametag/health bar as you zoom out.
local function getMeterScreenPos(unitID)
  local px, py, pz = Spring.GetUnitPosition(unitID)
  if not px then
    return nil
  end

  local baseSx, baseSy = Spring.WorldToScreenCoords(px, py, pz)
  local sx, sy = Spring.WorldToScreenCoords(px + worldOffsetRight, py + worldOffsetUp, pz)
  if not (sx and sy) then
    return sx, sy
  end
  if not (baseSx and baseSy) then
    return sx, sy
  end

  local rise = sy - baseSy
  if rise < minScreenClearUp then
    sy = sy + (minScreenClearUp - rise)
  end
  local shiftRight = sx - baseSx
  if shiftRight < minScreenClearRight then
    sx = sx + (minScreenClearRight - shiftRight)
  end

  return sx, sy
end

function widget:DrawScreen()
  if not myTeamID then
    drawDebugThrottled("DrawScreen: myTeamID is nil, skipping")
    return
  end
  if next(trackedCommanders) == nil and next(activeMeters) == nil then
    drawDebugThrottled("DrawScreen: nothing tracked and nothing fading, skipping")
    return
  end

  local armed = getArmedSelectedCommanders() or {}
  local queued = getQueuedSelectedCommanders() or {}
  local selected = getSelectedTrackedSet() or {}
  local current = Spring.GetTeamResources(myTeamID, "energy")

  -- Bring newly-armed units into activeMeters, and cancel any
  -- in-progress fade if a unit gets re-armed mid-fade.
  for unitID, dgun in pairs(armed) do
    local meter = activeMeters[unitID]
    if not meter then
      meter = {}
      activeMeters[unitID] = meter
    end
    meter.dgun = dgun
    meter.fadeStart = nil
  end

  -- Every tracked meter re-projects its screen position from the
  -- unit's LIVE world position every single frame, regardless of
  -- armed/fade state -- this is what keeps it glued to the unit
  -- through camera zoom/pan, including while fading out. Only the
  -- fraction/fill freezes once a fade starts (position never does).
  for unitID, meter in pairs(activeMeters) do
    local sx, sy = getMeterScreenPos(unitID)
    if not sx then
      -- Unit is gone (dead/invalid) -- nothing left to track.
      activeMeters[unitID] = nil
    else
      meter.sx, meter.sy = sx, sy

      if not meter.fadeStart and current and meter.dgun then
        meter.fraction = meter.dgun.energyCost > 0 and (current / meter.dgun.energyCost) or 1
      end

      if not armed[unitID] and not meter.fadeStart then
        -- Not currently armed. Keep it up, live, un-faded, ONLY while
        -- still selected and short on energy (the "just fired but
        -- couldn't afford it, still waiting" case) -- that's the one
        -- warning that matters most. Otherwise start the fade: a slow
        -- 7s fade if it's sitting full/green with nothing queued (so
        -- you actually get to see "ready"), a quick 2s fade otherwise.
        local stillWaiting = selected[unitID] and (meter.fraction or 1) < 1
        if not stillWaiting then
          meter.fadeStart = Spring.GetTimer()
          meter.fadeDuration = ((meter.fraction or 0) >= 1) and fadeDurationReady or fadeDuration
        end
      end
    end
  end

  -- Draw everything still visible; drop anything that's finished fading.
  local now = Spring.GetTimer()
  for unitID, meter in pairs(activeMeters) do
    local alpha = 1
    if meter.fadeStart then
      local elapsed = Spring.DiffTimers(now, meter.fadeStart)
      alpha = 1 - (elapsed / (meter.fadeDuration or fadeDuration))
    end
    if alpha <= 0 then
      activeMeters[unitID] = nil
    else
      -- Charging effect = a shot is actually QUEUED (you clicked a
      -- target) and it's not full yet -- not just the crosshair being
      -- up. Pressing D alone arms the cursor but commits to nothing;
      -- the commander is still under full manual control at that
      -- point, so the "charging toward a committed shot" effect
      -- shouldn't play until there's a real pending order.
      local charging = queued[unitID] and (meter.fraction or 1) < 1
      drawMeter(meter.sx, meter.sy, meter.fraction or 0, alpha, charging)
    end
  end
end
