-- Stamp
-- Draw on the map, save the strokes, stamp them as real backtick map marks.
-- Beyond All Reason is a free open source RTS.
--
-- Does not touch Alt+C / Alt+B. Those stay the stock building-blueprint binds.
--
--   Ctrl+Alt+D   draw mode (LMB drag)
--   Ctrl+Alt+C   save strokes as a stamp
--   Ctrl+Alt+B   paste mode (LMB stamps real map marks)
--   Ctrl+Alt+[ ] previous / next stamp
--   Ctrl+Alt+R   rotate paste 90 degrees
--   Ctrl+Alt+X   clear unsaved strokes
--   Ctrl+Alt+Q   delete selected saved stamp
--   RMB          cancel draw/paste mode
--
-- Install: <BAR data>/LuaUI/Widgets/gui_stamp.lua
-- Then: /luaui reload
-- Saved to LuaUI/Config/gui_stamps.json

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Stamp",
		desc = "Draw map marks, save them, stamp them. Ctrl+Alt only.",
		author = "Greg Weaver",
		date = "2026-10-19",
		license = "GNU GPL, v2 or later",
		layer = 2,
		enabled = true,
		handler = true,
	}
end

local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetGroundHeight = Spring.GetGroundHeight
local spEcho = Spring.Echo
local MarkerAddLine = Spring.MarkerAddLine
local MarkerAddPoint = Spring.MarkerAddPoint

local MODE_OFF = 0
local MODE_DRAW = 1
local MODE_PASTE = 2

local mode = MODE_OFF
local drawing = false
local currentStroke = nil
local canvas = {}
local blueprints = {}
local selected = 1
local pasteFacing = 0
local lastSampleDistSq = 9 -- capture finely; simplification trims the excess
local CONFIG_PATH = "LuaUI/Config/gui_stamps.json"

local function worldPos(mx, my)
	local _, pos = spTraceScreenRay(mx, my, true, false, false, true)
	if type(pos) == "table" and pos[1] then
		return pos[1], pos[2] or spGetGroundHeight(pos[1], pos[3]), pos[3]
	end
end

local function distSq(a, b)
	local dx, dz = a[1] - b[1], a[3] - b[3]
	return dx * dx + dz * dz
end

local function centroid(strokes)
	local sx, sz, n = 0, 0, 0
	for i = 1, #strokes do
		for j = 1, #strokes[i] do
			sx = sx + strokes[i][j][1]
			sz = sz + strokes[i][j][3]
			n = n + 1
		end
	end
	if n == 0 then
		return 0, 0
	end
	return sx / n, sz / n
end

local function normalizeStrokes(strokes)
	local cx, cz = centroid(strokes)
	local out = {}
	for i = 1, #strokes do
		local ns = {}
		for j = 1, #strokes[i] do
			local p = strokes[i][j]
			ns[j] = { p[1] - cx, p[2], p[3] - cz }
		end
		out[i] = ns
	end
	return out
end

local function rotatePoint(x, z, facing)
	if facing == 1 then
		return z, -x
	elseif facing == 2 then
		return -x, -z
	elseif facing == 3 then
		return -z, x
	end
	return x, z
end

local function placedStrokes(strokes, ox, oz, facing)
	local out = {}
	for i = 1, #strokes do
		local ns = {}
		for j = 1, #strokes[i] do
			local p = strokes[i][j]
			local rx, rz = rotatePoint(p[1], p[3], facing)
			local x, z = ox + rx, oz + rz
			ns[j] = { x, spGetGroundHeight(x, z), z }
		end
		out[i] = ns
	end
	return out
end

-- Fidelity: max distance (world units) a simplified line may stray from the
-- original stroke. Lower = more detail, more marks. 2-4 is a good range.
local SIMPLIFY_TOLERANCE = 3
-- Speed: map-mark lines sent per second. Raise if your games accept it;
-- lower it if lines go missing.
local MARKS_PER_SECOND = 20
-- Cap per Update call so a long frame does not dump a burst.
local MAX_MARKS_PER_UPDATE = 12

local stampQueue = {}
local stampHead = 1
local stampTail = 0
local stampBudget = 0

