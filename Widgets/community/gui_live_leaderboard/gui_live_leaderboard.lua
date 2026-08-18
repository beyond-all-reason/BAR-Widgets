function widget:GetInfo()
	return {
		name    = "Live Leaderboard",
		desc    = "A live leader board for resources produced and damage dealt",
		author  = "Richard Ulmer",
		date    = "Jun 2026",
		enabled = true
	}
end

-- Spring API
local GetAllyTeamList     = Spring.GetAllyTeamList
local GetGaiaTeamID       = Spring.GetGaiaTeamID
local GetPlayerInfo       = Spring.GetPlayerInfo
local GetSpectatingState  = Spring.GetSpectatingState
local GetTeamColor        = Spring.GetTeamColor
local GetTeamInfo         = Spring.GetTeamInfo
local GetTeamList         = Spring.GetTeamList
local GetTeamStatsHistory = Spring.GetTeamStatsHistory
local GetViewGeometry     = Spring.GetViewGeometry

-- GL API
local glColor      = gl.Color
local glCreateList = gl.CreateList
local glDeleteList = gl.DeleteList

-- FlowUI
-- See https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/luaui/Widgets/flowui_gl4.lua
local RectRound, UiElement
local guishaderRectDlist = nil

-- Lua stdlib
local insert    = table.insert
local mathFloor = math.floor

-- Config
local anonymousMode      = Spring.GetModOptions().teamcolors_anonymous_mode
local anonymousTeamColor = {
    Spring.GetConfigInt("anonymousColorR", 255) / 255,
    Spring.GetConfigInt("anonymousColorG",   0) / 255,
    Spring.GetConfigInt("anonymousColorB",   0) / 255,
}

-- State
local font
local vsx, vsy          = GetViewGeometry()
local isSpec            = GetSpectatingState()
local gameStarted       = false
local updateDrawing     = false
local passedTime        = 0
local teamCount         = 0
local teamData          = {}
local teamControllers   = {}
local topbar            = true
local topbarShowButtons = true
local displayinfoPos    = {}

-- Layout
local top, left, bottom, right = vsy, 0, 0, vsx
local widgetScale = 1
local textsize    = 0
local margin

local function formatNumber(n)
	if n < 1000 then
		return string.format("%.0f", n)
	elseif n < 10*1000 then
		return string.format("%.1fK", n/1000)
	elseif n < 1000*1000 then
		return string.format("%.0fK", n/1000)
	else
		return string.format("%.1fM", n/1000/1000)
	end
end

local function updatePosition()
	if WG['topbar'] then
		displayinfoPos = WG['topbar'].GetPosition()
		widgetScale = displayinfoPos[5]
		-- TODO: Remove WG['ecostats'].isvisible check once this func is established:
		if WG['ecostats'] and WG['ecostats'].isvisible and WG['ecostats'].isvisible() then
			top = WG['ecostats'].getWidgetPosY()
		elseif topbarShowButtons then
			top = displayinfoPos[2]
		else
			top = vsy
		end
	end
	textsize = 11 * widgetScale
	left     = right - 17*textsize
end

local function drawWidget()
	if teamCount == 0 or not WG['guishader'] then
		return
	end

	glColor(0, 0, 0, 0.7)
	if guishaderRectDlist then
		glDeleteList(guishaderRectDlist)
	end
	guishaderRectDlist = glCreateList(function()
		RectRound(left, bottom, right, top, 4*widgetScale, 1, 1, 1, 1)
	end)
	WG['guishader'].InsertDlist(guishaderRectDlist, 'live_leaderboard_rect')

	local myTeamID = Spring.GetMyTeamID()
	local teamIDs = {}
	for teamID in pairs(teamData) do insert(teamIDs, teamID) end
	
	font:Begin(true)
	local arrWidth = font:GetTextWidth("➡ ") * textsize
	local line = 1
	font:SetTextColor(0.96,0.96,0.96,1)
	font:Print("Resources produced", left+margin, top-margin*line-textsize*line, textsize, 'no')
	line = line + 1
	table.sort(teamIDs, function(a, b)
		return teamData[a].resourcesProduced > teamData[b].resourcesProduced
	end)
	local rank = 1
	for _, teamID in ipairs(teamIDs) do
		local history = teamData[teamID]
		font:SetOutlineColor(0.15,0.15,0.15,0.8)
		font:SetTextColor(history.teamColor[1],history.teamColor[2],history.teamColor[3],1)
		local res = formatNumber(history.resourcesProduced)
		if teamID == myTeamID then
		    font:Print("➡ "..rank..". "..history.playerName, left+margin, top-margin*line-textsize*line, textsize, 'no')
		else
		    font:Print(rank..". "..history.playerName, left+margin+arrWidth, top-margin*line-textsize*line, textsize, 'no')
		end
		font:Print(res, right-3*textsize, top-margin*line-textsize*line, textsize, 'no')
		line = line + 1
		rank = rank + 1
	end

	line = line + 1
	font:SetTextColor(0.96,0.96,0.96,1)
	font:Print("Damage dealt", left+margin, top-margin*line-textsize*line, textsize, 'no')
	line = line + 1
	table.sort(teamIDs, function(a, b)
		return teamData[a].damageDealt > teamData[b].damageDealt
	end)
	local rank = 1
	for _, teamID in ipairs(teamIDs) do
		local history = teamData[teamID]
		font:SetOutlineColor(0.15,0.15,0.15,0.8)
		font:SetTextColor(history.teamColor[1],history.teamColor[2],history.teamColor[3],1)
		if teamID == myTeamID then
		    font:Print("➡ "..rank..". "..history.playerName, left+margin, top-margin*line-textsize*line, textsize, 'no')
		else
		    font:Print(rank..". "..history.playerName, left+margin+arrWidth, top-margin*line-textsize*line, textsize, 'no')
		end
		local dmg = formatNumber(history.damageDealt)
		font:Print(dmg, right-3*textsize, top-margin*line-textsize*line, textsize, 'no')
		line = line + 1
		rank = rank + 1
	end
	font:End()
