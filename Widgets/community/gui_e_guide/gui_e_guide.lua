function widget:GetInfo()
	return {
		name    = "Energy Guide",
		desc    = "Tiny draggable mini-panel ranking the best energy sources (wind, solar, tidal, geo, T2) for the current map settings and faction.",
		author  = "goddot",
		date    = "2026-10-18",
		license = "GNU GPL, v2 or later",
		layer   = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Energy Guide
--
--  * Reads wind min/max, tidal strength, water and geo vents from the map.
--  * Reads every number (E/s, cost, build time) straight from UnitDefs, so it
--    follows balance changes and differs per faction (Armada / Cortex / Legion).
--  * Ranks the sources of each tier on two efficiencies: E/s per metal (E/M) and
--    E/s per total initial price (metal + energy). Best = highest mean of both.
--
--  Controls:   drag = move | wheel = resize | click ARM/COR/LEG chip = preview
--              another faction | click T2 chip = show/hide tier 2
--------------------------------------------------------------------------------

-- Tunables ---------------------------------------------------------------------
local WIND_CAP      = 25     -- wind turbines never output more than this
local UPDATE_FRAMES = 15     -- refresh interval (30 frames = 1 s)

-- Layout (local units, scaled as a whole) ------------------------------------------
local PAD, HEADER_H, GAP = 6, 14, 4
local TIER_W, CARD_W, ICON = 13, 44, 34
local CARD_H = 84
local MIN_SCALE, MAX_SCALE = 0.6, 2.5

-- Speedups -----------------------------------------------------------------------
local spGetWind          = Spring.GetWind
local spGetMyTeamID      = Spring.GetMyTeamID
local spGetTeamInfo      = Spring.GetTeamInfo
local spGetTeamRulesParam = Spring.GetTeamRulesParam
local spGetMouseState    = Spring.GetMouseState
local spIsGUIHidden      = Spring.IsGUIHidden
local spGetViewGeometry  = Spring.GetViewGeometry

local glColor, glTexture, glTexRect = gl.Color, gl.Texture, gl.TexRect
local glText, glGetTextWidth = gl.Text, gl.GetTextWidth
local glBeginEnd, glVertex, glLineWidth, glBlending = gl.BeginEnd, gl.Vertex, gl.LineWidth, gl.Blending
local glPushMatrix, glPopMatrix, glTranslate, glScale = gl.PushMatrix, gl.PopMatrix, gl.Translate, gl.Scale
local GL_TRIANGLE_FAN, GL_LINE_LOOP = GL.TRIANGLE_FAN, GL.LINE_LOOP

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local cos, sin, pi = math.cos, math.sin, math.pi
local sformat = string.format

-- Unit catalogue ---------------------------------------------------------------------
-- Names that do not exist in the running game are skipped automatically.
local CATALOG = {
	arm = { t1 = { "armwin", "armsolar", "armtide", "armgeo" }, t2 = { "armadvsol", "armfus", "armafus", "armageo" } },
	cor = { t1 = { "corwin", "corsolar", "cortide", "corgeo" }, t2 = { "coradvsol", "corfus", "corafus", "corageo" } },
	leg = { t1 = { "legwin", "legsolar", "legtide", "leggeo" }, t2 = { "legadvsol", "legfus", "legafus", "legageo" } },
}
local FACTION_ORDER = { "arm", "cor", "leg" }
local FACTION = {
	arm = { label = "ARM", name = "Armada", color = { 0.30, 0.56, 1.00 } },
	cor = { label = "COR", name = "Cortex", color = { 0.92, 0.32, 0.30 } },
	leg = { label = "LEG", name = "Legion", color = { 0.36, 0.80, 0.46 } },
}

-- Palette --------------------------------------------------------------------------
local C_BG     = { 0.05, 0.06, 0.08, 0.80 }
local C_EDGE   = { 1.00, 1.00, 1.00, 0.10 }
local C_TEXT   = { 0.94, 0.96, 1.00, 1.00 }
local C_DIM    = { 0.62, 0.68, 0.78, 1.00 }
local C_GOLD   = { 1.00, 0.82, 0.25, 1.00 }
local C_BAR    = { 0.30, 0.78, 0.85, 1.00 }
local C_BAR2   = { 0.70, 0.55, 1.00, 1.00 }

-- State ----------------------------------------------------------------------------
local vsx, vsy = spGetViewGeometry()
local px, ytop                       -- panel left edge / top edge in pixels
local savedFX, savedFY               -- saved position as screen fractions
local userScale  = 1.0
local showT2     = true
local override                       -- nil = auto-detect, otherwise "arm"/"cor"/"leg"
local faction    = "arm"

local windMin, windMax, windAvg, windNow = 0, 0, 0, 0
local tidal, hasWater, ventCount = 0, false, 0

local items = { t1 = {}, t2 = {} }
local layout
local dragging, dragDX, dragDY, dragDist, pressTarget = false, 0, 0, 0, nil

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

local function log(msg)
	Spring.Echo("[Energy Guide] " .. tostring(msg))
end

local function fmt(v)
	if v >= 100 then return sformat("%d", floor(v + 0.5)) end
	local s = sformat("%.1f", v)
	return (s:gsub("%.0$", ""))
end

local function factionAvailable(f)
	return UnitDefNames[CATALOG[f].t1[1]] ~= nil
end

local function prefixToFaction(v)
	-- BAR stores startUnit as a unitDefID (number); sides/names are strings
	if type(v) == "number" then
		local ud = UnitDefs[v]
		v = ud and ud.name
	end
	if type(v) ~= "string" or v == "" then return nil end
	local p = v:lower():sub(1, 3)
	if CATALOG[p] then return p end
	return nil
end

local function detectFaction()
	local team = spGetMyTeamID()
	if team then
		-- 1) commander the team starts with
		local ok, f = pcall(function() return prefixToFaction(spGetTeamRulesParam(team, "startUnit")) end)
		if ok and f then return f end
		-- 2) declared side
		ok, f = pcall(function() return prefixToFaction(select(5, spGetTeamInfo(team, false))) end)
		if ok and f then return f end
		-- 3) whatever units the team owns (covers random side / odd setups)
		ok, f = pcall(function()
			for _, uid in ipairs(Spring.GetTeamUnits(team) or {}) do
				local udid = Spring.GetUnitDefID(uid)
				local ud = udid and UnitDefs[udid]
				local pf = ud and prefixToFaction(ud.name)
				if pf then return pf end
			end
		end)
		if ok and f then return f end
	end
	return faction or "arm"
