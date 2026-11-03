local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name    = "Zombie Wreck Timers",
		desc    = "When the Zombies modoption is on, shows a countdown over each wreck until it reanimates. Reacts instantly when a corpse is reclaimed or resurrected. Display only.",
		author  = "SethDGamre + Egzothicki",
		date    = "August 2026",
		license = "GNU GPL, v2 or later",
		layer   = 10,
		enabled = true,
	}
end

local textSize    = 16
local heightBonus = 25
local maxDrawDist = 5500
local warnSeconds = 15

local ZOMBIE_REZ_FRAME_PARAM = "zombie_rez_frame"

-- royal purple ladder: white with plenty of time, purple as the rise nears
local COL_FAR    = { 0.95, 0.95, 0.95 } -- > 2 min
local COL_NEAR   = { 0.62, 0.44, 1.00 } -- 2..1 min
local COL_CLOSE  = { 0.47, 0.24, 0.95 } -- 60..15s
local COL_MIST   = { 0.36, 0.12, 0.85 } -- < 15s, pulsing
local COL_HIDDEN = { 0.45, 0.15, 0.90 } -- "?" for wrecks in the fog

local gameSpeed = Game.gameSpeed
local maxDistSq = maxDrawDist * maxDrawDist
local syncInterval = gameSpeed
local touchPollInterval = 6 -- frames between tamper-detection polls (~5x per second)

local spGetFeaturePosition   = Spring.GetFeaturePosition
local spGetFeatureRulesParam = Spring.GetFeatureRulesParam
local spGetFeatureResources  = Spring.GetFeatureResources
local spGetFeatureHealth     = Spring.GetFeatureHealth
local spIsPosInLos           = Spring.IsPosInLos
local spGetGameFrame         = Spring.GetGameFrame
local spGetCameraPosition    = Spring.GetCameraPosition
local spIsGUIHidden          = Spring.IsGUIHidden
local spValidFeatureID       = Spring.ValidFeatureID

local glPushMatrix = gl.PushMatrix
local glPopMatrix  = gl.PopMatrix
local glTranslate  = gl.Translate
local glBillboard  = gl.Billboard
local glText       = gl.Text
local glDepthTest  = gl.DepthTest
local glColor      = gl.Color

local floor = math.floor
local ceil = math.ceil
local max = math.max
local min = math.min
local sin   = math.sin
local abs   = math.abs
local format = string.format

local tracked = {}
local trackedCount = 0

-- Game state panel, fed by the game rules params the zombie gadget publishes
local TECH_LEVEL_PARAM = "zombie_tech_level"
local REZ_SPEED_PARAM = "zombie_rez_power_speed"
local LAB_MULTIPLIER_PARAM = "zombie_factory_buildpower_multiplier"
local TECH_LEVEL_MIN = 0.5 -- the gadget's tech estimate range
local TECH_LEVEL_MAX = 4.5
local REZ_SPEED_MAX = 130 -- the gadget's rez power speed at tech 4.5
local LAB_MULTIPLIER_MAX = 1.7 ^ 4.5 -- the gadget's lab buildpower multiplier at tech 4.5
-- the gadget clamps every wreck timer between these, overridable by the same customparams it reads
local RESPAWN_DELAY_MIN_PARAM = "zombie_minimum_respawn_delay"
local RESPAWN_DELAY_MAX_PARAM = "zombie_maximum_respawn_delay"
local respawnDelayMin = 45
local respawnDelayMax = 120

local PANEL_MODES = { "None", "Basic", "Advanced" }
local PANEL_OPTION_ID = "zombie_wreck_timers__panelMode"
local PANEL_ROWS = {
	tech = { label = "Tech", advancedOnly = true },
	rising = { label = "Rising" },
	labs = { label = "Labs" },
}
local PANEL_ROW_ORDER = { "tech", "rising", "labs" }
local PANEL_VALUE_SAMPLES = { tech = "4.5 / 4.5", rising = "130 / 130 (120-120s)", labs = "10.9x / 10.9x" }

