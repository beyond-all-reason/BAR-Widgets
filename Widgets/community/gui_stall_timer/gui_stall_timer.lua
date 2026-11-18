local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Stall Timer",
		desc = "Shows time-to-stall under the metal and energy sliders as M:SS. -:-- when the bar is not falling, 9:59 at ten minutes or more.",
		author = "gregory-j-weaver",
		date = "2026-11-11",
		license = "GNU GPL v2 or later",
		layer = -94990, -- just after Top Bar so the labels sit on top of its glow
		enabled = true,
		depends = { "Top Bar" },
	}
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local UPDATE_INTERVAL = 1.0 -- seconds between samples, as requested
local MAX_SECONDS = 9 * 60 + 59 -- 9:59; 10:00 and above clamp here
local DRAIN_EPSILON = 0.05 -- ignore floating-point noise as "decreasing"
local STALL_TEXT = "-:--"

-- Colors copied from gui_top_bar.drawResbarValue (the numbers over the sliders).
local COLOR_METAL = { 0.95, 0.95, 0.95, 1 }
local COLOR_ENERGY = { 1, 1, 0.74, 1 }
local COLOR_OUTLINE = { 0, 0, 0, 1 }

-- Layout constants copied from gui_top_bar.lua (Floris / BAR master).
local ORG_HEIGHT = 46
local BAR_WIDTH_DIVISOR = 4.4
local BAR_HEIGHT_DIVISOR = 7
local BAR_HEIGHT_PADDING_DIVISOR = 4.4
local BAR_LEFT_PADDING = 53
local BAR_RIGHT_PADDING = 14.5
local CURRENT_FONT_DIVISOR = 2.5 -- textCurrent size is (height / 2.5) * widgetScale
local DEFAULT_SKEW_TAN = math.tan(math.rad(20))

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local myTeamID = Spring.GetLocalTeamID()
local font2
local elapsed = 0
local labels = {
	metal = STALL_TEXT,
	energy = STALL_TEXT,
}
local layout = {
	metal = { x = 0, y = 0, fontSize = 16 },
	energy = { x = 0, y = 0, fontSize = 16 },
	ready = false,
}

local math_floor = math.floor
local string_format = string.format
local spGetTeamResources = Spring.GetTeamResources
local spGetLocalTeamID = Spring.GetLocalTeamID
local spIsGUIHidden = Spring.IsGUIHidden
local spGetConfigFloat = Spring.GetConfigFloat

--------------------------------------------------------------------------------
-- Time-to-stall
--------------------------------------------------------------------------------
-- Format seconds as M:SS. Anything 10:00 or longer becomes 9:59.
local function FormatStallTime(seconds)
	if not seconds or seconds < 0 then
		return STALL_TEXT
	end
	if seconds >= (MAX_SECONDS + 1) then
		return "9:59"
	end
	local whole = math_floor(seconds)
	local mins = math_floor(whole / 60)
	local secs = whole % 60
	return string_format("%d:%02d", mins, secs)
end

-- Decreasing means expense is beating income this sample. Otherwise -:--.
local function StallLabel(current, income, expense)
	local drain = (expense or 0) - (income or 0)
	if drain <= DRAIN_EPSILON then
		return STALL_TEXT
	end
	if not current or current <= 0 then
		return "0:00"
	end
	return FormatStallTime(current / drain)
end

local function SampleResources()
	myTeamID = spGetLocalTeamID()
	if myTeamID == nil then
		labels.metal = STALL_TEXT
		labels.energy = STALL_TEXT
		return
	end

	local function sample(resName)
		local current, _, _, income, expense = spGetTeamResources(myTeamID, resName)
		if current == nil then
			labels[resName] = STALL_TEXT
			return
		end
		labels[resName] = StallLabel(current, income, expense)
	end

	sample("metal")
	sample("energy")
end

--------------------------------------------------------------------------------
-- Layout: sit directly under each top-bar slider
--------------------------------------------------------------------------------
local function ResourceBarsVisible()
	if not (WG.topbar and WG.topbar.GetPosition) then
		return false
	end
	if WG.topbar.getResourceBarsVisible then
		return WG.topbar.getResourceBarsVisible()
	end
	return true
end

local function ComputeBarArea(res, area, tbh, widgetScale, skewTan, useSkew)
	local barHeight = math_floor((tbh / BAR_HEIGHT_DIVISOR) + 0.5)
	local barHeightPadding = math_floor((tbh / BAR_HEIGHT_PADDING_DIVISOR) + 0.5)
	local skewSideInset = 0
	if useSkew then
		skewSideInset = math_floor(tbh * skewTan * 0.5)
	end
	local barLeftPadding = math_floor(BAR_LEFT_PADDING * widgetScale) + (res == "metal" and skewSideInset or 0)
	local barRightPadding = math_floor(BAR_RIGHT_PADDING * widgetScale) + (res == "energy" and skewSideInset or 0)
	local x1 = area[1] + math_floor(tbh + barLeftPadding)
	local y1 = area[2] + barHeightPadding
	local x2 = area[3] - barRightPadding
	local y2 = y1 + barHeight
	return { x1, y1, x2, y2 }