-- Ramer-Douglas-Peucker (iterative). Keeps corners and curve shape, drops
-- points that sit on a near-straight line. Works on x/z only.
local function simplifyStroke(stroke, tol)
	local n = #stroke
	if n <= 2 then
		return stroke
	end
	local tolSq = tol * tol
	local keep = { [1] = true, [n] = true }
	local stack = { 1, n }
	while #stack > 0 do
		local last = table.remove(stack)
		local first = table.remove(stack)
		local a, b = stroke[first], stroke[last]
		local ax, az = a[1], a[3]
		local dx, dz = b[1] - ax, b[3] - az
		local lenSq = dx * dx + dz * dz
		local maxD, idx = -1, nil
		for i = first + 1, last - 1 do
			local p = stroke[i]
			local px, pz = p[1] - ax, p[3] - az
			local d
			if lenSq == 0 then
				d = px * px + pz * pz
			else
				local t = (px * dx + pz * dz) / lenSq
				if t < 0 then t = 0 elseif t > 1 then t = 1 end
				local ex, ez = px - t * dx, pz - t * dz
				d = ex * ex + ez * ez
			end
			if d > maxD then
				maxD, idx = d, i
			end
		end
		if idx and maxD > tolSq then
			keep[idx] = true
			stack[#stack + 1] = first
			stack[#stack + 1] = idx
			stack[#stack + 1] = idx
			stack[#stack + 1] = last
		end
	end
	local out = {}
	for i = 1, n do
		if keep[i] then
			out[#out + 1] = stroke[i]
		end
	end
	return out
end

-- Simplify a blueprint once and reuse it (preview + stamp). Weak keys so
-- deleted blueprints drop out; never written to the save file.
local simplifiedCache = setmetatable({}, { __mode = "k" })

local function simplifiedStrokes(bp)
	local cached = simplifiedCache[bp]
	if cached then
		return cached
	end
	local out = {}
	for i = 1, #bp.strokes do
		out[i] = simplifyStroke(bp.strokes[i], SIMPLIFY_TOLERANCE)
	end
	simplifiedCache[bp] = out
	return out
end

local function stampStrokes(strokes)
	local n = 0
	for i = 1, #strokes do
		local s = strokes[i]
		for j = 2, #s do
			local a, b = s[j - 1], s[j]
			stampTail = stampTail + 1
			stampQueue[stampTail] = { a[1], a[2] or 0, a[3], b[1], b[2] or 0, b[3] }
			n = n + 1
		end
	end
	spEcho(string.format("[Stamp] stamping %d marks (~%.1fs)", n, (stampTail - stampHead + 1) / MARKS_PER_SECOND))
end

-- Update (not GameFrame) so stamping also runs while paused and is tied to
-- real time instead of sim frames.
function widget:Update(dt)
	if stampHead > stampTail then
		return
	end
	stampBudget = math.min(stampBudget + dt * MARKS_PER_SECOND, MAX_MARKS_PER_UPDATE)
	while stampBudget >= 1 and stampHead <= stampTail do
		local seg = stampQueue[stampHead]
		stampQueue[stampHead] = nil
		stampHead = stampHead + 1
		stampBudget = stampBudget - 1
		MarkerAddLine(seg[1], seg[2], seg[3], seg[4], seg[5], seg[6])
	end
	if stampHead > stampTail then
		stampQueue, stampHead, stampTail, stampBudget = {}, 1, 0, 0
		spEcho("[Stamp] stamp finished")
	end
end

local function tryDecode(raw)
	if Json and Json.decode then
		local ok, data = pcall(Json.decode, raw)
		if ok then
			return data
		end
	end
	if WG and WG.json and WG.json.decode then
		local ok, data = pcall(WG.json.decode, raw)
		if ok then
			return data
		end
	end
end

local function loadBlueprints()
	if not VFS.FileExists(CONFIG_PATH) then
		return
	end
	local raw = VFS.LoadFile(CONFIG_PATH)
	local data = raw and tryDecode(raw)
	if type(data) == "table" then
		blueprints = data
	end
end

local function saveBlueprints()
	local encoded
	if Json and Json.encode then
		encoded = Json.encode(blueprints)
	elseif WG and WG.json and WG.json.encode then
		encoded = WG.json.encode(blueprints)
	end
	if not encoded then
		spEcho("[Stamp] could not encode save file")
		return
	end
	local f = io.open(CONFIG_PATH, "w")
	if not f then
		spEcho("[Stamp] could not write " .. CONFIG_PATH)
		return
	end
	f:write(encoded)
	f:close()
end

local function drawStrokeList(strokes, r, g, b, a)
	if not strokes then
		return
	end
	gl.Color(r, g, b, a or 1)
	gl.LineWidth(3)
	gl.DepthTest(false)
	for i = 1, #strokes do
		local s = strokes[i]
		if #s >= 2 then
			gl.BeginEnd(GL.LINE_STRIP, function()
				for j = 1, #s do
					local p = s[j]
					gl.Vertex(p[1], (p[2] or spGetGroundHeight(p[1], p[3])) + 4, p[3])
				end
			end)
		end
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
	gl.DepthTest(true)
end

local function doToggle()
	mode = (mode == MODE_DRAW) and MODE_OFF or MODE_DRAW
	drawing = false
	currentStroke = nil
	spEcho(mode == MODE_DRAW and "[Stamp] draw ON — LMB drag, then Ctrl+Alt+C" or "[Stamp] off")
end

local function doSave()
	if #canvas == 0 then
		spEcho("[Stamp] nothing to save")
		return
	end
	blueprints[#blueprints + 1] = {
		name = "drawing " .. tostring(#blueprints + 1),
		strokes = normalizeStrokes(canvas),
	}
	selected = #blueprints
	canvas = {}
	saveBlueprints()
	mode = MODE_OFF
	spEcho("[Stamp] saved #" .. selected .. " — Ctrl+Alt+B to paste")
end

local function doPaste()
	if #blueprints == 0 then
		spEcho("[Stamp] no saved stamps")
		return
	end
	mode = (mode == MODE_PASTE) and MODE_OFF or MODE_PASTE
	spEcho(mode == MODE_PASTE and ("[Stamp] paste #" .. selected .. " — LMB stamps a map mark") or "[Stamp] off")
end

local function doNext()
	if #blueprints == 0 then
		return
	end
	selected = selected % #blueprints + 1
	spEcho("[Stamp] #" .. selected)
end

local function doPrev()
	if #blueprints == 0 then
		return
	end
	selected = selected - 1
	if selected < 1 then
		selected = #blueprints
	end
	spEcho("[Stamp] #" .. selected)
end

local function doRot()
	pasteFacing = (pasteFacing + 1) % 4
	spEcho("[Stamp] facing " .. (pasteFacing * 90))
end

local function doClear()
	canvas = {}
	currentStroke = nil
	spEcho("[Stamp] canvas cleared")
end

local function doDelete()
	if #blueprints == 0 then
		spEcho("[Stamp] no saved stamps")
		return
	end
	table.remove(blueprints, selected)
	if selected > #blueprints then
		selected = math.max(#blueprints, 1)
	end
	saveBlueprints()
	spEcho("[Stamp] deleted. " .. #blueprints .. " left, selected #" .. selected)
end

function widget:Initialize()
	if not Json and VFS.FileExists("LuaUI/Include/json.lua") then
		VFS.Include("LuaUI/Include/json.lua")
	end
	loadBlueprints()

	local AH = widgetHandler.actionHandler
	local function add(name, fn)
		AH:AddAction(self, name, function()
			fn()
			return true
		end, nil, "p")
	end
	add("stamp_toggle", doToggle)
	add("stamp_save", doSave)
	add("stamp_paste", doPaste)
	add("stamp_next", doNext)
	add("stamp_prev", doPrev)
	add("stamp_rot", doRot)
	add("stamp_clear", doClear)
	add("stamp_delete", doDelete)

	-- sc_ is the form BAR actually matches. Do not bind plain Alt+C.
	Spring.SendCommands({
		"bind      Ctrl+Alt+d     stamp_toggle",
		"bind      Ctrl+Alt+sc_d  stamp_toggle",
		"bind      Ctrl+Alt+c     stamp_save",
		"bind      Ctrl+Alt+sc_c  stamp_save",
		"bind      Ctrl+Alt+b     stamp_paste",
		"bind      Ctrl+Alt+sc_b  stamp_paste",
		"bind      Ctrl+Alt+]     stamp_next",
		"bind      Ctrl+Alt+[     stamp_prev",
		"bind      Ctrl+Alt+r     stamp_rot",
		"bind      Ctrl+Alt+sc_r  stamp_rot",
		"bind      Ctrl+Alt+x     stamp_clear",
		"bind      Ctrl+Alt+sc_x  stamp_clear",
		"bind      Ctrl+Alt+q     stamp_delete",
		"bind      Ctrl+Alt+sc_q  stamp_delete",
	})
	spEcho("[Stamp] loaded. Ctrl+Alt+D draw, Ctrl+Alt+C save, Ctrl+Alt+B paste. Alt+C is untouched.")
end

function widget:Shutdown()
	local AH = widgetHandler.actionHandler
	AH:RemoveAction(self, "stamp_toggle", "p")
	AH:RemoveAction(self, "stamp_save", "p")
	AH:RemoveAction(self, "stamp_paste", "p")
	AH:RemoveAction(self, "stamp_next", "p")
	AH:RemoveAction(self, "stamp_prev", "p")
	AH:RemoveAction(self, "stamp_rot", "p")
	AH:RemoveAction(self, "stamp_clear", "p")
	AH:RemoveAction(self, "stamp_delete", "p")
end

local KEY_C, KEY_B, KEY_D = 99, 98, 100
local KEY_R, KEY_X = 114, 120

function widget:KeyPress(key, mods, isRepeat, label)
	if isRepeat or not mods.alt or not mods.ctrl or mods.meta then
		return false
	end
	local name = label and string.lower(label) or ""
	if key == KEY_D or name == "d" then
		doToggle()
		return true
	end
	if key == KEY_C or name == "c" then
		doSave()
		return true
	end
	if key == KEY_B or name == "b" then
		doPaste()
		return true
	end
	if key == KEY_R or name == "r" then
		doRot()
		return true
	end
	if key == KEY_X or name == "x" then
		doClear()
		return true
	end
	if name == "q" then
		doDelete()
		return true
	end
	return false
end

function widget:MousePress(mx, my, button)
	if button == 3 and mode ~= MODE_OFF then
		mode = MODE_OFF
		drawing = false
		currentStroke = nil
		spEcho("[Stamp] cancelled")
		return true
	end
	if button ~= 1 then
		return false
	end
	if mode == MODE_DRAW then
		local x, y, z = worldPos(mx, my)
		if not x then
			return false
		end
		drawing = true
		currentStroke = { { x, y, z } }
		return true
	end
	if mode == MODE_PASTE then
		local bp = blueprints[selected]
		if not bp then
			return false
		end
		local x, _, z = worldPos(mx, my)
		if not x then
			return false
		end
		stampStrokes(placedStrokes(simplifiedStrokes(bp), x, z, pasteFacing))
		spEcho("[Stamp] stamped #" .. selected .. " as map marks")
		return true
	end
	return false
end

function widget:MouseMove(mx, my)
	if not drawing or mode ~= MODE_DRAW or not currentStroke then
		return
	end
	local x, y, z = worldPos(mx, my)
	if not x then
		return
	end
	local last = currentStroke[#currentStroke]
	if distSq(last, { x, y, z }) >= lastSampleDistSq then
		currentStroke[#currentStroke + 1] = { x, y, z }
	end
end

function widget:MouseRelease()
	if drawing and currentStroke and #currentStroke >= 1 then
		canvas[#canvas + 1] = currentStroke
	end
	drawing = false
	currentStroke = nil
end

function widget:DrawWorld()
	drawStrokeList(canvas, 0.35, 0.85, 1.0, 0.95)
	if currentStroke then
		drawStrokeList({ currentStroke }, 1.0, 0.95, 0.2, 1)
	end
	if mode == MODE_PASTE and blueprints[selected] then
		local mx, my = spGetMouseState()
		local x, _, z = worldPos(mx, my)
		if x then
			-- preview shows exactly what will be stamped
			drawStrokeList(placedStrokes(simplifiedStrokes(blueprints[selected]), x, z, pasteFacing), 0.2, 1.0, 0.35, 0.9)
		end
	end
end

function widget:DrawScreen()
	if mode == MODE_OFF and #canvas == 0 then
		return
	end
	local label = "Stamp strokes=" .. #canvas
	if mode == MODE_DRAW then
		label = "DRAW  strokes=" .. #canvas .. "   Ctrl+Alt+C save   RMB cancel"
	elseif mode == MODE_PASTE then
		label = "PASTE #" .. selected .. "/" .. #blueprints .. "  " .. (pasteFacing * 90) .. "deg   LMB stamp"
	end
	gl.Color(1, 1, 1, 1)
	gl.Text(label, 20, 80, 16, "o")
end