local PANEL_SIZE_FRAC = 0.98 -- element height as a fraction of the top bar height
local PANEL_ANCHOR_MARGIN = 12
local PANEL_ICON = "icons/inverted/skull.png"
local PANEL_ICON_FRAC = 0.62
local PANEL_PAD_FRAC = 0.16
local PANEL_GAP_FRAC = 0.14
local PANEL_BAR_WIDTH_FRAC = 3.0 -- in element heights
local PANEL_BAR_HEIGHT_FRAC = 0.13
local PANEL_FONT_FRAC = { [2] = 0.28, [3] = 0.23 } -- by row count
local PANEL_ROW_OFFSETS = { [2] = { 0.22, -0.22 }, [3] = { 0.3, 0, -0.3 } } -- in element heights from the center
local PANEL_FILL_SPEED = 4 -- bar fill eases toward its target at this rate per second
local PANEL_SKEW_SIDE_PAD_FRAC = 0.7 -- the skewed bottom cut eats into the sides, so pad them by this much of it
local PANEL_CORNER_FRAC = 0.16
local PANEL_TEXT_BASELINE_FRAC = 0.36 -- font:Print draws from the baseline, this centers the text vertically
local PANEL_FALLBACK_HEIGHT = 34 -- when there is no top bar to size against, at 1080p
local PANEL_FALLBACK_X_FRAC = 0.8
local REFERENCE_SCREEN_HEIGHT = 1080
-- bar color ramps from light to deep purple as it fills, the same ladder as the ramp indicator
local BAR_COLOR_RAMP = {
	{ 0.86, 0.74, 1.00 },
	{ 0.78, 0.60, 0.97 },
	{ 0.70, 0.46, 0.94 },
	{ 0.62, 0.33, 0.90 },
	{ 0.54, 0.22, 0.83 },
	{ 0.46, 0.12, 0.73 },
	{ 0.38, 0.05, 0.60 },
	{ 0.30, 0.00, 0.48 },
}
local TOOLTIP_NAME = "zombiewrecktimers_tech"

local panelMode = "Basic"
local panel = { x = 0, y = 0, w = 0, h = 34 }
local panelUserPos = nil
local panelDrag = nil
local shownFill = { tech = 0, rising = 0, labs = 0 }
local lastDrawClock = os.clock()
local vsx, vsy = Spring.GetViewGeometry()

local spGetGameRulesParam = Spring.GetGameRulesParam
local glTexture = gl.Texture
local glTexRect = gl.TexRect
local glRect = gl.Rect
local glGetTextWidth = gl.GetTextWidth

local function untrackFeature(featureID)
	if tracked[featureID] then
		tracked[featureID] = nil
		trackedCount = trackedCount - 1
	end
end

local function tryAddFeature(featureID, knownCreation)
	if tracked[featureID] then
		return
	end

	local spawnFrame = spGetFeatureRulesParam(featureID, ZOMBIE_REZ_FRAME_PARAM)
	if not spawnFrame then
		return
	end

	local x, y, z = spGetFeaturePosition(featureID)
	if not x then
		return
	end

	local data = {
		spawnFrame = spawnFrame,
		x = x,
		y = y,
		z = z,
		hidden = false,
	}
	-- seen from birth: the param minus now is this corpse's exact full delay,
	-- which is what the gadget re-arms to when the corpse gets touched
	if knownCreation then
		local frame = spGetGameFrame()
		if spawnFrame > frame then
			data.delayFrames = spawnFrame - frame
		end
	end
	tracked[featureID] = data
	trackedCount = trackedCount + 1
end

local function syncTrackedFeature(featureID, data, frame)
	local spawnFrame = spGetFeatureRulesParam(featureID, ZOMBIE_REZ_FRAME_PARAM)

	if not spawnFrame or not spValidFeatureID(featureID) then
		-- unreadable: gone for real (we can see the spot), or just fogged
		if spIsPosInLos(data.x, data.y, data.z) then
			untrackFeature(featureID)
		else
			data.hidden = true -- timer may get reset unseen: show "?"
		end
		return
	end

	local x, y, z = spGetFeaturePosition(featureID)
	if not x then
		if spIsPosInLos(data.x, data.y, data.z) then
			untrackFeature(featureID)
		else
			data.hidden = true
		end
		return
	end

	if frame > spawnFrame + gameSpeed then
		untrackFeature(featureID)
		return
	end

	if data.spawnFrame ~= spawnFrame then
		data.displaySec = nil
		data.predictedFrame = nil -- the gadget published the real reset; it wins
	end

	if data.hidden then
		data.lastMetal = nil -- fog gap: reseed before trusting change detection
	end
	data.hidden = false
	data.spawnFrame = spawnFrame
	data.x = x
	data.y = y
	data.z = z
