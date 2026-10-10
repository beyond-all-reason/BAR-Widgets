local widget = widget

function widget:GetInfo()
    return {
        name = "Pinpointer Counter",
        desc = "Active Pinpointers in the viewed player's allyteam. Ctrl + left-drag to reposition.",
        author = "Devin Jacobs",
        date = "October 2026",
        license = "GNU GPL, v2 or later",
        layer = 100,
        enabled = true,
    }
end

-- Set true to cycle the displayed count from 0 through 4 once per second.
local TEST_COUNT_CYCLE = false
local testCountElapsed = 0

local SNAP_KEY = 'pinpointercounter'
local SNAP_DIST, SNAP_GAP, SNAP_NEAR, SNAP_GRID = 10, 5, 40, 16
local LAYOUT_REFRESH_INTERVAL = 0.25
local TEXTURE_PADDING = 3
local vsx, vsy = 1920, 1080
local pos = { x = 0, y = 0, s = 34, w = 80 }
local userPos, drag, cachedFont
local definitions = {}
local count, viewedTeam, elapsed = 0, nil, 0
local layoutElapsed = 0
local textureCache, textureWidth, textureHeight
local textureDirty, cachedOpacity, cacheDisabled = true, nil, false
-- BAR IceXuick V6 team palette, from game_autocolors.lua.
local colors = {
    { 255 / 255, 16 / 255, 5 / 255 },   -- #FF1005 red
    { 255 / 255, 97 / 255, 7 / 255 },   -- #FF6107 orange
    { 255 / 255, 210 / 255, 0 },        -- #FFD200 yellow
    { 12 / 255, 233 / 255, 8 / 255 },   -- #0CE908 bright green
}
local shader, uniforms
local tooltipText = "The number of active Pinpointers. Three is plenty in most cases.\n"
    .. "Ctrl + left mouse click to drag."

local config = {
    hideAtZero = false,
}

local OPTION_SPECS = {
    {
        configVariable = "hideAtZero",
        name = "Hide counter when there are no Pinpointers",
        description = "Hide Pinpointer count widget when there are none",
        type = "bool",
    },
}

local function IsHidden()
    return config.hideAtZero and count == 0
end

local function UpdateSnapRect()
    WG.snapRects = WG.snapRects or {}
    if IsHidden() then
        WG.snapRects[SNAP_KEY] = nil
    else
        WG.snapRects[SNAP_KEY] = { pos.x, pos.y, pos.x + pos.w, pos.y + pos.s }
    end
end

local function RegisterOptions()
    if not (WG.options and WG.options.addOptions) then return end
    local options = {}
    for _, spec in ipairs(OPTION_SPECS) do
        options[#options + 1] = {
            id = "pinpointer_counter__" .. spec.configVariable,
            widgetname = "Pinpointer Counter",
            name = spec.name,
            description = spec.description,
            type = spec.type,
            value = config[spec.configVariable],
            onchange = function(_, value)
                config[spec.configVariable] = value
                textureDirty = true
                UpdateSnapRect()
            end,
        }
    end
    WG.options.addOptions(options)
end

local function UnregisterOptions()
    if not (WG.options and WG.options.removeOptions) then return end
    WG.options.removeOptions({ "pinpointer_counter__hideAtZero" })
end

local function RemoveTooltip()
    if WG.tooltip and WG.tooltip.RemoveTooltip then
        WG.tooltip.RemoveTooltip(SNAP_KEY)
    end
end

local function DisableShader(reason)
    if shader then gl.DeleteShader(shader); shader = nil end
    textureDirty = true
    if Spring.Echo then Spring.Echo('[Pinpointer Counter] Target graphic disabled: ' .. tostring(reason)) end
end

local function SetCount(value)
    if count ~= value then
        count = value
        textureDirty = true
        UpdateSnapRect()
    end
end

