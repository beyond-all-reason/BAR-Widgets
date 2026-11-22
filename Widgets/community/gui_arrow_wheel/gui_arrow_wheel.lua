function widget:GetInfo()
    return {
        name    = "Arrow Wheel",
        desc    = "Hold the draw key (`) and then Q, point the mouse where the arrow should go and release Q to draw it on the map. Escape cancels. The key is the arrow_wheel action in the keybind editor.",
        author  = "_sing",
        date    = "November 22, 2026",
        license = "GNU GPL, v2 or later",
        version = "1.3",
        layer   = 998,
        enabled = true,
    }
end

-----------------------------------------------------------------------------------------------
-- Hold ` (the draw key) and press Q: the arrow starts at the cursor.
-- Move the mouse: the arrow points at the cursor, a preview of it is drawn on the map.
-- Release Q: the arrow is drawn with map lines, visible to your allies.
-- Escape or releasing close to the start (no preview shown) cancels.
-- Once ` is let go, left click also places the arrow and right click cancels. While ` is held,
-- BAR's map drawing gets the mouse buttons.
--
-- ` then Q is the default key of the arrow_wheel action, set in manifest.json. Players can
-- change it in the keybind editor.
-----------------------------------------------------------------------------------------------

local ACTION = "arrow_wheel"

-- Arrow shape
local arrowHeadLengthRatio = 0.3  -- head length as a share of the arrow length
local arrowHeadMinLength = 40     -- elmos, keeps short arrows readable
local arrowHeadMaxLength = 160    -- elmos, keeps long arrows from growing huge heads
local arrowHeadWidthRatio = 0.6   -- head half-width relative to head length
local arrowHeadSweepRatio = 0.25  -- how far the barbs sweep back past the neck, relative to head length
local arrowShaftWidthRatio = 0.35 -- shaft half-width at the neck relative to head half-width
local arrowTailWidthRatio = 0.7   -- shaft half-width at the tail relative to the neck (tapered shaft)
local arrowTailNotchRatio = 1     -- depth of the swallowtail notch relative to tail half-width
local drawChevron = true          -- set to false to skip the inner chevron in the arrow head

local minArrowLength = 24         -- elmos, shorter arrows are not drawn
local maxSegmentLength = 128      -- elmos, longer edges are split so the arrow follows the terrain
local groundOffset = 5            -- elmos above the ground, same as BAR's own map drawing
local deadZoneRadius = 30         -- pixels, the cursor must move this far from the start to aim

-- The server silently drops a player's map lines after 26 that arrive less than 50 ms apart,
-- so long arrows are sent in batches with a pause between them
local maxLinesPerBatch = 20
local batchInterval = 0.2         -- seconds between batches

-- Timing in seconds
local fadeOutTime = 0.15          -- preview fade after placing, covers the delay before the map lines show up (0 disables)
local spamControlTime = 0.3       -- minimum time between two arrows

local previewLineWidth = 3
local previewAlpha = 0.8
-----------------------------------------------------------------------------------------------
-- End of params

local aiming = false
local fading = false      -- the placed arrow's preview is fading out
local previewFade = 1     -- multiplies the preview's alpha while fading out

local arrowColor          -- team color, set when aiming starts
local arrowStart          -- world position the arrow starts from
local arrowSegments       -- world space line segments of the arrow being aimed
local spamControl = 0
local sendQueue = {}      -- map lines of placed arrows waiting to be sent
local sendIndex = 1       -- next line in sendQueue to send
local sendTimer = 0       -- time left before the next batch can be sent

-- Speedups
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spWorldToScreenCoords = Spring.WorldToScreenCoords
local spGetGroundHeight = Spring.GetGroundHeight
local spGetKeyCode = Spring.GetKeyCode
local spGetKeyFromScanSymbol = Spring.GetKeyFromScanSymbol
local spGetKeyState = Spring.GetKeyState
local spMarkerAddLine = Spring.MarkerAddLine
local glColor = gl.Color
local glLineWidth = gl.LineWidth
local glDepthTest = gl.DepthTest
local glBeginEnd = gl.BeginEnd
local glVertex = gl.Vertex
local GL_LINES = GL.LINES
local ceil = math.ceil
local max = math.max
local min = math.min
local sqrt = math.sqrt

local KEY_ESCAPE = Spring.GetKeyCode("esc")

local soundSetTarget = "sounds/commands/cmd-settarget.wav"