end

-- The gadget postpones the spawn to (last touch + full delay) whenever a build
-- step hits the corpse, but only publishes the new frame once the old one
-- expires. Reclaim and resurrect progress are visible on screen, so watch them
-- and predict the reset instantly; the published value reconciles it later.
local function pollTampering(frame)
	for featureID, data in pairs(tracked) do
		if not data.hidden and data.delayFrames then
			local metal, _, _, _, reclaimLeft = spGetFeatureResources(featureID)
			if metal then
				local _, _, rezProgress = spGetFeatureHealth(featureID)
				reclaimLeft = reclaimLeft or 1
				rezProgress = rezProgress or 0
				if data.lastMetal and (abs(metal - data.lastMetal) > 0.01
					or abs(reclaimLeft - data.lastReclaimLeft) > 0.0001
					or abs(rezProgress - data.lastRezProgress) > 0.0001) then
					data.predictedFrame = frame + data.delayFrames
				end
				data.lastMetal = metal
				data.lastReclaimLeft = reclaimLeft
				data.lastRezProgress = rezProgress
			end
		end
	end
end

local function getDisplayText(data, remainingSec)
	if data.displaySec == remainingSec then
		return data.text
	end

	local text
	if remainingSec >= 60 then
		text = format("%d:%02d", floor(remainingSec / 60), remainingSec % 60)
	else
		text = format("%d", remainingSec)
	end

	data.displaySec = remainingSec
	data.text = text
	return text
end

local function getPanelFont()
	return WG["fonts"] and WG["fonts"].getFont and WG["fonts"].getFont(2)
end

local function panelTextWidth(text, fontSize)
	local font = getPanelFont()
	return ((font and font:GetTextWidth(text)) or glGetTextWidth(text) or 0) * fontSize
end

local function readRespawnDelayClamps()
	for _, unitDef in pairs(UnitDefs) do
		local params = unitDef.customParams
		respawnDelayMin = tonumber(params[RESPAWN_DELAY_MIN_PARAM]) or respawnDelayMin
		respawnDelayMax = tonumber(params[RESPAWN_DELAY_MAX_PARAM]) or respawnDelayMax
	end
end

local function isAdvanced()
	return panelMode == "Advanced"
end