local function InitShader()
    if not (gl.CreateShader and gl.UseShader and gl.GetUniformLocation and gl.Uniform) then return end
    local ok, result = pcall(gl.CreateShader, {
        vertex = [[
            #version 120
            void main() { gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex; }
        ]],
        fragment = [[
            #version 120
            uniform vec2 center;
            uniform float radius;
            uniform float filled;
            uniform vec3 fillColor;
            uniform vec4 outlineColor;
            // Signed-distance coverage: a one-pixel transparent edge transition.
            float coverage(float distance) {
                return 1.0 - smoothstep(-0.5, 0.5, distance);
            }
            void main() {
                float r = length(gl_FragCoord.xy - center);
                float stepSize = radius / 5.0;
                float border = min(0.8, stepSize * 0.22);
                float gap = stepSize * 0.20;
                float ink = 0.0;
                float outlines = 0.0;
                for (int i = 1; i <= 5; ++i) {
                    float edge = float(i) * stepSize;
                    if (float(i) <= filled) {
                        float outer = edge - border;
                        float inner = float(i - 1) * stepSize + gap;
                        float sd = i == 1 ? r - outer : max(inner - r, r - outer);
                        ink = max(ink, coverage(sd));
                    }
                    float ringDistance = abs(r - (edge - border * 0.5)) - border * 0.5;
                    outlines = max(outlines, coverage(ringDistance));
                }
                float ca = ink * 0.95;
                float oa = outlines * outlineColor.a;
                float alpha = oa + ca * (1.0 - oa);
                vec3 rgb = outlineColor.rgb * oa + fillColor * ca * (1.0 - oa);
                gl_FragColor = vec4(rgb / max(alpha, 0.00001), alpha);
            }
        ]],
    })
    if not ok or not result or result == 0 then
        DisableShader(ok and (gl.GetShaderLog and gl.GetShaderLog() or 'shader compilation failed') or result)
        return
    end
    shader = result
    local locationsOK, locations = pcall(function()
        local result = {}
        for _, name in ipairs({ 'center', 'radius', 'filled', 'fillColor', 'outlineColor' }) do
            result[name] = gl.GetUniformLocation(shader, name)
            assert(result[name] and result[name] >= 0, 'Missing uniform: ' .. name)
        end
        return result
    end)
    if locationsOK then uniforms = locations else DisableShader(locations) end
end

local function DrawTarget(cx, cy, radius, color, opacity)
    if not shader then return end
    gl.UseShader(shader)
    gl.Uniform(uniforms.center, cx, cy)
    gl.Uniform(uniforms.radius, radius)
    gl.Uniform(uniforms.filled, math.max(1, 5 - count))
    gl.Uniform(uniforms.fillColor, color[1], color[2], color[3])
    gl.Uniform(uniforms.outlineColor, 0.12, 0.12, 0.12, opacity)
    -- Extra pixel leaves room for feathering outside the outer boundary.
    local extent = radius + 1
    gl.Rect(cx - extent, cy - extent, cx + extent, cy + extent)
    gl.UseShader(0)
end

local function RefreshCount()
    viewedTeam = Spring.GetMyTeamID()
    if TEST_COUNT_CYCLE then
        SetCount(math.floor(testCountElapsed) % 5)
        return
    end
    local allyTeam = Spring.GetMyAllyTeamID()
    local newCount = 0
    if #definitions == 0 then
        SetCount(newCount)
        return
    end
    -- Query only targeting-upgrade units in the selected allyteam. Polling also
    -- handles activation, destruction, captures, gifts and replay seeking.
    for _, teamID in ipairs(Spring.GetTeamList(allyTeam) or {}) do
        for _, unitID in ipairs(Spring.GetTeamUnitsByDefs(teamID, definitions) or {}) do
            if Spring.GetUnitIsBeingBuilt(unitID) == false
                and Spring.GetUnitIsActive(unitID) == true then
                newCount = newCount + 1
            end
        end
    end
    SetCount(newCount)
end

