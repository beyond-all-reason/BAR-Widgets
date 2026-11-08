local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Commander Health Bar",
        desc = "Commander health bar. Ctrl + left-drag to reposition.",
        author = "Buttons840",
        date = "October 2026",
        license = "GNU GPL, v2 or later",
        layer = 100,
        enabled = true,
    }
end

-- Only the local team's sole living commander is displayed.
-- Set true to simulate damage and show the bar for layout testing.
local PREVIEW = false
local SETTINGS_PREVIEW_SECONDS = 30
local PREVIEW_MESSAGE = "Temporary preview after changing settings"
local PLAYER_COLOR_MODES = { "Never", "When spectating", "Always" }
local SNAP_KEY = "commanderhealthbar"
local SNAP_DIST, SNAP_GAP, SNAP_NEAR, SNAP_GRID = 10, 5, 40, 16
local DAMAGE_HOLD = 0.025 -- Short stationary white flash before the segment starts falling.
local MIN_DAMAGE = 5 -- Wake the bar when at least this much HP is missing.
local FULL_HEALTH_HOLD = 5.0 -- Keep the bar visible this long after a heal to full.
local FULL_HEALTH_FADE = 1.0 -- Fade out the entire bar (including frame and text).
local UNIT_POLL = 0.22   -- Re-scan for multiple commanders, capture, resurrection, etc.
local LAYOUT_POLL = 0.30
local BAR_W_MULT = 20.0 -- Width relative to the top resource bar's height.
local BAR_H_MULT = 0.68

local max, min, floor = math.max, math.min, math.floor
local vsx, vsy = 1920, 1080
local pos = { x = 170, y = 970, w = 700, h = 25 }
local baseBarHeight = 25 -- Bar height at the 100% height setting.
local userPos, drag, shader, uniforms
local commanderDefs = {}
local commanderID, commanderTeam, commanderCount
local hp, maxHP, healthFrac = 0, 1, 1
local damageEvents = {} -- Active falling white damage segments.
local previewDamageEvents = {} -- Preview animation is separate from actual damage.
local previewRemaining = 0
local visible = false
local fullHealElapsed = nil -- Counts up after significant damage has healed.
local attentionActive = false -- Small hits do not wake a hidden bar or extend its fade.
local color = { 0.3, 0.8, 1.0 }
-- Width/height percentages relative to the automatically scaled bar.
local config = {
    widthPercent = 100,
    heightPercent = 100,
    damageFallHeights = 10,
    damageDurationMs = 500,
    playerColorMode = "Never",
    showWhileSpectating = true,
}
local testTimer, testFrac = 0, 0.76
local unitsTimer, layoutTimer = 0, 0
local lastSpectating

local function Clamp(v, lo, hi)
    return max(lo, min(hi, v))
end

local function InPreview()
    return PREVIEW or previewRemaining > 0
end

local function CanShow()
    return shader ~= nil and (config.showWhileSpectating or not Spring.GetSpectatingState())
        and (InPreview() or (visible and commanderCount == 1))
end

local function UpdateSnapRect()
    WG.snapRects = WG.snapRects or {}
    if CanShow() then
        WG.snapRects[SNAP_KEY] = { pos.x, pos.y, pos.x + pos.w, pos.y + pos.h }
    else
        WG.snapRects[SNAP_KEY] = nil
    end
end

-- The bar wakes at five missing HP and stays visible through healing and fade.
local function RefreshVisibility()
    local shouldShow = commanderCount == 1 and commanderID ~= nil and attentionActive
        and (fullHealElapsed == nil or fullHealElapsed < FULL_HEALTH_HOLD + FULL_HEALTH_FADE)
    if visible ~= shouldShow then
        visible = shouldShow
        UpdateSnapRect()
    end
end

local function VisibilityAlpha()
    if InPreview() or fullHealElapsed == nil then return 1 end
    return 1 - Clamp((fullHealElapsed - FULL_HEALTH_HOLD) / FULL_HEALTH_FADE, 0, 1)
end