end

local function countVents()
	local n = 0
	for _, fid in ipairs(Spring.GetAllFeatures()) do
		local fdid = Spring.GetFeatureDefID(fid)
		local fd = fdid and FeatureDefs[fdid]
		if fd and (fd.geoThermal or (fd.name and fd.name:find("geovent"))) then
			n = n + 1
		end
	end
	return n
end

local function readMap()
	windMin = Game.windMin or 0
	windMax = Game.windMax or 0
	windAvg = (windMin + windMax) * 0.5
	tidal = Game.tidal or 0
	local okG, lowest = pcall(Spring.GetGroundExtremes)
	hasWater = okG and (lowest or 0) < 0 or false
	local okV, n = pcall(countVents)
	ventCount = okV and n or 0
	if not okV then log("vent scan failed: " .. tostring(n)) end
end

-- Turns a unitdef into a display item (or nil when it is irrelevant on this map)
local function describe(ud)
	local kind, avg, now, count = "flat", 0, 0, nil

	if (ud.windGenerator or 0) > 0 then
		kind = "wind"
		avg = min(windAvg, WIND_CAP)
		now = min(windNow, WIND_CAP)
	elseif (ud.tidalGenerator or 0) > 0 then
		kind = "tide"
		if not hasWater then return nil end
		avg = ud.tidalGenerator * tidal
		now = avg
	else
		avg = (ud.energyMake or 0) - (ud.energyUpkeep or 0)
		now = avg
		if ud.needGeo or (ud.name or ""):find("geo") then
			kind = "geo"
			if ventCount <= 0 then return nil end
			count = ventCount
		end
	end

	local metal, energy = ud.metalCost or 0, ud.energyCost or 0
	return {
		defID     = ud.id,
		human     = ud.humanName or ud.name,
		kind      = kind,
		avg       = avg,
		now       = now,
		count     = count,
		metal     = metal,
		energy    = energy,
		buildTime = ud.buildTime or 0,
		effM      = metal > 0 and (avg / metal) or 0,                   -- E/s per metal
		effT      = (metal + energy) > 0 and (avg / (metal + energy)) or 0, -- E/s per (metal + energy)
		dim       = (kind == "wind" and windMax < 1) or (kind == "tide" and tidal < 1),
	}
end