end

local function UpdateLayout()
	layout.ready = false
	if not (WG.topbar and WG.topbar.GetPosition) then
		return
	end

	local pos = WG.topbar.GetPosition()
	if not (pos and pos[1] and pos[5]) then
		return
	end

	local px1, py1, px2, py2, widgetScale = pos[1], pos[2], pos[3], pos[4], pos[5]
	local tbh = py2 - py1
	if tbh < 8 or widgetScale <= 0 then
		return
	end

	local sk = WG.topbar.GetSkewConfig and WG.topbar.GetSkewConfig()
	local useSkew = sk and sk.useSkew
	local skewTan = (sk and sk.skewTan) or DEFAULT_SKEW_TAN
	local margin = (WG.FlowUI and WG.FlowUI.elementMargin) or 0

	-- GetPosition() returns the skewed origin. Undo that so metal starts at
	-- the same x as gui_top_bar's resbarArea.metal.
	local leftSkew = (useSkew and math_floor(tbh * skewTan)) or 0
	local topX = px1 - leftSkew - margin
	local totalWidth = px2 - topX
	local barW = math_floor(totalWidth / BAR_WIDTH_DIVISOR)
	if barW < 40 then
		return
	end

	local metalArea = { topX, py1, topX + barW, py2 }
	local energyArea = { topX + barW + margin, py1, topX + barW + margin + barW, py2 }

	-- Font size matches the current-amount numbers over the sliders:
	-- (height / 2.5) * widgetScale, and height * widgetScale == tbh.
	local fontSize = tbh / CURRENT_FONT_DIVISOR
	local uiScale = tonumber(spGetConfigFloat("ui_scale", 1) or 1)
	local height = ORG_HEIGHT * (1 + (uiScale - 1) / 1.7)
	if height > 0 then
		fontSize = (height / CURRENT_FONT_DIVISOR) * widgetScale
	end

	local function place(res, area)
		local bar = ComputeBarArea(res, area, tbh, widgetScale, skewTan, useSkew)
		local barWidth = bar[3] - bar[1]
		if barWidth < 8 then
			return false
		end
		-- Centered on the slider. Baseline sits one font-height below the
		-- bottom of the top-bar frame so the glyphs clear the slider boxes
		-- (the numbers over the sliders use the same size, above the track).
		layout[res].x = bar[1] + barWidth * 0.5
		layout[res].y = area[2] - fontSize
		layout[res].fontSize = fontSize
		return true
	end

	if place("metal", metalArea) and place("energy", energyArea) then
		layout.ready = true
	end
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------
function widget:Initialize()
	myTeamID = spGetLocalTeamID()
	if WG.fonts and WG.fonts.getFont then
		font2 = WG.fonts.getFont(2)
	end
	UpdateLayout()
	SampleResources()
end

function widget:ViewResize()
	if WG.fonts and WG.fonts.getFont then
		font2 = WG.fonts.getFont(2)
	end
	UpdateLayout()
end

function widget:PlayerChanged()
	myTeamID = spGetLocalTeamID()
	labels.metal = STALL_TEXT
	labels.energy = STALL_TEXT
	SampleResources()
end

function widget:Update(dt)
	elapsed = elapsed + (dt or 0)
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0
	UpdateLayout()
	SampleResources()
end

function widget:DrawScreen()
	if spIsGUIHidden() then
		return
	end
	if not layout.ready then
		UpdateLayout()
		if not layout.ready then
			return
		end
	end
	if not ResourceBarsVisible() then
		return
	end

	-- Same typeface as the numbers over the sliders: bar_font2 / Exo2 SemiBold.
	if not font2 and WG.fonts and WG.fonts.getFont then
		font2 = WG.fonts.getFont(2)
	end

	local function drawLabel(res, color)
		local L = layout[res]
		local text = labels[res] or STALL_TEXT
		if font2 then
			font2:Begin()
			font2:SetTextColor(color[1], color[2], color[3], color[4])
			font2:SetOutlineColor(COLOR_OUTLINE[1], COLOR_OUTLINE[2], COLOR_OUTLINE[3], COLOR_OUTLINE[4])
			font2:Print(text, L.x, L.y, L.fontSize, "ocd")
			font2:End()
		else
			gl.Color(color[1], color[2], color[3], color[4])
			gl.Text(text, L.x, L.y, L.fontSize, "ocd")
			gl.Color(1, 1, 1, 1)
		end
	end

	drawLabel("metal", COLOR_METAL)
	drawLabel("energy", COLOR_ENERGY)
end

function widget:Shutdown()
	font2 = nil
end