local function SnapPos(x, y, w, h)
    local rects = {}
    if WG.snapRects then
        for key, r in pairs(WG.snapRects) do
            if key ~= SNAP_KEY then rects[#rects + 1] = r end
        end
    end
    local mx, my, mw, mh = Spring.GetMiniMapGeometry()
    if mw and mw > 0 then rects[#rects + 1] = { mx, my, mx + mw, my + mh } end
    local tb = WG.topbar and WG.topbar.GetPosition and WG.topbar.GetPosition()
    if tb then rects[#rects + 1] = { tb[1], tb[2], min(tb[3] or vsx, vsx), vsy } end

    local dx, dy
    for i = 1, #rects do
        local r = rects[i]
        if y < r[4] + SNAP_NEAR and y + h > r[2] - SNAP_NEAR then
            local c = { r[1], r[3] - w, r[3] + SNAP_GAP, r[1] - w - SNAP_GAP }
            for j = 1, 4 do
                local d = c[j] - x
                if math.abs(d) <= SNAP_DIST and (not dx or math.abs(d) < math.abs(dx)) then dx = d end
            end
        end
        if x < r[3] + SNAP_NEAR and x + w > r[1] - SNAP_NEAR then
            local c = { r[2], r[4] - h, r[4] + SNAP_GAP, r[2] - h - SNAP_GAP }
            for j = 1, 4 do
                local d = c[j] - y
                if math.abs(d) <= SNAP_DIST and (not dy or math.abs(d) < math.abs(dy)) then dy = d end
            end
        end
    end
    if not dx then dx = floor(x / SNAP_GRID + 0.5) * SNAP_GRID - x end
    if not dy then dy = floor(y / SNAP_GRID + 0.5) * SNAP_GRID - y end
    return x + dx, y + dy
end

local function UpdatePos()
    local tb = WG.topbar and WG.topbar.GetPosition and WG.topbar.GetPosition()
    local topH = tb and Clamp(vsy - tb[2], 26, 85) or 36 * Clamp(vsy / 1080, 0.7, 1.8)
    local baseW = Clamp(topH * BAR_W_MULT, 280, vsx * 0.66)
    local baseH = Clamp(topH * BAR_H_MULT, 17, 48)
    baseBarHeight = floor(Clamp(baseH, 10, min(120, vsy)) + 0.5)
    pos.w = floor(Clamp(baseW * config.widthPercent * 0.01, 120, vsx) + 0.5)
    pos.h = floor(Clamp(baseH * config.heightPercent * 0.01, 10, min(120, vsy)) + 0.5)
    if userPos then
        pos.x, pos.y = userPos[1] * vsx, userPos[2] * vsy
    elseif tb then
        pos.x, pos.y = tb[1], tb[2] - pos.h - 9
    else
        pos.x, pos.y = vsx * 0.12, vsy - pos.h - topH - 15
    end
    pos.x = floor(Clamp(pos.x, 0, max(0, vsx - pos.w)))
    pos.y = floor(Clamp(pos.y, 0, max(0, vsy - pos.h)))
    UpdateSnapRect()
end

local function AddDamage(oldFrac, newFrac, events)
    if config.damageDurationMs <= 0 then return end
    events = events or damageEvents
    oldFrac, newFrac = Clamp(oldFrac, 0, 1), Clamp(newFrac, 0, 1)
    if oldFrac <= newFrac then return end
    events[#events + 1] = { left = newFrac, right = oldFrac, age = 0 }
    if #events > 40 then table.remove(events, 1) end
end

local function StartSettingsPreview()
    -- Disabling spectator display also suppresses the settings preview.
    if Spring.GetSpectatingState() and not config.showWhileSpectating then
        previewRemaining = 0
        previewDamageEvents = {}
    else
        testTimer, testFrac = 0, 1.0
        previewDamageEvents = {}
        previewRemaining = SETTINGS_PREVIEW_SECONDS
    end
    UpdateSnapRect()
end

local function ResetCommander(unitID, team)
    commanderID, commanderTeam = unitID, team
    hp, maxHP, healthFrac = 0, 1, 1
    damageEvents = {}
    fullHealElapsed = nil
    attentionActive = false
    visible = false
end

local function RefreshUnits()
    local team = Spring.GetMyTeamID()
    if not team or #commanderDefs == 0 then
        commanderCount = 0
        if commanderID then ResetCommander(nil, nil) end
        RefreshVisibility()
        UpdateSnapRect()
        return
    end

    local list = Spring.GetTeamUnitsByDefs(team, commanderDefs) or {}
    local alive, chosen = 0, nil
    for i = 1, #list do
        local unitID = list[i]
        if not Spring.GetUnitIsDead(unitID) then
            alive = alive + 1
            chosen = unitID
            if alive > 1 then break end
        end
    end
    commanderCount = alive
    if alive ~= 1 then chosen = nil end
    if commanderID ~= chosen or commanderTeam ~= team then ResetCommander(chosen, team) end
    RefreshVisibility()
    UpdateSnapRect()
end

local function RefreshHealth()
    if not commanderID then return end
    local current, maximum = Spring.GetUnitHealth(commanderID)
    if not current or not maximum or maximum <= 0 then
        fullHealElapsed = nil
        attentionActive = false
        visible = false
        UpdateSnapRect()
        return
    end

    local fraction = Clamp(current / maximum, 0, 1)
    local damage = (hp > 0) and max(0, hp - current) or 0
    local missing = max(0, maximum - current)

    -- Only missing health decides whether to wake a hidden bar.
    -- Once visible, every HP loss animates and cancels any full-health fade.
    local wakesBar = missing >= MIN_DAMAGE
    if damage > 0 and (visible or wakesBar) then
        AddDamage(Clamp(hp / maximum, 0, 1), fraction)
    end

    -- An existing injury is shown when first tracking a commander.
    if wakesBar or (visible and damage > 0) then
        attentionActive = true
        fullHealElapsed = nil
    elseif attentionActive and fullHealElapsed == nil and missing <= 0.001 then
        -- Significant damage has healed fully: hold for five seconds, then fade.
        fullHealElapsed = 0
    end

    hp, maxHP, healthFrac = current, maximum, fraction
    RefreshVisibility()
end

-- GLSL 1.20 works with BAR's compatibility OpenGL drawing path.
-- One shader draws both the frame/fill and independent white drop-off sprites.
local FRAGMENT = [[
    #version 120
    uniform vec4 rect;       // x, y, width, height in screen pixels
    uniform vec3 teamColor;
    uniform float usePlayerColor;
    uniform float health;
    uniform float opacity;
    uniform float visibility; // Fade of the entire health bar on return to full health.
    uniform float mode;      // 0: base bar, 1: falling white damage segment
    uniform vec2 interval;   // Normalized left/right of a damage segment
    uniform float drop;
    uniform float flashAlpha;

    float roundedDistance(vec2 p, vec2 halfSize, float radius) {
        vec2 q = abs(p) - halfSize + vec2(radius);
        return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    }
    float cover(float d) { return 1.0 - smoothstep(-0.8, 0.8, d); }

    // Smooth procedural noise for broad, non-tiling surface variation.
    float hash2(vec2 p) {
        return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    }
    float valueNoise(vec2 p) {
        vec2 cell = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(
            mix(hash2(cell), hash2(cell + vec2(1.0, 0.0)), f.x),
            mix(hash2(cell + vec2(0.0, 1.0)), hash2(cell + vec2(1.0, 1.0)), f.x),
            f.y);
    }
    void main() {
        vec2 uv = gl_FragCoord.xy - rect.xy;
        vec2 halfSize = rect.zw * 0.5;
        float radius = min(8.0, rect.w * 0.34);
        float outer = cover(roundedDistance(uv - halfSize, halfSize - vec2(0.45), radius));
        // Three-pixel opaque frame surrounding the health interior.
        float stroke = 3.0;
        vec2 inset = vec2(stroke);
        vec2 innerHalf = halfSize - inset;
        float innerR = max(0.8, radius - stroke + 0.2);

        if (mode > 0.5) {
            // The white sliver originates at the missing-health portion, then drops.
            vec2 falling = uv + vec2(0.0, drop);
            float inside = cover(roundedDistance(falling - halfSize, innerHalf, innerR));
            float l = inset.x + (rect.z - 2.0 * inset.x) * interval.x;
            float r = inset.x + (rect.z - 2.0 * inset.x) * interval.y;
            float region = smoothstep(l - 0.7, l + 0.5, uv.x)
                         * (1.0 - smoothstep(r - 0.5, r + 0.7, uv.x));
            float a = inside * region * flashAlpha * visibility;
            gl_FragColor = vec4(vec3(0.96, 0.985, 1.0), a);
            return;
        }

        float border = cover(roundedDistance(uv - halfSize, halfSize - vec2(1.1), radius - 0.45));
        float interior = cover(roundedDistance(uv - halfSize, innerHalf, innerR));
        float fillEnd = inset.x + (rect.z - 2.0 * inset.x) * clamp(health, 0.0, 1.0);
        float fillMask = 1.0 - smoothstep(fillEnd - 0.7, fillEnd + 0.7, uv.x);
        float filled = interior * fillMask;

        // The bar's rounded/cylindrical lighting and upper specular highlight.
        // Normalize vertically by HEIGHT so the shading survives width changes.
        float y = clamp(uv.y / max(rect.w, 1.0), 0.0, 1.0);
        // BAR healthbars interpolate red -> green, normalize by the largest
        // red/green channel, then darken the bottom to 50% brightness.
        float h = clamp(health, 0.0, 1.0);
        vec3 gameColor = vec3(1.0 - h, h, 0.0);
        gameColor /= max(max(gameColor.r, gameColor.g), 0.0001);
        vec3 gameBase = gameColor * (0.5 + 0.5 * y);
        vec3 playerBase = teamColor * (0.56 + 0.53 * smoothstep(0.0, 1.0, y));
        vec3 base = mix(gameBase, playerBase, usePlayerColor);
        base += vec3(0.067 * exp(-pow((y - 0.79) * 8.5, 2.0)));

        // Large, irregular features make the grain fit a wide boss-style bar.
        // Three different scales, in widget-local PIXELS (not bar-relative UV),
        // so resizing the bar does not squeeze or repeatedly tile the texture.
        // The waves have separate periods and noise-warped phases.
        float broad  = valueNoise(uv / vec2(184.0, 39.0) + vec2(2.4, 6.9));
        float medium = valueNoise(uv / vec2(59.0, 15.0) + vec2(9.7, 3.2));
        float detail = valueNoise(uv / vec2(13.0, 6.1) + vec2(4.3, 12.5));
        float grain = 0.60 * (broad - 0.5)
                    + 0.32 * (medium - 0.5)
                    + 0.08 * (detail - 0.5);
        float wave = sin(uv.x * 0.032 + uv.y * 0.19 + broad * 3.1)
                   * sin(uv.x * 0.013 - uv.y * 0.30 + medium * 2.4);
        // Procedural surface variation.
        float texture = 0.1 * grain + 0.02 * wave;
        vec3 background = vec3(0.035, 0.041, 0.052) + vec3(0.0045 * grain);
        base = clamp(base + vec3(texture), 0.0, 1.0);
        vec3 rgb = mix(background, base, filled);
        rgb = mix(vec3(0.07, 0.078, 0.095) + vec3(0.12) * y, rgb, interior);
        rgb = mix(vec3(0.025, 0.029, 0.037), rgb, border);
        float edgeLine = max(0.0, outer - border);
        rgb += vec3(0.27, 0.31, 0.36) * edgeLine;
        rgb += vec3(0.08) * exp(-pow((uv.y - rect.w + 2.7) * 1.15, 2.0)) * outer;
        // Missing health is transparent inside the opaque frame.
        // Interior coverage softens the rounded edge and health boundary.
        float interiorAlpha = mix(0.10, opacity, fillMask);
        float alpha = outer * mix(1.0, interiorAlpha, interior) * visibility;
        gl_FragColor = vec4(rgb, alpha);
    }
]]

local function DisableShader(problem)
    if shader then gl.DeleteShader(shader) end
    shader, uniforms = nil, nil
    UpdateSnapRect()
    Spring.Echo("[Commander Health Bar] Shader unavailable: " .. tostring(problem))
end

local function InitShader()
    if not (gl.CreateShader and gl.GetUniformLocation and gl.Uniform and gl.UseShader) then
        DisableShader("OpenGL shader functions are unavailable")
        return
    end
    local ok, result = pcall(gl.CreateShader, {
        vertex = [[
            #version 120
            void main() { gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex; }
        ]],
        fragment = FRAGMENT,
    })
    if not ok or not result or result == 0 then
        DisableShader(ok and (gl.GetShaderLog and gl.GetShaderLog() or "shader compilation failed") or result)
        return
    end
    shader = result
    local names = { "rect", "teamColor", "usePlayerColor", "health", "opacity", "visibility", "mode", "interval", "drop", "flashAlpha" }
    uniforms = {}
    for i = 1, #names do
        local location = gl.GetUniformLocation(shader, names[i])
        if location == nil or location < 0 then
            DisableShader("Missing uniform: " .. names[i])
            return
        end
        uniforms[names[i]] = location
    end
    Spring.Echo("[Commander Health Bar] Shader ready")
end

local function DrawShaderBar(x, y, w, h, frac, c, visibility, events)
    gl.UseShader(shader)
    gl.Uniform(uniforms.rect, x, y, w, h)
    gl.Uniform(uniforms.teamColor, c[1], c[2], c[3])
    local spectating = Spring.GetSpectatingState()
    local playerColor = config.playerColorMode == "Always"
        or (config.playerColorMode == "When spectating" and spectating)
    gl.Uniform(uniforms.usePlayerColor, playerColor and 1 or 0)
    gl.Uniform(uniforms.health, frac)
    gl.Uniform(uniforms.opacity, 0.98)
    gl.Uniform(uniforms.visibility, visibility)
    gl.Uniform(uniforms.mode, 0)
    gl.Uniform(uniforms.interval, 0, 1)
    gl.Uniform(uniforms.drop, 0)
    gl.Uniform(uniforms.flashAlpha, 0)
    gl.Color(1, 1, 1, 1)
    gl.Rect(x - 1, y - 1, x + w + 1, y + h + 1)
    gl.Uniform(uniforms.mode, 1)
    local duration = config.damageDurationMs * 0.001
    if duration > 0 then
        local hold = min(DAMAGE_HOLD, duration * 0.25)
        for i = 1, #events do
            local event = events[i]
            local t = Clamp(event.age / duration, 0, 1)
            local fall = Clamp((event.age - hold) / (duration - hold), 0, 1)
            local drop = (baseBarHeight * config.damageFallHeights) * fall ^ 1.2
            local fade = (1 - t) ^ 0.75
            gl.Uniform(uniforms.interval, event.left, event.right)
            gl.Uniform(uniforms.drop, drop)
            gl.Uniform(uniforms.flashAlpha, fade)
            gl.Rect(x - 1, y - drop - 1, x + w + 1, y + h - drop + 1)
        end
    end
end

local function RegisterOptions()
    if WG.options and WG.options.addOptions then
        WG.options.addOptions({
            {
                id = "commander_healthbar__show_while_spectating",
                widgetname = "Commander Health Bar",
                name = "Show while spectating",
                description = "Display the health bar while spectating.",
                type = "bool",
                value = config.showWhileSpectating,
                onchange = function(_, value)
                    config.showWhileSpectating = (value == true)
                    StartSettingsPreview()
                end,
            },
            {
                id = "commander_healthbar__use_player_color",
                widgetname = "Commander Health Bar",
                name = "Use player color",
                description = "Choose when to use the viewed team's color instead of health-based colors.",
                type = "select",
                options = PLAYER_COLOR_MODES,
                value = (config.playerColorMode == "Always" and 3)
                    or (config.playerColorMode == "When spectating" and 2) or 1,
                onchange = function(_, value)
                    config.playerColorMode = PLAYER_COLOR_MODES[tonumber(value)] or config.playerColorMode
                    StartSettingsPreview()
                end,
            },
            {
                id = "commander_healthbar__width",
                widgetname = "Commander Health Bar",
                name = "Width (%)",
                description = "Adjust the bar width relative to the automatic size.",
                type = "slider", min = 30, max = 200, step = 1,
                value = config.widthPercent,
                onchange = function(_, value)
                    config.widthPercent = Clamp(tonumber(value) or 100, 30, 200)
                    UpdatePos()
                    StartSettingsPreview()
                end,
            },
            {
                id = "commander_healthbar__height",
                widgetname = "Commander Health Bar",
                name = "Height (%)",
                description = "Adjust the bar height relative to the automatic size.",
                type = "slider", min = 50, max = 250, step = 1,
                value = config.heightPercent,
                onchange = function(_, value)
                    config.heightPercent = Clamp(tonumber(value) or 100, 50, 250)
                    UpdatePos()
                    StartSettingsPreview()
                end,
            },
            {
                id = "commander_healthbar__damage_fall_distance",
                widgetname = "Commander Health Bar",
                name = "Damage fall distance",
                description = "Distance the white damage segments fall, measured in bar heights at 100% height. Zero holds them in place.",
                type = "slider", min = 0, max = 100, step = 1,
                value = config.damageFallHeights,
                onchange = function(_, value)
                    config.damageFallHeights = Clamp(tonumber(value) or 0, 0, 100)
                    StartSettingsPreview()
                end,
            },
            {
                id = "commander_healthbar__damage_duration",
                widgetname = "Commander Health Bar",
                name = "Damage animation duration (ms)",
                description = "How long the white damage segments remain visible. Zero disables them.",
                type = "slider", min = 0, max = 2000, step = 50,
                value = config.damageDurationMs,
                onchange = function(_, value)
                    config.damageDurationMs = Clamp(tonumber(value) or 500, 0, 2000)
                    if config.damageDurationMs == 0 then
                        damageEvents, previewDamageEvents = {}, {}
                    end
                    StartSettingsPreview()
                end,
            },
        })
    end
end

local function RemoveTooltip()
    if WG.tooltip and WG.tooltip.RemoveTooltip then WG.tooltip.RemoveTooltip(SNAP_KEY) end
end

function widget:Initialize()
    lastSpectating = Spring.GetSpectatingState()
    commanderDefs = {}
    for defID, def in pairs(UnitDefs) do
        if def.customParams and def.customParams.iscommander ~= nil then
            commanderDefs[#commanderDefs + 1] = defID
        end
    end
    vsx, vsy = Spring.GetViewGeometry()
    InitShader()
    RefreshUnits()
    RefreshHealth()
    UpdatePos()
    RegisterOptions()
end

function widget:ViewResize(w, h)
    vsx, vsy = w, h
    UpdatePos()
end

function widget:PlayerChanged()
    ResetCommander(nil, nil)
    RefreshUnits()
    RefreshHealth()
end

-- BAR's LuaUI damage callin supplements the per-frame check. Reading the unit's
-- real HP here means we don't fabricate damage from shields or blocked attacks.
function widget:UnitDamaged(unitID)
    if unitID == commanderID and commanderCount == 1 then
        RefreshHealth()
    end
end

function widget:Update(dt)
    local spectating = Spring.GetSpectatingState()
    if spectating ~= lastSpectating then
        lastSpectating = spectating
        UpdateSnapRect()
    end
    -- Animate in display time, including while the game is paused.
    local duration = config.damageDurationMs * 0.001
    if duration <= 0 then
        damageEvents, previewDamageEvents = {}, {}
    else
        for _, events in ipairs({ damageEvents, previewDamageEvents }) do
            local i = 1
            while i <= #events do
                local event = events[i]
                event.age = event.age + dt
                if event.age >= duration then table.remove(events, i) else i = i + 1 end
            end
        end
    end

    if previewRemaining > 0 then
        previewRemaining = max(0, previewRemaining - max(dt, 0))
        if previewRemaining == 0 then
            previewDamageEvents = {}
            UpdateSnapRect()
        end
    end
    if InPreview() then
        testTimer = testTimer + dt
        if testTimer >= 1.5 then
            testTimer = testTimer - 1.5
            local before = testFrac
            if testFrac >= 0.999 then
                testFrac = 0.76
            else
                testFrac = testFrac <= 0.40 and 1.0 or (testFrac - 0.19)
            end
            AddDamage(before, testFrac, previewDamageEvents)
        end
    end

    -- Hold and fade use display time, including while paused.
    if fullHealElapsed ~= nil then
        fullHealElapsed = min(fullHealElapsed + max(dt, 0), FULL_HEALTH_HOLD + FULL_HEALTH_FADE)
        if fullHealElapsed >= FULL_HEALTH_HOLD + FULL_HEALTH_FADE then
            attentionActive = false
        end
        RefreshVisibility()
    end

    -- Track changes on each rendered update and after damage events.
    RefreshHealth()
    unitsTimer, layoutTimer = unitsTimer + dt, layoutTimer + dt
    if unitsTimer >= UNIT_POLL then
        unitsTimer = 0
        RefreshUnits()
        RefreshHealth()
    end
    if layoutTimer >= LAYOUT_POLL then
        layoutTimer = 0
        UpdatePos()
    end
end

function widget:DrawScreen()
    if Spring.IsGUIHidden() or not CanShow() then RemoveTooltip(); return end
    local c = color
    local fraction, current, maximum = healthFrac, hp, maxHP
    local preview = InPreview()
    if preview then
        fraction, current, maximum = testFrac, floor(testFrac * 10000), 10000
    end
    local team = commanderTeam or Spring.GetMyTeamID()
    if team then
        local r, g, b = Spring.GetTeamColor(team)
        if r and g and b then c = { r, g, b } end
    end

    local visibility = VisibilityAlpha()
    local events = preview and previewDamageEvents or damageEvents
    gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
    local ok, err = pcall(DrawShaderBar, pos.x, pos.y, pos.w, pos.h, fraction, c, visibility, events)
    gl.UseShader(0)
    if not ok then
        DisableShader(err)
        RemoveTooltip()
        return
    end

    local label = string.format("%d / %d", floor(current + 0.5), floor(maximum + 0.5))
    local size = max(11, min(17, floor(pos.h * 0.62)))
    gl.Color(1, 1, 1, 0.96 * visibility)
    if preview then
        local messageSize = max(8, min(size, floor(pos.w / 24)))
        gl.Text(PREVIEW_MESSAGE, pos.x + pos.w * 0.5, pos.y + pos.h * 0.5 - messageSize * 0.38, messageSize, "oc")
    else
        gl.Text(label, pos.x + pos.w * 0.5, pos.y + (pos.h - size) * 0.5 + 2, size, "oc")
    end
    gl.Color(1, 1, 1, 1)
    if WG.tooltip and WG.tooltip.AddTooltip and WG.snapRects and WG.snapRects[SNAP_KEY] then
        WG.tooltip.AddTooltip(SNAP_KEY, WG.snapRects[SNAP_KEY],
            "Ctrl + left-drag to move. Change size in Settings.",
            nil, "Commander Health Bar")
    end
end

function widget:IsAbove(x, y)
    return not Spring.IsGUIHidden() and CanShow()
        and x >= pos.x and x <= pos.x + pos.w and y >= pos.y and y <= pos.y + pos.h
end

function widget:MousePress(x, y, button)
    if button ~= 1 or not self:IsAbove(x, y) then return false end
    local _, ctrl = Spring.GetModKeyState()
    if not ctrl then return false end
    drag = { x - pos.x, y - pos.y }
    return true
end

function widget:MouseMove(x, y)
    if not drag then return end
    local nx, ny = SnapPos(x - drag[1], y - drag[2], pos.w, pos.h)
    nx = Clamp(nx, 0, max(0, vsx - pos.w))
    ny = Clamp(ny, 0, max(0, vsy - pos.h))
    userPos = { nx / vsx, ny / vsy }
    UpdatePos()
    return true
end

function widget:MouseRelease()
    drag = nil
    return false
end

function widget:GetTooltip(x, y)
    if self:IsAbove(x, y) then
        return "Commander Health Bar\nCtrl + left-drag to move. Change size in Settings."
    end
end

function widget:GetConfigData()
    return {
        userPos = userPos,
        widthPercent = config.widthPercent,
        heightPercent = config.heightPercent,
        damageFallHeights = config.damageFallHeights,
        damageDurationMs = config.damageDurationMs,
        playerColorMode = config.playerColorMode,
        showWhileSpectating = config.showWhileSpectating,
    }
end

function widget:SetConfigData(data)
    if type(data) ~= "table" then return end
    local width = tonumber(data.widthPercent)
    local height = tonumber(data.heightPercent)
    local fall = tonumber(data.damageFallHeights)
    local duration = tonumber(data.damageDurationMs)
    if data.playerColorMode == "Never" or data.playerColorMode == "When spectating"
        or data.playerColorMode == "Always" then
        config.playerColorMode = data.playerColorMode
    end
    if type(data.showWhileSpectating) == "boolean" then config.showWhileSpectating = data.showWhileSpectating end
    if width and width == width then config.widthPercent = Clamp(width, 30, 200) end
    if height and height == height then config.heightPercent = Clamp(height, 50, 250) end
    if fall and fall == fall then config.damageFallHeights = Clamp(fall, 0, 100) end
    if duration and duration == duration then
        config.damageDurationMs = Clamp(duration, 0, 2000)
        if config.damageDurationMs == 0 then damageEvents = {} end
    end
    if type(data.userPos) == "table" then
        local x, y = tonumber(data.userPos[1]), tonumber(data.userPos[2])
        if x and y and x == x and y == y then
            userPos = { Clamp(x, 0, 1), Clamp(y, 0, 1) }
        end
    end
    UpdatePos()
end

function widget:Shutdown()
    RemoveTooltip()
    if WG.options and WG.options.removeOptions then
        WG.options.removeOptions({
            "commander_healthbar__show_while_spectating",
            "commander_healthbar__use_player_color",
            "commander_healthbar__width",
            "commander_healthbar__height",
            "commander_healthbar__damage_fall_distance",
            "commander_healthbar__damage_duration",
        })
    end
    if WG.snapRects then WG.snapRects[SNAP_KEY] = nil end
    if shader then gl.DeleteShader(shader); shader = nil end
end