local function visibleRows()
	local rows = {}
	for i = 1, #PANEL_ROW_ORDER do
		local key = PANEL_ROW_ORDER[i]
		if isAdvanced() or not PANEL_ROWS[key].advancedOnly then
			rows[#rows + 1] = key
		end
	end
	return rows
end

local function updatePanel()
	local topbar = WG["topbar"]
	local topbarPos = topbar and topbar.GetPosition and topbar.GetPosition()
	local freeArea = topbar and topbar.GetFreeArea and topbar.GetFreeArea()
	local s
	if topbarPos and freeArea then
		local barHeight = vsy - topbarPos[2]
		s = floor(barHeight * PANEL_SIZE_FRAC)
		panel.y = floor(topbarPos[2] + (barHeight - s) * 0.5)
		local baseX = freeArea[1]
		for _, name in ipairs({ "converter_usage", "energy_conversion_meter" }) do
			local other = WG[name] and WG[name].GetPosition and WG[name].GetPosition()
			if other and other[3] and other[3] > baseX then
				baseX = other[3]
			end
		end
		panel.x = floor(baseX + PANEL_ANCHOR_MARGIN)
	else
		s = floor(PANEL_FALLBACK_HEIGHT * max(0.7, vsy / REFERENCE_SCREEN_HEIGHT))
		panel.y = vsy - s - 4
		panel.x = floor(vsx * PANEL_FALLBACK_X_FRAC)
	end
	panel.h = s

	local skewConfig = topbar and topbar.GetSkewConfig and topbar.GetSkewConfig()
	panel.skew = (skewConfig and skewConfig.useSkew)
			and { blx = s * skewConfig.skewTan, brx = -(s * skewConfig.skewTan) }
		or nil
	local sidePad = panel.skew and floor(s * skewConfig.skewTan * PANEL_SKEW_SIDE_PAD_FRAC) or 0
	panel.rows = visibleRows()
	local rowCount = #panel.rows
	panel.pad = max(3, floor(s * PANEL_PAD_FRAC)) + sidePad
	panel.gap = floor(s * PANEL_GAP_FRAC)
	panel.icon = floor(s * PANEL_ICON_FRAC)
	panel.font = s * (PANEL_FONT_FRAC[rowCount] or PANEL_FONT_FRAC[3])
	panel.rowOffsets = PANEL_ROW_OFFSETS[rowCount] or PANEL_ROW_OFFSETS[3]
	panel.labelWidth = 0
	panel.valueWidth = 0
	for i = 1, rowCount do
		local key = panel.rows[i]
		panel.labelWidth = max(panel.labelWidth, ceil(panelTextWidth(PANEL_ROWS[key].label, panel.font)))
		if isAdvanced() then
			local sampleWidth = ceil(panelTextWidth(PANEL_VALUE_SAMPLES[key], panel.font))
			panel.valueWidth = max(panel.valueWidth, sampleWidth)
		end
	end
	panel.barWidth = floor(s * PANEL_BAR_WIDTH_FRAC)
	panel.barHeight = max(2, floor(s * PANEL_BAR_HEIGHT_FRAC))
	panel.w = panel.pad + panel.icon + panel.gap + panel.labelWidth + panel.gap + panel.barWidth + panel.pad
	if isAdvanced() then
		panel.w = panel.w + panel.gap + panel.valueWidth
	end

	if panelUserPos then
		panel.x = floor(max(0, min(panelUserPos[1] * vsx, vsx - panel.w)))
		panel.y = floor(max(0, min(panelUserPos[2] * vsy, vsy - panel.h)))
	end
end

local function readTechState()
	local techLevel = spGetGameRulesParam(TECH_LEVEL_PARAM)
	if not techLevel then
		return nil
	end
	return techLevel, spGetGameRulesParam(REZ_SPEED_PARAM) or 0, spGetGameRulesParam(LAB_MULTIPLIER_PARAM) or 1
end

local function panelShown()
	return panelMode ~= "None" and readTechState() ~= nil
end

local function drawPanelElement()
	local flowDraw = WG.FlowUI and WG.FlowUI.Draw
	local x1, y1, x2, y2 = panel.x, panel.y, panel.x + panel.w, panel.y + panel.h
	if flowDraw and flowDraw.Element then
		flowDraw.Element(x1, y1, x2, y2, 1, 1, 1, 1, 1, 1, 1, 1, nil, nil, nil, nil, nil, panel.skew)
	elseif flowDraw and flowDraw.RectRound then
		local corner = floor(panel.h * PANEL_CORNER_FRAC)
		flowDraw.RectRound(x1, y1, x2, y2, corner, 1, 1, 1, 1, { 0, 0, 0, 0.62 }, { 0.14, 0.14, 0.14, 0.62 })
	else
		glColor(0, 0, 0, 0.55)
		glRect(x1, y1, x2, y2)
	end
end

local function drawPanelText(text, x, y, fontSize)
	local font = getPanelFont()
	if font then
		font:Begin()
		font:SetTextColor(0.9, 0.9, 0.9, 0.95)
		font:SetOutlineColor(0, 0, 0, 1)
		font:Print(text, x, y - fontSize * PANEL_TEXT_BASELINE_FRAC, fontSize, "o")
		font:End()
	else
		glColor(0.9, 0.9, 0.9, 0.95)
		glText(text, x, y, fontSize, "vo")
	end
end

local function rampColor(fill)
	local steps = #BAR_COLOR_RAMP
	local position = 1 + max(0, min(1, fill)) * (steps - 1)
	local lower = BAR_COLOR_RAMP[floor(position)]
	local upper = BAR_COLOR_RAMP[min(steps, floor(position) + 1)]
	local t = position - floor(position)
	return lower[1] + (upper[1] - lower[1]) * t, lower[2] + (upper[2] - lower[2]) * t, lower[3] + (upper[3] - lower[3]) * t
end

local function drawPanelBar(x, y, fill)
	local half = panel.barHeight / 2
	glColor(0, 0, 0, 0.5)
	glRect(x, y - half, x + panel.barWidth, y + half)
	if fill > 0 then
		local r, g, b = rampColor(fill)
		glColor(r, g, b, 0.95)
		glRect(x, y - half, x + panel.barWidth * fill, y + half)
	end
end

local function panelTooltip(techLevel, rezSpeed, labMultiplier)
	return format(
		"Zombie tech %.1f of %.1f, estimated from the strongest team's army\n"
			.. "Rising speed %d, cap %d at tech %.1f. Wreck power revived per second\n"
			.. "Wreck timer = power / rising speed, never under %d s or over %d s\n"
			.. "Zombie lab build speed %.1fx, cap %.1fx at tech %.1f",
		techLevel,
		TECH_LEVEL_MAX,
		rezSpeed,
		REZ_SPEED_MAX,
		TECH_LEVEL_MAX,
		respawnDelayMin,
		respawnDelayMax,
		labMultiplier,
		LAB_MULTIPLIER_MAX,
		TECH_LEVEL_MAX
	)
end

local function drawGameStatePanel()
	local techLevel, rezSpeed, labMultiplier = readTechState()
	if panelMode == "None" or not techLevel then
		return
	end
	updatePanel()

	local now = os.clock()
	local ease = min(1, (now - lastDrawClock) * PANEL_FILL_SPEED)
	lastDrawClock = now
	local targetFill = {
		tech = (techLevel - TECH_LEVEL_MIN) / (TECH_LEVEL_MAX - TECH_LEVEL_MIN),
		rising = rezSpeed / REZ_SPEED_MAX,
		labs = (labMultiplier - 1) / (LAB_MULTIPLIER_MAX - 1),
	}
	local values = {
		tech = format("%.1f / %.1f", techLevel, TECH_LEVEL_MAX),
		rising = format("%d / %d (%d-%ds)", rezSpeed, REZ_SPEED_MAX, respawnDelayMin, respawnDelayMax),
		labs = format("%.1fx / %.1fx", labMultiplier, LAB_MULTIPLIER_MAX),
	}
	for key, target in pairs(targetFill) do
		target = max(0, min(1, target))
		shownFill[key] = shownFill[key] + (target - shownFill[key]) * ease
	end

	drawPanelElement()

	local s = panel.h
	local cy = panel.y + s * 0.5
	local iconX = panel.x + panel.pad
	local half = panel.icon / 2
	local iconR, iconG, iconB = rampColor((shownFill.rising + shownFill.labs) * 0.5)
	glColor(iconR, iconG, iconB, 1)
	glTexture(PANEL_ICON)
	glTexRect(iconX, cy - half, iconX + panel.icon, cy + half)
	glTexture(false)

	local labelX = iconX + panel.icon + panel.gap
	local barX = labelX + panel.labelWidth + panel.gap
	local valueX = barX + panel.barWidth + panel.gap
	for i = 1, #panel.rows do
		local key = panel.rows[i]
		local rowY = cy + panel.rowOffsets[i] * s
		drawPanelText(PANEL_ROWS[key].label, labelX, rowY, panel.font)
		drawPanelBar(barX, rowY, shownFill[key])
		if isAdvanced() then
			drawPanelText(values[key], valueX, rowY, panel.font)
		end
	end
	glColor(1, 1, 1, 1)

	if WG["tooltip"] and WG["tooltip"].AddTooltip then
		WG["tooltip"].AddTooltip(
			TOOLTIP_NAME,
			{ panel.x, panel.y, panel.x + panel.w, panel.y + panel.h },
			panelTooltip(techLevel, rezSpeed, labMultiplier),
			nil,
			"Zombies"
		)
	end
end

local function panelModeIndex()
	for i = 1, #PANEL_MODES do
		if PANEL_MODES[i] == panelMode then
			return i
		end
	end
	return 2
end

local function registerOptions()
	if not (WG["options"] and WG["options"].addOptions) then
		return
	end
	WG["options"].addOptions({
		{
			id = PANEL_OPTION_ID,
			widgetname = "Zombie Wreck Timers",
			name = "Zombie game state panel",
			description = "Top bar panel with the zombies' current tech state.\nBasic: bars for how fast wrecks rise and how fast zombie labs build.\nAdvanced: adds the tech estimate and the numbers.",
			type = "select",
			options = PANEL_MODES,
			value = panelModeIndex(),
			onchange = function(_, value)
				panelMode = PANEL_MODES[value] or panelMode
			end,
		},
	})
end

local function unregisterOptions()
	if WG["options"] and WG["options"].removeOptions then
		WG["options"].removeOptions({ PANEL_OPTION_ID })
	end
end

function widget:Initialize()
	local zombies = Spring.GetModOptions().zombies
	if not zombies or zombies == "disabled" then
		widgetHandler:RemoveWidget(self)
		return
	end

	registerOptions()
	readRespawnDelayClamps()

	-- corpses found at game start were queued this frame, so their delay is
	-- exact too; after a mid-game /luaui reload it is unknown -> no prediction
	local knownCreation = spGetGameFrame() <= 1
	for _, featureID in ipairs(Spring.GetAllFeatures()) do
		tryAddFeature(featureID, knownCreation)
	end
end

function widget:FeatureCreated(featureID, allyTeamID)
	tryAddFeature(featureID, true)
end

function widget:FeatureDestroyed(featureID)
	untrackFeature(featureID)
end

function widget:GameFrame(frame)
	if frame % touchPollInterval == 2 then
		pollTampering(frame)
	end

	if frame % syncInterval ~= 11 then
		return
	end

	for featureID, data in pairs(tracked) do
		syncTrackedFeature(featureID, data, frame)
	end
end

function widget:DrawWorld()
	if trackedCount == 0 or spIsGUIHidden() then
		return
	end

	local frame = spGetGameFrame()
	local camX, camY, camZ = spGetCameraPosition()

	glDepthTest(false)
	for featureID, data in pairs(tracked) do
		local dx = data.x - camX
		local dy = data.y - camY
		local dz = data.z - camZ
		if (dx * dx + dy * dy + dz * dz) < maxDistSq then
			local text, r, g, b, a

			if data.hidden then
				-- out of sight: the timer may have been reset unseen
				text = "?"
				r, g, b = COL_HIDDEN[1], COL_HIDDEN[2], COL_HIDDEN[3]
				a = 0.85
			else
				local spawnFrame = data.spawnFrame
				if data.predictedFrame and data.predictedFrame > spawnFrame then
					spawnFrame = data.predictedFrame
				end
				local remainingFrames = spawnFrame - frame
				if remainingFrames >= 0 then
					local remainingSec = floor(remainingFrames / gameSpeed)
					text = getDisplayText(data, remainingSec)

					local c = COL_FAR
					a = 0.85
					if remainingSec < warnSeconds then
						c = COL_MIST
						a = 0.6 + 0.4 * sin(frame * 0.35)
					elseif remainingSec < 60 then
						c = COL_CLOSE
					elseif remainingSec < 120 then
						c = COL_NEAR
					end
					r, g, b = c[1], c[2], c[3]
					if not spIsPosInLos(data.x, data.y, data.z) then
						a = a * 0.6
					end
				end
			end

			if text then
				glPushMatrix()
				glTranslate(data.x, data.y + heightBonus, data.z)
				glBillboard()
				glColor(r, g, b, a)
				glText(text, 0, 0, textSize, "con")
				glPopMatrix()
			end
		end
	end
	glColor(1, 1, 1, 1)
	glDepthTest(true)
end

function widget:Shutdown()
	unregisterOptions()
	if WG["tooltip"] and WG["tooltip"].RemoveTooltip then
		WG["tooltip"].RemoveTooltip(TOOLTIP_NAME)
	end
end

function widget:GetConfigData()
	return { panelUserPos = panelUserPos, panelMode = panelMode }
end

function widget:SetConfigData(data)
	local pos = data and data.panelUserPos
	if type(pos) == "table" and tonumber(pos[1]) and tonumber(pos[2]) then
		panelUserPos = { pos[1], pos[2] }
	end
	local mode = data and data.panelMode
	for i = 1, #PANEL_MODES do
		if PANEL_MODES[i] == mode then
			panelMode = mode
		end
	end
end

function widget:ViewResize()
	vsx, vsy = Spring.GetViewGeometry()
	updatePanel()
end

function widget:MousePress(mx, my, button)
	if button ~= 1 or spIsGUIHidden() or not panelShown() then
		return false
	end
	local _, ctrl = Spring.GetModKeyState()
	if ctrl and mx >= panel.x and mx <= panel.x + panel.w and my >= panel.y and my <= panel.y + panel.h then
		panelDrag = { mx - panel.x, my - panel.y }
		return true
	end
	return false
end

function widget:MouseMove(mx, my)
	if panelDrag then
		panelUserPos = { (mx - panelDrag[1]) / vsx, (my - panelDrag[2]) / vsy }
		return true
	end
end

function widget:MouseRelease()
	panelDrag = nil
	return false
end

function widget:DrawScreen()
	if spIsGUIHidden() then
		return
	end
	drawGameStatePanel()
end