end

local function refreshUiDrawing()
	local prevBottom = bottom
	-- I'm not sure why I need extra padding at the bottom.
	bottom = math.ceil(top-((2*teamCount+3)*textsize+(5+2*teamCount)*margin))
	if uiWidget and bottom ~= prevBottom then
		gl.DeleteTexture(uiWidget)
		uiWidget = nil
	end

	if right-left >= 1 and top-bottom >= 1 then
		if not uiWidgetBg then
			uiWidgetBg = gl.CreateTexture(mathFloor(right-left), mathFloor(top-bottom), {
				target = GL.TEXTURE_2D,
				format = GL.RGBA,
				fbo = true,
			})
		end
		gl.R2tHelper.RenderInRect(uiWidgetBg, left, bottom, right, top, function()
			UiElement(left, bottom, right, top, 4*widgetScale, 0, 0, 1, 1, 1, 1, 1, nil, nil, nil, nil)
		end, true)

		if not uiWidget then
			uiWidget = gl.CreateTexture(mathFloor(right-left), mathFloor(top-bottom), {
				target = GL.TEXTURE_2D,
				format = GL.RGBA,
				fbo = true,
			})
		end
		gl.R2tHelper.RenderInRect(uiWidget, left, bottom, right, top, drawWidget, true)
	end
end

local function refreshStats()
	teamData = {}
	teamCount = 0
	for _,allyTeamID in ipairs(GetAllyTeamList()) do
		for _,teamID in ipairs(GetTeamList(allyTeamID)) do
			if teamID ~= GetGaiaTeamID() then
				local range = GetTeamStatsHistory(teamID)
				local history = GetTeamStatsHistory(teamID,range)
				if history then
					teamCount = teamCount + 1
					history = history[#history]
					history.resourcesProduced = history.metalProduced + history.energyProduced/60

					-- Find team color:
					local teamColor
					if not isSpec and anonymousMode ~= "disabled" and teamID ~= Spring.GetLocalTeamID() then
						teamColor = { anonymousTeamColor[1], anonymousTeamColor[2], anonymousTeamColor[3] }
					else
						teamColor = { GetTeamColor(teamID) }
					end
					history.teamColor = teamColor

					-- Find player name:
					local _,leader,_ = GetTeamInfo(teamID,false)
					local playerName,_ = GetPlayerInfo(leader,false)
					playerName = (WG.playernames and WG.playernames.getPlayername) and WG.playernames.getPlayername(leader) or playerName
					if Spring.GetGameRulesParam('ainame_'..teamID) then
						playerName = Spring.GetGameRulesParam('ainame_'..teamID)
					end
					if gameStarted == true then
						if not playerName then
							playerName = teamControllers[teamID] or Spring.I18N('ui.teamStats.gone', { player = '' })
						else
							teamControllers[teamID] = playerName
						end
					end
					playerName = playerName or ''
					history.playerName = playerName

					teamData[teamID] = history
				end
			end
		end
	end
end

function widget:DrawScreen()
	if updateDrawing then
		updateDrawing = false
		refreshStats()
		refreshUiDrawing()
	end
	if uiWidgetBg then
		gl.R2tHelper.BlendTexRect(uiWidgetBg, left, bottom, right, top, true)
	end
	if uiWidget then
		gl.R2tHelper.BlendTexRect(uiWidget, left, bottom, right, top, true)
	end
end

function widget:Initialize()
	widget:ViewResize()
	updatePosition()
	WG['live_leaderboard'] = {}
	WG['live_leaderboard'].GetPosition = function()
		return {top,left,bottom,right,widgetScale}
	end
end

function widget:Update(dt)
	local prevTopbarShowButtons = topbarShowButtons
	topbarShowButtons = WG['topbar'] and WG['topbar'].getShowButtons()
	passedTime = passedTime + dt
	if passedTime > 1
		or topbarShowButtons ~= prevTopbarShowButtons
		or not prevTopbar and (WG['topbar'] ~= nil)
		or prevTopbar ~= (WG['topbar'] ~= nil)
	then
		topbarShowButtons = WG['topbar'] and WG['topbar'].getShowButtons()
		updatePosition()
		updateDrawing = true
		passedTime = passedTime - 1
		prevTopbar = WG['topbar'] ~= nil and true or false
	end
end

function widget:PlayerChanged()
	isSpec = GetSpectatingState()
end

function widget:GameStart()
	gameStarted = true
end

function widget:ViewResize(newX, newY)
	vsx, vsy = GetViewGeometry()
	margin = WG.FlowUI.elementMargin
	RectRound = WG.FlowUI.Draw.RectRound
	UiElement = WG.FlowUI.Draw.Element
	font = WG['fonts'].getFont()
	updateDrawing = true
	if uiWidget then
		gl.DeleteTexture(uiWidget)
		uiWidget = nil
	end
end

function widget:Shutdown()
	if uiWidget then
		gl.DeleteTexture(uiWidget)
		uiWidget = nil
	end
	if uiWidgetBg then
		gl.DeleteTexture(uiWidgetBg)
		uiWidgetBg = nil
	end
	if WG['guishader'] then
		WG['guishader'].DeleteDlist('live_leaderboard_rect')
	end
	if guishaderRectDlist then
		gl.DeleteList(guishaderRectDlist)
		guishaderRectDlist = nil
	end
	WG['live_leaderboard'] = nil
end