local function SnapPos(x, y, w, h)
    local rects = {}
    if WG.snapRects then
        for k, r in pairs(WG.snapRects) do
            if k ~= SNAP_KEY then rects[#rects + 1] = r end
        end
    end
    local mpx, mpy, msx, msy = Spring.GetMiniMapGeometry()
    if msx and msx > 0 then rects[#rects + 1] = { mpx, mpy, mpx + msx, mpy + msy } end
    local tb = WG['topbar'] and WG['topbar'].GetPosition and WG['topbar'].GetPosition()
    if tb then rects[#rects + 1] = { tb[1], tb[2], math.min(tb[3] or vsx, vsx), vsy } end

    local bestDX, bestDY
    for i = 1, #rects do
        local r = rects[i]
        if y < r[4] + SNAP_NEAR and y + h > r[2] - SNAP_NEAR then
            local cands = { r[1], r[3] - w, r[3] + SNAP_GAP, r[1] - w - SNAP_GAP }
            for j = 1, 4 do
                local d = cands[j] - x
                if math.abs(d) <= SNAP_DIST and (not bestDX or math.abs(d) < math.abs(bestDX)) then bestDX = d end
            end
        end
        if x < r[3] + SNAP_NEAR and x + w > r[1] - SNAP_NEAR then
            local cands = { r[2], r[4] - h, r[4] + SNAP_GAP, r[2] - h - SNAP_GAP }
            for j = 1, 4 do
                local d = cands[j] - y
                if math.abs(d) <= SNAP_DIST and (not bestDY or math.abs(d) < math.abs(bestDY)) then bestDY = d end
            end
        end
    end
    -- dense-net fallback per axis: free placements still stick to a grid
    if not bestDX then bestDX = math.floor(x / SNAP_GRID + 0.5) * SNAP_GRID - x end
    if not bestDY then bestDY = math.floor(y / SNAP_GRID + 0.5) * SNAP_GRID - y end
    return x + bestDX, y + bestDY
end

local function UpdatePos()
    local oldS, oldW, oldFont = pos.s, pos.w, cachedFont
    cachedFont = WG.fonts and WG.fonts.getFont and WG.fonts.getFont(2)
    local fs
    local tb = WG.topbar and WG.topbar.GetPosition and WG.topbar.GetPosition()
    local free = WG.topbar and WG.topbar.GetFreeArea and WG.topbar.GetFreeArea()
    if tb and free then
        local h = vsy - tb[2]
        pos.s = math.max(24, math.floor(h * 0.98))
        pos.y = math.floor(tb[2] + (h - pos.s) * 0.5)
        local baseX = free[1]
        local cu = WG.converter_usage and WG.converter_usage.GetPosition and WG.converter_usage.GetPosition()
        if cu and cu[3] then baseX = math.max(baseX, cu[3]) end
        -- Leave room for the supplied Energy Conversion Meter when enabled.
        local ec = WG.snapRects and WG.snapRects.energyconvmeter
        if ec then baseX = math.max(baseX, ec[3]) end
        pos.x = math.floor(baseX + 12)
    else
        pos.s = math.floor(34 * math.max(0.7, vsy / 1080))
        pos.x, pos.y = math.floor(vsx * 0.72), vsy - pos.s - 4
    end
    fs = pos.s * 0.40
    local sample = #tostring(count) > 2 and tostring(count) or '99'
    local textWidth = (cachedFont and cachedFont:GetTextWidth(sample)) or gl.GetTextWidth(sample)
    pos.w = math.ceil(pos.s * 1.35 + textWidth * fs)
    if userPos then pos.x, pos.y = userPos[1] * vsx, userPos[2] * vsy end
    pos.x = math.floor(math.max(0, math.min(pos.x, vsx - pos.w)))
    pos.y = math.floor(math.max(0, math.min(pos.y, vsy - pos.s)))

    -- Other widgets use this rectangle for snapping. Publish it when the
    -- layout changes instead of allocating a new table every rendered frame.
    UpdateSnapRect()
    if oldS ~= pos.s or oldW ~= pos.w or oldFont ~= cachedFont then
        textureDirty = true
    end
end

function widget:Initialize()
    definitions = {}
    testCountElapsed = 0
    for id, def in pairs(UnitDefs) do
        if def.isTargetingUpgrade then definitions[#definitions + 1] = id end
    end
    vsx, vsy = Spring.GetViewGeometry()
    RefreshCount()
    UpdatePos()
    InitShader()
    RegisterOptions()
end

function widget:ViewResize(x, y)
    vsx, vsy = x, y
    UpdatePos()
end

function widget:PlayerChanged()
    RefreshCount()
end

function widget:Update(dt)
    if TEST_COUNT_CYCLE then
        -- Update's dt advances while paused; use cumulative time to preserve
        -- fractional seconds and catch up correctly after a long frame.
        testCountElapsed = testCountElapsed + dt
        -- SetCount also applies Hide when there are no Pinpointers, so a
        -- cycle through zero exercises the setting's hidden state.
        SetCount(math.floor(testCountElapsed) % 5)
    else
        elapsed = elapsed + dt
        if Spring.GetMyTeamID() ~= viewedTeam or elapsed >= 0.5 then
            elapsed = 0
            RefreshCount()
        end
    end

    -- Topbar and neighboring widget positions change infrequently. Recompute
    -- layout at 4 Hz, while keeping the actual HUD draw current every frame.
    layoutElapsed = layoutElapsed + dt
    if layoutElapsed >= LAYOUT_REFRESH_INTERVAL then
        layoutElapsed = 0
        UpdatePos()
    end
end

local function DrawCounterContent(x, y, s, w, opacity)
    local fui = WG.FlowUI and WG.FlowUI.Draw
    if fui and fui.Element then
        fui.Element(x, y, x + w, y + s, 1, 1, 1, 1, 1, 1, 1, 1)
    else
        gl.Color(0, 0, 0, 0.55)
        gl.Rect(x, y, x + w, y + s)
    end
    gl.Texture(false)
    local cx, cy = x + s * 0.57, y + s * 0.5
    local radius = s * 0.40
    local color = colors[math.min(count + 1, 4)]
    if config.hideAtZero and count == 1 then color = colors[1] end
    if shader then
        gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
        local ok, err = pcall(DrawTarget, cx, cy, radius, color, opacity)
        -- Restore the pipeline before independently drawing the count.
        gl.UseShader(0)
        if not ok then DisableShader(err) end
    end
    local fs = s * 0.40
    local tx, ty = x + s * 1.14, cy - fs * 0.36
    if cachedFont then
        cachedFont:Begin()
        cachedFont:SetTextColor(1, 1, 1, 0.95)
        cachedFont:SetOutlineColor(0, 0, 0, 1)
        cachedFont:Print(tostring(count), tx, ty, fs, 'o')
        cachedFont:End()
    else
        gl.Color(1, 1, 1, 0.95)
        gl.Text(tostring(count), tx, ty, fs, 'o')
    end
    gl.Color(1, 1, 1, 1)
end

local function EnsureTexture()
    local width = math.max(1, math.ceil(pos.w + TEXTURE_PADDING * 2))
    local height = math.max(1, math.ceil(pos.s + TEXTURE_PADDING * 2))
    if textureCache and (textureWidth ~= width or textureHeight ~= height) then
        gl.DeleteTexture(textureCache)
        textureCache = nil
        textureDirty = true
    end
    if not textureCache and not cacheDisabled and gl.CreateTexture and gl.R2tHelper then
        local ok, result = pcall(gl.CreateTexture, width, height, {
            target = GL.TEXTURE_2D,
            format = GL.RGBA,
            fbo = true,
        })
        if ok and result and result ~= 0 then
            textureCache = result
            textureWidth, textureHeight = width, height
            textureDirty = true
        else
            cacheDisabled = true
        end
    end
    return textureCache ~= nil
end

local function RefreshTexture(opacity)
    if not EnsureTexture() then return false end
    if textureDirty or cachedOpacity ~= opacity then
        local width, height = textureWidth, textureHeight
        local ok, result = pcall(gl.R2tHelper.RenderToTexture, textureCache, function()
            -- Match the pixel-to-clip transform used by BAR's cached widgets.
            gl.Translate(-1, -1, 0)
            gl.Scale(2 / width, 2 / height, 0)
            DrawCounterContent(TEXTURE_PADDING, TEXTURE_PADDING, pos.s, pos.w, opacity)
        end, true)
        if not ok or result == false then
            gl.DeleteTexture(textureCache)
            textureCache = nil
            cacheDisabled = true
            return false
        end
        textureDirty = false
        cachedOpacity = opacity
    end
    return true
end

function widget:DrawScreen()
    if Spring.IsGUIHidden() or IsHidden() then RemoveTooltip(); return end
    local x, y, s, w = pos.x, pos.y, pos.s, pos.w
    local opacity = WG.FlowUI and WG.FlowUI.opacity or 0.7
    if RefreshTexture(opacity) then
        local ok = pcall(gl.R2tHelper.BlendTexRect, textureCache,
            x - TEXTURE_PADDING, y - TEXTURE_PADDING,
            x + w + TEXTURE_PADDING, y + s + TEXTURE_PADDING, true)
        if not ok then
            gl.DeleteTexture(textureCache)
            textureCache = nil
            cacheDisabled = true
            DrawCounterContent(x, y, s, w, opacity)
        end
    else
        DrawCounterContent(x, y, s, w, opacity)
    end
    if WG.tooltip and WG.tooltip.AddTooltip then
        WG.tooltip.AddTooltip(SNAP_KEY, WG.snapRects[SNAP_KEY], tooltipText, nil, 'Pinpointer Counter')
    end
    gl.Color(1, 1, 1, 1)
end

function widget:IsAbove(mx, my)
    return not Spring.IsGUIHidden() and not IsHidden()
        and mx >= pos.x and mx <= pos.x + pos.w
        and my >= pos.y and my <= pos.y + pos.s
end

function widget:MousePress(mx, my, button)
    if button ~= 1 or not self:IsAbove(mx, my) then return false end
    local _, ctrl = Spring.GetModKeyState()
    if not ctrl then return false end
    drag = { mx - pos.x, my - pos.y }
    return true
end

function widget:MouseMove(mx, my)
    if not drag then return end
    local x, y = SnapPos(mx - drag[1], my - drag[2], pos.w, pos.s)
    userPos = { math.max(0, math.min(x, vsx - pos.w)) / vsx,
        math.max(0, math.min(y, vsy - pos.s)) / vsy }
    UpdatePos()
    return true
end

function widget:MouseRelease()
    drag = nil
    return false
end

function widget:GetConfigData()
    return { userPos = userPos, hideAtZero = config.hideAtZero }
end

function widget:SetConfigData(data)
    if data and type(data.hideAtZero) == 'boolean' then
        config.hideAtZero = data.hideAtZero
    end
    if data and type(data.userPos) == 'table' then
        local x, y = tonumber(data.userPos[1]), tonumber(data.userPos[2])
        if x and y and x == x and y == y then
            userPos = { math.max(0, math.min(x, 1)), math.max(0, math.min(y, 1)) }
        end
    end
end

function widget:GetTooltip(mx, my)
    if self:IsAbove(mx, my) then return 'Pinpointer Counter\n' .. tooltipText end
end

function widget:Shutdown()
    RemoveTooltip()
    UnregisterOptions()
    if shader then gl.DeleteShader(shader); shader = nil end
    if textureCache then gl.DeleteTexture(textureCache); textureCache = nil end
    if WG.snapRects then WG.snapRects[SNAP_KEY] = nil end
end