local function markBest(list)
	local bestM, bestT = 0, 0
	for _, it in ipairs(list) do
		bestM, bestT = max(bestM, it.effM), max(bestT, it.effT)
	end
	local best, bestScore = nil, 0
	for _, it in ipairs(list) do
		it.relM = bestM > 0 and (it.effM / bestM) or 0
		it.relT = bestT > 0 and (it.effT / bestT) or 0
		it.score = (it.relM + it.relT) * 0.5
		if it.score > bestScore then best, bestScore = it, it.score end
	end
	for _, it in ipairs(list) do it.isBest = (it == best) end
end

local function buildItems()
	local cat = CATALOG[faction]
	items = { t1 = {}, t2 = {} }
	for _, key in ipairs({ "t1", "t2" }) do
		for _, name in ipairs(cat[key]) do
			local ud = UnitDefNames[name]
			if ud then
				local ok, it = pcall(describe, ud)
				if not ok then log("describe " .. name .. ": " .. tostring(it)) end
				if ok and it then items[key][#items[key] + 1] = it end
			end
		end
		markBest(items[key])
	end
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function buildLayout()
	local n1, n2 = #items.t1, showT2 and #items.t2 or 0
	local n = max(3, n1, n2)
	local W = PAD * 2 + TIER_W + n * CARD_W + (n - 1) * GAP

	local rowsWanted = { { label = "T1", list = items.t1 } }
	if showT2 and #items.t2 > 0 then rowsWanted[2] = { label = "T2", list = items.t2 } end

	local H = PAD * 2 + HEADER_H + #rowsWanted * (CARD_H + GAP) - GAP + GAP
	local L = { W = W, H = H, rows = {} }

	local cy = H - PAD - HEADER_H * 0.5
	L.headerCy = cy
	L.t2Chip = { x1 = W - PAD - 18, x2 = W - PAD, y1 = cy - 6, y2 = cy + 6 }
	L.facChip = { x1 = L.t2Chip.x1 - 3 - 26, x2 = L.t2Chip.x1 - 3, y1 = cy - 6, y2 = cy + 6 }

	local rowTop = H - PAD - HEADER_H - GAP
	for _, r in ipairs(rowsWanted) do
		local row = { label = r.label, y1 = rowTop - CARD_H, y2 = rowTop, cards = {} }
		for i, it in ipairs(r.list) do
			local x1 = PAD + TIER_W + (i - 1) * (CARD_W + GAP)
			row.cards[i] = { item = it, x1 = x1, x2 = x1 + CARD_W, y1 = row.y1, y2 = row.y2 }
		end
		L.rows[#L.rows + 1] = row
		rowTop = rowTop - CARD_H - GAP
	end
	layout = L
end

local function refresh()
	faction = override or detectFaction()
	if Spring.GetGameFrame() > 0 then
		windNow = select(4, spGetWind()) or windAvg
	else
		windNow = windAvg
	end
	buildItems()
	buildLayout()
end

--------------------------------------------------------------------------------
-- Placement / coordinates
--------------------------------------------------------------------------------

local function uiScale()
	return userScale * max(0.75, vsy / 1080)
end

local function place()
	if px then return end
	local s = uiScale()
	px = (savedFX or 0) * vsx + (savedFX and 0 or 6 * s)
	if savedFY then
		ytop = savedFY * vsy
	else
		ytop = vsy * 0.5 + (layout and layout.H or 150) * s * 0.5   -- vertically centred
	end
end

local function clampPos()
	if not layout then return end
	local s = uiScale()
	px   = max(0, min(px, vsx - layout.W * s))
	ytop = max(layout.H * s, min(ytop, vsy))
end

local function toLocal(mx, my)
	local s = uiScale()
	return (mx - px) / s, (my - (ytop - layout.H * s)) / s
end

local function inRect(r, x, y)
	return x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2
end

local function hitTest(mx, my)
	if not layout then return nil end
	local lx, ly = toLocal(mx, my)
	if lx < 0 or ly < 0 or lx > layout.W or ly > layout.H then return nil end
	if inRect(layout.facChip, lx, ly) then return { kind = "faction" } end
	if inRect(layout.t2Chip, lx, ly) then return { kind = "t2" } end
	for _, row in ipairs(layout.rows) do
		for _, c in ipairs(row.cards) do
			if inRect(c, lx, ly) then return { kind = "card", card = c } end
		end
	end
	return { kind = "panel" }
end

--------------------------------------------------------------------------------
-- Drawing primitives
--------------------------------------------------------------------------------

local function roundedPath(x1, y1, x2, y2, r)
	r = min(r, (x2 - x1) * 0.5, (y2 - y1) * 0.5)
	local pts, seg = {}, 4
	local corners = {
		{ x2 - r, y2 - r, 0 }, { x1 + r, y2 - r, pi * 0.5 },
		{ x1 + r, y1 + r, pi }, { x2 - r, y1 + r, pi * 1.5 },
	}
	for _, c in ipairs(corners) do
		for i = 0, seg do
			local a = c[3] + (pi * 0.5) * (i / seg)
			pts[#pts + 1] = { c[1] + cos(a) * r, c[2] + sin(a) * r }
		end
	end
	return pts
end

local function roundedRect(x1, y1, x2, y2, r)
	local pts = roundedPath(x1, y1, x2, y2, r)
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex((x1 + x2) * 0.5, (y1 + y2) * 0.5)
		for _, p in ipairs(pts) do glVertex(p[1], p[2]) end
		glVertex(pts[1][1], pts[1][2])
	end)
end

local function roundedOutline(x1, y1, x2, y2, r, width)
	local pts = roundedPath(x1, y1, x2, y2, r)
	glLineWidth(width or 1)
	glBeginEnd(GL_LINE_LOOP, function()
		for _, p in ipairs(pts) do glVertex(p[1], p[2]) end
	end)
	glLineWidth(1)
end

local function star(cx, cy, r)
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex(cx, cy)
		for i = 0, 10 do
			local rr = (i % 2 == 0) and r or r * 0.45
			local a = pi * 0.5 + i * pi / 5
			glVertex(cx + cos(a) * rr, cy + sin(a) * rr)
		end
	end)
end

local function setColor(c, a)
	glColor(c[1], c[2], c[3], (c[4] or 1) * (a or 1))
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function drawCard(c, hovered)
	local it = c.item
	local a = it.dim and 0.4 or 1
	local cx = (c.x1 + c.x2) * 0.5

	glColor(1, 1, 1, hovered and 0.12 or 0.05)
	roundedRect(c.x1, c.y1, c.x2, c.y2, 4)

	-- buildpic
	local ix1 = c.x1 + (CARD_W - ICON) * 0.5
	local iy2 = c.y2 - 3
	local iy1 = iy2 - ICON
	glColor(1, 1, 1, a)
	glTexture("#" .. it.defID)
	glTexRect(ix1, iy1, ix1 + ICON, iy2)
	glTexture(false)

	-- best-of-tier highlight
	if it.isBest then
		setColor(C_GOLD, 0.9)
		roundedOutline(c.x1, c.y1, c.x2, c.y2, 4, 1.4)
		star(c.x2 - 6, c.y2 - 6, 4.6)
	end

	-- value (average E/s) + unit line
	setColor(C_TEXT, a)
	glText(fmt(it.avg), cx, iy1 - 7, 10.5, "cvo")

	local unit = "E/s"
	if it.kind == "wind" then
		unit = "E/s now " .. fmt(it.now)
	elseif it.kind == "geo" then
		unit = "E/s x" .. it.count
	end
	setColor(C_DIM, a)
	glText(unit, cx, iy1 - 16, 6.8, "cvo")

	-- efficiencies
	setColor(C_BAR, a)
	glText(sformat("%.2f/M", it.effM), cx, iy1 - 25, 6.8, "cvo")
	setColor(C_BAR2, a)
	glText(sformat("%.3f/M+E", it.effT), cx, iy1 - 33, 6.8, "cvo")

	-- relative bars (vs best of the tier): metal, then metal+energy
	local bx1, bx2 = c.x1 + 4, c.x2 - 4
	local function bar(by1, rel, col)
		glColor(1, 1, 1, 0.08)
		glBeginEnd(GL.QUADS, function()
			glVertex(bx1, by1); glVertex(bx2, by1); glVertex(bx2, by1 + 2); glVertex(bx1, by1 + 2)
		end)
		if rel > 0 then
			local fx = bx1 + (bx2 - bx1) * rel
			setColor(col, a * 0.9)
			glBeginEnd(GL.QUADS, function()
				glVertex(bx1, by1); glVertex(fx, by1); glVertex(fx, by1 + 2); glVertex(bx1, by1 + 2)
			end)
		end
	end
	bar(c.y1 + 6, it.relM, C_BAR)
	bar(c.y1 + 3, it.relT, C_BAR2)
end

local function chip(rect, label, color, filled, outlined, hovered)
	local alpha = filled and 0.85 or 0.25
	glColor(color[1], color[2], color[3], hovered and min(1, alpha + 0.15) or alpha)
	roundedRect(rect.x1, rect.y1, rect.x2, rect.y2, 3)
	if outlined then
		glColor(1, 1, 1, 0.8)
		roundedOutline(rect.x1, rect.y1, rect.x2, rect.y2, 3, 1)
	end
	glColor(1, 1, 1, filled and 1 or 0.7)
	glText(label, (rect.x1 + rect.x2) * 0.5, (rect.y1 + rect.y2) * 0.5, 7.5, "cvo")
end

local function tooltipLines(h)
	if h.kind == "faction" then
		local f = FACTION[faction]
		return {
			{ f.name .. (override and " (preview)" or " (auto)"), C_TEXT },
			{ "Click: cycle faction", C_DIM },
		}
	elseif h.kind == "t2" then
		return { { "Click: show / hide tier 2", C_DIM } }
	elseif h.kind == "card" then
		local it = h.card.item
		local out
		if it.kind == "wind" then
			out = sformat("%s E/s avg  (wind %s-%s, now %s)", fmt(it.avg), fmt(windMin), fmt(windMax), fmt(it.now))
		elseif it.kind == "tide" then
			out = sformat("%s E/s  (map tidal %s)", fmt(it.avg), fmt(tidal))
		elseif it.kind == "geo" then
			out = sformat("%s E/s per vent  (%d on map)", fmt(it.avg), it.count)
		else
			out = sformat("%s E/s", fmt(it.avg))
		end
		return {
			{ it.human .. (it.isBest and "  - best in tier" or ""), it.isBest and C_GOLD or C_TEXT },
			{ out, C_TEXT },
			{ sformat("Cost: %d M  %d E   BT %d", it.metal, it.energy, it.buildTime), C_DIM },
			{ sformat("%.3f E/s per metal   (%d%% of best)", it.effM, floor(it.relM * 100 + 0.5)), C_BAR },
			{ sformat("%.4f E/s per metal+energy   (%d%% of best)", it.effT, floor(it.relT * 100 + 0.5)), C_BAR2 },
			{ "Best = highest mean of both", C_DIM },
		}
	end
end

local function drawTooltip(h)
	local lines = tooltipLines(h)
	if not lines then return end
	local size, lh = 8, 11
	local w = 0
	for _, l in ipairs(lines) do w = max(w, glGetTextWidth(l[1]) * size) end
	w = w + 12
	local hgt = #lines * lh + 8

	local s = uiScale()
	local x1 = 0
	local overflow = px + w * s - vsx
	if overflow > 0 then x1 = -overflow / s end

	local below = ytop > vsy * 0.5
	local y2 = below and -4 or (layout.H + 4 + hgt)
	local y1 = y2 - hgt

	setColor({ 0.04, 0.05, 0.07, 0.94 })
	roundedRect(x1, y1, x1 + w, y2, 4)
	setColor(C_EDGE)
	roundedOutline(x1, y1, x1 + w, y2, 4, 1)
	for i, l in ipairs(lines) do
		setColor(l[2])
		glText(l[1], x1 + 6, y2 - 4 - (i - 0.5) * lh, size, "vo")
	end
end

local pushed = false
local drawErr

local function drawPanel()
	place()
	clampPos()

	local mx, my = spGetMouseState()
	local hover = (not dragging) and hitTest(mx, my) or nil
	local s = uiScale()

	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	glPushMatrix()
	pushed = true
	glTranslate(px, ytop - layout.H * s, 0)
	glScale(s, s, 1)

	-- backdrop
	setColor(C_BG)
	roundedRect(0, 0, layout.W, layout.H, 6)
	setColor(C_EDGE)
	roundedOutline(0, 0, layout.W, layout.H, 6, 1)

	-- header
	setColor(C_DIM)
	glText(sformat("WIND %s-%s", fmt(windMin), fmt(windMax)), PAD + 1, layout.headerCy, 8, "vo")
	local f = FACTION[faction]
	chip(layout.facChip, f.label, f.color, true, override ~= nil, hover and hover.kind == "faction")
	chip(layout.t2Chip, "T2", C_BAR, showT2, false, hover and hover.kind == "t2")

	-- rows
	for _, row in ipairs(layout.rows) do
		setColor(C_DIM, 0.8)
		glText(row.label, PAD + TIER_W * 0.5 - 1, row.y2 - 3 - ICON * 0.5, 7, "cvo")
		for _, c in ipairs(row.cards) do
			drawCard(c, hover and hover.kind == "card" and hover.card == c)
		end
	end

	if hover and hover.kind ~= "panel" then drawTooltip(hover) end

	glPopMatrix()
	pushed = false
	glColor(1, 1, 1, 1)
end

function widget:DrawScreen()
	if spIsGUIHidden() then return end
	if not layout then
		local ok, e = pcall(refresh)
		if not ok then log("refresh failed: " .. tostring(e)) end
		if not layout then return end
	end
	local ok, e = pcall(drawPanel)
	if not ok then
		if pushed then glPopMatrix(); pushed = false end
		if e ~= drawErr then drawErr = e; log("draw error: " .. tostring(e)) end
	end
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function cycleFaction()
	local seq = { false }                      -- false = auto-detect
	for _, f in ipairs(FACTION_ORDER) do
		if factionAvailable(f) then seq[#seq + 1] = f end
	end
	local idx = 1
	for i, f in ipairs(seq) do
		if f == (override or false) then idx = i end
	end
	idx = idx % #seq + 1
	override = seq[idx] or nil
	refresh()
end

function widget:MousePress(mx, my, button)
	if button ~= 1 or not layout then return false end
	place()
	local h = hitTest(mx, my)
	if not h then return false end
	dragging, dragDist, pressTarget = true, 0, h.kind
	dragDX, dragDY = mx - px, my - ytop
	return true
end

function widget:MouseMove(mx, my, dx, dy)
	if not dragging then return end
	dragDist = dragDist + abs(dx) + abs(dy)
	if dragDist > 3 then
		px, ytop = mx - dragDX, my - dragDY
		clampPos()
	end
end

function widget:MouseRelease(mx, my, button)
	if not dragging then return false end
	dragging = false
	if dragDist <= 3 then
		local h = hitTest(mx, my)
		if h and h.kind == pressTarget then
			if h.kind == "faction" then
				cycleFaction()
			elseif h.kind == "t2" then
				showT2 = not showT2
				buildLayout()
				clampPos()
			end
		end
	end
	return true
end

function widget:IsAbove(mx, my)
	return layout ~= nil and px ~= nil and hitTest(mx, my) ~= nil
end

function widget:MouseWheel(up, value)
	if not layout or not px then return false end
	local mx, my = spGetMouseState()
	if not hitTest(mx, my) then return false end
	userScale = max(MIN_SCALE, min(MAX_SCALE, userScale + (up and 0.08 or -0.08)))
	clampPos()
	return true
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

function widget:Initialize()
	vsx, vsy = spGetViewGeometry()
	local ok, e = pcall(readMap)
	if not ok then log("readMap failed: " .. tostring(e)) end
	ok, e = pcall(refresh)
	if not ok then log("refresh failed: " .. tostring(e)) end
	log("ready - faction " .. tostring(faction) .. ", wind " .. tostring(windMin) .. "-" .. tostring(windMax)
		.. ", " .. #items.t1 .. "+" .. #items.t2 .. " sources")
end

function widget:GameStart()
	pcall(readMap)
	pcall(refresh)
end

function widget:GameFrame(n)
	if n == 2 then pcall(readMap) end   -- features are final once the game runs
	if n % UPDATE_FRAMES == 0 or n == 2 then
		local ok, e = pcall(refresh)
		if not ok and e ~= drawErr then drawErr = e; log("refresh failed: " .. tostring(e)) end
	end
end

function widget:PlayerChanged(playerID)
	if playerID == Spring.GetMyPlayerID() then refresh() end
end

function widget:ViewResize(x, y)
	local ox, oy = vsx, vsy
	vsx, vsy = x, y
	if px and ox > 0 and oy > 0 then
		px, ytop = px / ox * vsx, ytop / oy * vsy
		clampPos()
	end
end

function widget:GetConfigData()
	if not px then return nil end
	return {
		ox = px / vsx, oy = ytop / vsy,
		scale = userScale, showT2 = showT2, override = override,
	}
end

function widget:SetConfigData(data)
	if not data then return end
	savedFX, savedFY = data.ox, data.oy
	userScale = data.scale or userScale
	if data.showT2 ~= nil then showT2 = data.showT2 end
	override = data.override
end