-- Builds the arrow as line segments { u1, v1, u2, v2 } in arrow space: u runs from the tail (0)
-- to the tip (length) and v is the sideways offset, so the point always sits exactly on the tip.
local function BuildArrowShape(length)
    local headLength = min(max(length * arrowHeadLengthRatio, arrowHeadMinLength), arrowHeadMaxLength)
    headLength = min(headLength, length * 0.6) -- leave some shaft on short arrows

    local headHalfWidth = headLength * arrowHeadWidthRatio
    local shaftHalfWidth = headHalfWidth * arrowShaftWidthRatio
    local tailHalfWidth = shaftHalfWidth * arrowTailWidthRatio
    local barbU = length - headLength
    local neckU = barbU + headLength * arrowHeadSweepRatio

    -- closed outline, starting at the tip
    local outline = {
        { length, 0 },
        { barbU, headHalfWidth },
        { neckU, shaftHalfWidth },
        { 0, tailHalfWidth },
        { tailHalfWidth * arrowTailNotchRatio, 0 }, -- swallowtail notch
        { 0, -tailHalfWidth },
        { neckU, -shaftHalfWidth },
        { barbU, -headHalfWidth },
    }
    local segments = {}
    for i = 1, #outline do
        local a, b = outline[i], outline[i % #outline + 1]
        segments[#segments + 1] = { a[1], a[2], b[1], b[2] }
    end

    -- a smaller chevron inside the head, parallel to its edges
    if drawChevron then
        local chevronTipU = length - headLength * 0.3
        local chevronArmU = chevronTipU - headLength * 0.45
        local chevronArmV = headHalfWidth * 0.45
        segments[#segments + 1] = { chevronArmU, chevronArmV, chevronTipU, 0 }
        segments[#segments + 1] = { chevronTipU, 0, chevronArmU, -chevronArmV }
    end
    return segments
end

local function GroundY(x, z)
    return spGetGroundHeight(x, z) + groundOffset
end

-- Places the arrow shape between two world positions as { x1, y1, z1, x2, y2, z2 } segments,
-- splitting long edges so the arrow follows the terrain instead of cutting through hills
local function BuildWorldArrow(startPosition, endPosition)
    local dx = endPosition[1] - startPosition[1]
    local dz = endPosition[3] - startPosition[3]
    local length = sqrt(dx * dx + dz * dz)
    if length < minArrowLength then
        return nil
    end

    local dirX, dirZ = dx / length, dz / length
    local shape = BuildArrowShape(length)
    local segments = {}
    for i = 1, #shape do
        local u1, v1, u2, v2 = shape[i][1], shape[i][2], shape[i][3], shape[i][4]
        local x1 = startPosition[1] + dirX * u1 - dirZ * v1
        local z1 = startPosition[3] + dirZ * u1 + dirX * v1
        local segX = dirX * (u2 - u1) - dirZ * (v2 - v1)
        local segZ = dirZ * (u2 - u1) + dirX * (v2 - v1)
        local pieces = max(1, ceil(sqrt(segX * segX + segZ * segZ) / maxSegmentLength))
        local px, py, pz = x1, GroundY(x1, z1), z1
        for p = 1, pieces do
            local nx = x1 + segX * p / pieces
            local nz = z1 + segZ * p / pieces
            local ny = GroundY(nx, nz)
            segments[#segments + 1] = { px, py, pz, nx, ny, nz }
            px, py, pz = nx, ny, nz
        end
    end
    return segments
end

-- Rebuilds the arrow preview from the start to the ground under the cursor
local function UpdateArrow()
    arrowSegments = nil
    local sx, sy = spWorldToScreenCoords(arrowStart[1], arrowStart[2], arrowStart[3])
    local mx, my = spGetMouseState()
    local dx, dy = mx - sx, my - sy
    if dx * dx + dy * dy < deadZoneRadius * deadZoneRadius then
        return
    end
    local _, arrowEnd = spTraceScreenRay(mx, my, true)
    if arrowEnd then
        arrowSegments = BuildWorldArrow(arrowStart, arrowEnd)
    end
end

local function StartAiming()
    local mx, my = spGetMouseState()
    local _, pos = spTraceScreenRay(mx, my, true)
    if not pos then
        return
    end
    arrowStart = pos
    arrowSegments = nil
    arrowColor = { Spring.GetTeamColor(Spring.GetMyTeamID()) }
    aiming = true
    fading = false
    previewFade = 1
    Spring.PlaySoundFile(soundSetTarget, 0.1, "ui")
end

-- Cancels aiming, or ends the fade out of a placed arrow
local function Reset()
    aiming = false
    fading = false
    arrowSegments = nil
end

-- Queues the arrow's map lines, then fades the preview out to cover the delay before they show up
local function PlaceArrow()
    if not arrowSegments or spamControl > 0 then
        Reset()
        return
    end
    for i = 1, #arrowSegments do
        sendQueue[#sendQueue + 1] = arrowSegments[i]
    end
    spamControl = spamControlTime
    if fadeOutTime > 0 then
        aiming = false
        fading = true
    else
        Reset()
    end
end

-- Sends the next batch of queued map lines
local function SendBatch()
    local last = min(#sendQueue, sendIndex + maxLinesPerBatch - 1)
    for i = sendIndex, last do
        local s = sendQueue[i]
        spMarkerAddLine(s[1], s[2], s[3], s[4], s[5], s[6], false)
    end
    sendIndex = last + 1
    if sendIndex > #sendQueue then
        sendQueue, sendIndex = {}, 1
    end
    sendTimer = batchInterval
end

-- Keycode of a key named in a bind, such as "sc_`" or "q", ignoring modifiers like "Alt+".
-- nil when the name can't be resolved.
local function BoundKeyCode(keyset)
    local name = string.match(keyset, "([^+]+)$")
    if name and string.sub(name, 1, 3) == "sc_" then
        name = spGetKeyFromScanSymbol(name)
    end
    local code = name and name ~= "" and spGetKeyCode(name)
    if code and code > 0 then
        return code
    end
end

-- The engine still matches a key sequence like ` then Q for a moment after its first key is
-- let go. Requiring the earlier keys to be held keeps a quick Q after drawing doing what Q
-- normally does.
local function SequenceHeld(actions)
    for i = 1, #actions do
        if actions[i].command == ACTION then
            local keysets = {}
            for keyset in string.gmatch(string.lower(actions[i].boundWith or ""), "[^,]+") do
                keysets[#keysets + 1] = keyset
            end
            for k = 1, #keysets - 1 do
                local code = BoundKeyCode(keysets[k])
                if code and not spGetKeyState(code) then
                    return false
                end
            end
            return true
        end
    end
    return true
end

-- Key press and its repeats. Repeats are taken too, so they don't reach other binds on the key.
local function OnActionPress(_, _, _, _, isRepeat, _, actions)
    if not SequenceHeld(actions) then
        return false
    end
    if not isRepeat and not aiming then
        StartAiming()
    end
    return true
end

-- BAR sends the release to the action that got the press, even if ` was let go first
local function OnActionRelease()
    if aiming then
        PlaceArrow()
        return true
    end
    return false
end

function widget:Initialize()
    widgetHandler:AddAction(ACTION, OnActionPress, nil, "pR")
    widgetHandler:AddAction(ACTION, OnActionRelease, nil, "r")
end

function widget:KeyPress(key)
    if key == KEY_ESCAPE and aiming then
        Reset()
        return true
    end
end

function widget:MousePress(mx, my, button)
    if not aiming then
        return false
    end
    if button == 1 then
        PlaceArrow()
        return true
    elseif button == 3 then
        Reset()
        return true
    end
end

function widget:Update(dt)
    spamControl = max(0, spamControl - dt)
    sendTimer = max(0, sendTimer - dt)
    if sendTimer == 0 and sendIndex <= #sendQueue then
        SendBatch()
    end

    if fading then
        previewFade = previewFade - dt / fadeOutTime
        if previewFade <= 0 then
            Reset()
        end
    elseif aiming then
        UpdateArrow()
    end
end

local function DrawSegments(segments)
    for i = 1, #segments do
        local s = segments[i]
        glVertex(s[1], s[2], s[3])
        glVertex(s[4], s[5], s[6])
    end
end

-- preview of the arrow on the map, exactly the lines that will be drawn
function widget:DrawWorld()
    if not arrowSegments then
        return
    end
    glDepthTest(false)
    glLineWidth(previewLineWidth)
    glColor(arrowColor[1], arrowColor[2], arrowColor[3], previewAlpha * previewFade)
    glBeginEnd(GL_LINES, DrawSegments, arrowSegments)
    glLineWidth(1)
    glColor(1, 1, 1, 1)
end
