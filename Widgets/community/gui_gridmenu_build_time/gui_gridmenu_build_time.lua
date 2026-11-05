local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Grid Menu Build Time",
		desc = "Shows each unit's build time in green above its metal and energy cost in the grid menu, for both constructors and factories.",
		author = "jjjj",
		date = "November 2026",
		license = "GNU GPL, v2 or later",
		layer = -1, -- one below the grid menu (layer 0) so this draws on top of it
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- The grid menu does not expose its cell rectangles, so this widget rebuilds
-- them with the same math as gui_gridmenu.lua (widget:ViewResize and
-- setupCells), then asks the grid menu which unit sits in each cell through
-- WG.gridmenu.getUnitDefIDByRowCol. As a safety check, the rebuilt background
-- must match WG.buildmenu.getSize(), otherwise nothing is drawn rather than
-- drawing in the wrong place after a grid menu update.
--------------------------------------------------------------------------------

local math_floor = math.floor
local math_abs = math.abs
local string_format = string.format
local spGetViewGeometry = Spring.GetViewGeometry

-- Values copied from the grid menu's CONFIG
local CELL_PADDING = 0.007
local PRICE_FONT_SIZE = 0.16

-- Same light green the Unit Stats panel (I) uses for build time
local BUILD_TIME_COLOR = "\255\128\255\128"
-- Same grey the grid menu uses for the metal cost of a disabled unit
local DISABLED_COLOR = "\255\125\125\125"

local font
local buildTimeText = {}
local unitsConfig

local function formatNumber(n)
	if n >= 1000 then
		return string_format("%s %03d", formatNumber(math_floor(n / 1000)), n % 1000)
	end
	return tostring(n)
end

local function getBuildTimeText(unitDefID)
	local text = buildTimeText[unitDefID]
	if not text then
		local unitDef = UnitDefs[unitDefID]
		text = formatNumber(math_floor((unitDef and unitDef.buildTime or 0) + 0.5))
		buildTimeText[unitDefID] = text
	end
	return text
end

-- Disabled (restricted) units are greyed out by the grid menu. The restriction
-- state lives in this config module, kept current the same way the grid menu
-- does it (loadBlocked once, then UnitBlocked). If it ever moves, labels just stay green.
local function loadUnitsConfig()
	local ok, module = pcall(require, "luaui/configs/unit_buildmenu_config")
	if ok and type(module) == "table" and module.isRestricted then
		unitsConfig = module
		if module.loadBlocked then
			pcall(module.loadBlocked)
		end
	else
		unitsConfig = nil
	end
end

local function isDisabled(unitDefID, builderDefID)
	return unitsConfig ~= nil and unitsConfig.isRestricted(unitDefID, builderDefID)
end

-- Returns the grid layout, or nil if the grid menu is not in a state we can match
local function computeLayout(buildmenu)
	local flowUI = WG.FlowUI
	if not (flowUI and flowUI.scale and flowUI.elementPadding and flowUI.elementMargin) then
		return nil
	end

	local vsx, vsy = spGetViewGeometry()
	local uiScale = flowUI.scale
	local bgpadding = flowUI.elementPadding
	local widgetSpaceMargin = flowUI.elementMargin
	local categoryFontSize = 0.013 * uiScale * vsy
	local categoryButtonHeight = math_floor(2.3 * categoryFontSize * uiScale)

	local stickToBottom = buildmenu.getBottomPosition and buildmenu.getBottomPosition()
	local rows, cellSize, picsX, picsYEnd, bgY, bgYEnd

	if stickToBottom then
		-- 2 rows by 6 columns, right of the order menu
		local ordermenuLeft = math_floor(vsx / 5)
		if WG.ordermenu and WG.ordermenu.getPosition then
			local oposX, _, owidth = WG.ordermenu.getPosition()
			ordermenuLeft = math_floor((oposX + owidth) * vsx)
		end
		local posY = math_floor(0.14 * uiScale * vsy)
		local posX = ordermenuLeft + widgetSpaceMargin
		local categoryWidth = 10 * categoryFontSize * uiScale

		rows = 2
		cellSize = math_floor((posY - bgpadding) / rows)
		picsX = posX + categoryWidth + bgpadding
		picsYEnd = posY - bgpadding
		bgY, bgYEnd = 0, posY
	else
		-- 3 rows by 4 columns, bottom-left above the info panel
		local width = 0.2125
		width = width / (vsx / vsy) * 1.78
		width = width * uiScale
		local posYEnd = math_floor(0.14 * uiScale * vsy) + widgetSpaceMargin
		width = math_floor(width * vsx)

		local categoriesYEnd = posYEnd + (categoryButtonHeight * 1.4) + bgpadding

		rows = 3
		cellSize = math_floor((width - (bgpadding * 2)) / 4)
		picsX = bgpadding
		picsYEnd = categoriesYEnd + (cellSize * rows)
		bgY, bgYEnd = posYEnd, math_floor(picsYEnd + (bgpadding * 1.5))
	end

	local menuY, menuYEnd = buildmenu.getSize()
	if not (menuY and menuYEnd) or math_abs(menuY - bgY) > 0.5 or math_abs(menuYEnd - bgYEnd) > 0.5 then
		return nil
	end

	local cellPadding = math_floor(cellSize * CELL_PADDING)
	local cellInnerSize = cellSize - cellPadding - cellPadding

	return {
		stickToBottom = stickToBottom,
		rows = rows,
		cellSize = cellSize,
		picsX = picsX,
		picsYEnd = picsYEnd,
		cellPadding = cellPadding,
		cellInnerSize = cellInnerSize,
		fontSize = math_floor((cellInnerSize * PRICE_FONT_SIZE) + 0.5),
	}
end

-- Bottom-left corner of the cell at (row, col), mirroring the grid menu's setupCells
local function getCellOrigin(layout, row, col)
	local arow, acol = row, col
	if row > 2 and layout.stickToBottom then
		-- the 3x4 grid is remapped onto 2x6 when the menu sits at the bottom
		arow = col < 3 and 2 or 1
		acol = 6 - col % 2
	end
	return layout.picsX + (acol - 1) * layout.cellSize, layout.picsYEnd - (layout.rows - arow + 1) * layout.cellSize
end

function widget:DrawScreen()
	local buildmenu = WG.buildmenu
	local gridmenu = WG.gridmenu
	if not (buildmenu and gridmenu and gridmenu.getUnitDefIDByRowCol and buildmenu.getSize) then
		return
	end
	-- the legacy "Build menu" also fills WG.buildmenu, and it has a different layout
	if buildmenu.getMaxColls then
		return
	end
	if buildmenu.getIsShowing and not buildmenu.getIsShowing() then
		return
	end

	local layout = computeLayout(buildmenu)
	if not layout then
		return
	end

	-- follow the grid menu: costs on every icon when its prices are on, otherwise only on hover
	local showAll = not buildmenu.getShowPrice or buildmenu.getShowPrice()
	local hoverID = buildmenu.hoverID
	local activeBuilder = gridmenu.getActiveBuilder and gridmenu.getActiveBuilder()

	local fontSize = layout.fontSize
	local textOffsetX = layout.cellSize - layout.cellPadding - (layout.cellInnerSize * 0.048)
	-- metal sits at 1.35 and energy at 0.35 font heights, so this is the line above them
	local textOffsetY = layout.cellPadding + (fontSize * 2.35)

	local begun = false
	for row = 1, 3 do
		for col = 1, 4 do
			local unitDefID = gridmenu.getUnitDefIDByRowCol(row, col)
			if unitDefID and (showAll or unitDefID == hoverID) then
				if not begun then
					font:Begin()
					begun = true
				end
				local x, y = getCellOrigin(layout, row, col)
				local color = isDisabled(unitDefID, activeBuilder) and DISABLED_COLOR or BUILD_TIME_COLOR
				font:Print(color .. getBuildTimeText(unitDefID), x + textOffsetX, y + textOffsetY, fontSize, "ro")
			end
		end
	end
	if begun then
		font:End()
	end
end

function widget:UnitBlocked(unitDefID, reasons, builderUnitDefID)
	if unitsConfig and unitsConfig.setBlocked then
		unitsConfig.setBlocked(unitDefID, reasons, builderUnitDefID)
	end
end

function widget:ViewResize()
	font = WG.fonts.getFont(2)
end

function widget:Initialize()
	if not WG.fonts then
		widgetHandler:RemoveWidget()
		return
	end
	font = WG.fonts.getFont(2)
	loadUnitsConfig()
end
