local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Joint Command Protocol",
		desc = "Tournament unit-sharing for coordinated allied teams",
		author = "Vdb",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 9999,
		enabled = true,
		handler = true,
	}
end

-- TOURNAMENT AUTO-SHARE SETUP
-- This widget is intentionally enabled by default for its dedicated tournament mode.
-- In the supported 2v2 format there is one allied teammate, so use "ALLY" as the target.
-- Add/remove unit def names here to control exactly which units auto-share.
-- Examples:
--   armflea = { "ALLY" },
--   corak   = { "ALLY" },
--   armpw   = { "ALLY" },
local startupRules = {
	-- armflea = { "ALLY" },
	-- corak   = { "ALLY" },
	-- armpw   = { "ALLY" },
}

-- If false, the widget ignores old saved /luaui unitshare rules and only uses
-- the hard-coded startupRules above plus any factory-menu choices made this game.
local USE_SAVED_RUNTIME_RULES = false


-- Tournament default: automatically share every finished whitelisted unit to your only ally.
-- Set this to false only when using the optional per-factory recipient controls instead.
local SHARE_ALL_UNITS_TO_ALLY = true

local CONFIG_KEY = "unit_auto_share_by_type_rules_v1"
local ECHO_PREFIX = "[Joint Command Protocol] "
local CMD_FACTORY_SHARE_MENU = 455698
local TARGET_RANGE = 200

local spEcho = Spring.Echo
local spGetMyTeamID = Spring.GetMyTeamID
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetTeamAllyTeamID = Spring.GetTeamAllyTeamID
local spGetTeamList = Spring.GetTeamList
local spGetTeamInfo = Spring.GetTeamInfo
local spGetPlayerList = Spring.GetPlayerList
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetGameRulesParam = Spring.GetGameRulesParam
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spSelectUnitArray = Spring.SelectUnitArray
local spShareResources = Spring.ShareResources
local spGetConfigString = Spring.GetConfigString or function(_, default) return default end
local spSetConfigString = Spring.SetConfigString or function() end
local spGetSpectatingState = Spring.GetSpectatingState
local spGetViewGeometry = Spring.GetViewGeometry

local lower = string.lower
local gsub = string.gsub
local match = string.match
local tonumber = tonumber
local tostring = tostring
local concat = table.concat

local myTeamID
local myAllyTeamID
local rules = {}
local factoryRules = {}
local unitToFactoryID = {}
local unitAliases = {}
local factoryDefIDs = {}
local immediateShares = {}
local immediateCount = 0
local enabled = true
local announceShares = false
local menu = {
	open = false,
	factoryID = nil,
	factoryDefID = nil,
	factories = {},
	selectedUnitDefID = nil,
	clickAreas = {},
}

local glColor = gl.Color
local glRect = gl.Rect
local glText = gl.Text

local function echo(message)
	spEcho(ECHO_PREFIX .. message)
end

local function normalize(value)
	value = lower(tostring(value or ""))
	return gsub(value, "[%s_%-%p]+", "")
end

-- Simple exact whitelist mode.
-- ONLY units listed here will be shared.
local shareWhitelist = {
	["armflea"] = true,
	["armpw"] = true,
	["armrock"] = true,
	["armjeth"] = true,
	["armkam"] = true,
	["armham"] = true,
	["armrectr"] = true,
	["armwar"] = true,
	["armvader"] = true,
	["armaser"] = true,
	["armmark"] = true,
	["armspy"] = true,
	["armfast"] = true,
	["armspid"] = true,
	["armamph"] = true,
	["armfido"] = true,
	["armfig"] = true,
	["armzeus"] = true,
	["armsptk"] = true,
	["armaak"] = true,
	["armmav"] = true,
	["armsnipe"] = true,
	["armscab"] = true,
	["armfboy"] = true,
	["armmar"] = true,
	["armvang"] = true,
	["armraz"] = true,
	["armbanth"] = true,
	["corak"] = true,
	["corstorm"] = true,
	["corcrash"] = true,
	["cornecro"] = true,
	["corthud"] = true,
	["corroach"] = true,
	["corspec"] = true,
	["corvoyr"] = true,
	["corspy"] = true,
	["corpyro"] = true,
	["coramph"] = true,
	["cormort"] = true,
	["cortermite"] = true,
	["corcan"] = true,
	["corhrk"] = true,
	["coraak"] = true,
	["cordecom"] = true,
	["corsktl"] = true,
	["cormando"] = true,
	["corsumo"] = true,
	["corshiva"] = true,
	["corkarg"] = true,
	["corcat"] = true,
	["cordemon"] = true,
	["corjugg"] = true,
	["corkorg"] = true,
	["armdecom"] = true,
	["armfav"] = true,
	["armmlv"] = true,
	["armflash"] = true,
	["armart"] = true,
	["armsam"] = true,
	["armpincer"] = true,
	["armstump"] = true,
	["armjanus"] = true,
	["armjam"] = true,
	["armseer"] = true,
	["armgremlin"] = true,
	["armmart"] = true,
	["armlatnk"] = true,
	["armyork"] = true,
	["armcroc"] = true,
	["armmerl"] = true,
	["armbull"] = true,
	["armmanni"] = true,
	["armthor"] = true,
	["corfav"] = true,
	["cormlv"] = true,
	["corgator"] = true,
	["cormist"] = true,
	["corwolv"] = true,
	["corgarp"] = true,
	["corlevlr"] = true,
	["corraid"] = true,
	["corvrad"] = true,
	["coreter"] = true,
	["corsala"] = true,
	["cormart"] = true,
	["corsent"] = true,
	["correap"] = true,
	["corvroc"] = true,
	["corban"] = true,
	["corparrow"] = true,
	["cormabm"] = true,
	["corgol"] = true,
	["cortrem"] = true,
	["armpeep"] = true,
	["armsfig"] = true,
	["armsehak"] = true,
	["armthund"] = true,
	["armsaber"] = true,
	["armsb"] = true,
	["armseap"] = true,
	["armhawk"] = true,
	["armawac"] = true,
	["armpnix"] = true,
	["armbrawl"] = true,
	["armdfly"] = true,
	["armlance"] = true,
	["armstil"] = true,
	["armblade"] = true,
	["armliche"] = true,
	["corfink"] = true,
	["corbw"] = true,
	["corveng"] = true,
	["corsfig"] = true,
	["corhunt"] = true,
	["corshad"] = true,
	["corsb"] = true,
	["corcut"] = true,
	["corseap"] = true,
	["corvamp"] = true,
	["corawac"] = true,
	["corhurc"] = true,
	["corape"] = true,
	["cortitan"] = true,
	["corcrwh"] = true,
	["armpt"] = true,
	["armdecade"] = true,
	["armrecl"] = true,
	["armpship"] = true,
	["armsub"] = true,
	["armroy"] = true,
	["armsjam"] = true,
	["armlship"] = true,
	["armsubk"] = true,
	["armaas"] = true,
	["armcrus"] = true,
	["armantiship"] = true,
	["armserp"] = true,
	["armmship"] = true,
	["armbats"] = true,
	["armepoch"] = true,
	["coresupp"] = true,
	["corpt"] = true,
	["correcl"] = true,
	["corpship"] = true,
	["corsub"] = true,
	["corroy"] = true,
	["corsjam"] = true,
	["corfship"] = true,
	["corshark"] = true,
	["corarch"] = true,
	["corcrus"] = true,
	["corantiship"] = true,
	["corssub"] = true,
	["cormship"] = true,
	["corbats"] = true,
	["corblackhy"] = true,
	["armsh"] = true,
	["armmh"] = true,
	["armah"] = true,
	["armanac"] = true,
	["armlun"] = true,
	["corsh"] = true,
	["cormh"] = true,
	["corah"] = true,
	["corsnap"] = true,
	["corhal"] = true,
	["corsok"] = true,
}

local function shouldShareUnit(unitDefID)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef or not unitDef.name then
		return false
	end

	-- Exact internal BAR unit-name whitelist only.
	return shareWhitelist[unitDef.name] == true
end

local function splitList(value, separator)
	local result = {}
	for item in string.gmatch(value or "", "([^" .. separator .. "]+)") do
		local trimmed = string.match(item, "^%s*(.-)%s*$")
		if trimmed ~= "" then
			result[#result + 1] = trimmed
		end
	end
	return result
end

local function getUnitKey(unitName)
	if not unitName then
		return nil
	end
	return unitAliases[normalize(unitName)]
end

local function rebuildUnitAliases()
	unitAliases = {}
	factoryDefIDs = {}
	for unitDefID, unitDef in pairs(UnitDefs) do
		local names = {
			unitDef.name,
			unitDef.humanName,
			unitDef.translatedHumanName,
		}
		for i = 1, #names do
			if names[i] then
				unitAliases[normalize(names[i])] = unitDefID
			end
		end
		if unitDef.isFactory then
			factoryDefIDs[unitDefID] = true
		end
	end
end

local function getDisplayUnitName(unitDefID)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then
		return tostring(unitDefID)
	end
	if unitDef.translatedHumanName and unitDef.translatedHumanName ~= "" then
		return unitDef.translatedHumanName
	end
	if unitDef.humanName and unitDef.humanName ~= "" then
		return unitDef.humanName
	end
	if unitDef.name and unitDef.name ~= "" then
		return unitDef.name
	end
	return tostring(unitDefID)
end

local function resolveUnitDefID(value)
	if not value then
		return nil
	end

	local numericValue = tonumber(value)
	if numericValue then
		if UnitDefs[numericValue] then
			return numericValue
		elseif UnitDefs[-numericValue] then
			return -numericValue
		end
	end

	if type(value) == "string" then
		if UnitDefNames and UnitDefNames[value] then
			return UnitDefNames[value].id
		end
		return getUnitKey(value)
	end

	return nil
end

local function getFactoryBuildOptions(factoryID, factoryDefID)
	local seen = {}
	local result = {}

	if factoryID and spGetUnitCmdDescs then
		local cmdDescs = spGetUnitCmdDescs(factoryID) or {}
		for i = 1, #cmdDescs do
			local cmdID = cmdDescs[i].id
			if cmdID and cmdID < 0 then
				local unitDefID = -cmdID
				if UnitDefs[unitDefID] and not seen[unitDefID] then
					seen[unitDefID] = true
					result[#result + 1] = unitDefID
				end
			end
		end
	end

	if #result > 0 then
		table.sort(result, function(a, b)
			return getDisplayUnitName(a) < getDisplayUnitName(b)
		end)
		return result
	end

	local factoryDef = UnitDefs[factoryDefID]
	local buildOptions = factoryDef and factoryDef.buildOptions
	if not buildOptions then
		return {}
	end

	for key, value in pairs(buildOptions) do
		local unitDefID = resolveUnitDefID(value)
		if not unitDefID and type(key) ~= "number" then
			unitDefID = resolveUnitDefID(key)
		end
		if unitDefID and UnitDefs[unitDefID] and not seen[unitDefID] then
			seen[unitDefID] = true
			result[#result + 1] = unitDefID
		end
	end

	table.sort(result, function(a, b)
		return getDisplayUnitName(a) < getDisplayUnitName(b)
	end)

	return result
end

local function saveRules()
	if not USE_SAVED_RUNTIME_RULES then
		return
	end

	local encoded = {}
	for unitDefID, rule in pairs(rules) do
		if rule.targets and #rule.targets > 0 then
			encoded[#encoded + 1] = tostring(unitDefID) .. "=" .. concat(rule.targets, ",")
		end
	end
	spSetConfigString(CONFIG_KEY, concat(encoded, ";"))
end

local function setRule(unitDefID, targets, shouldSave)
	if not unitDefID or not UnitDefs[unitDefID] then
		return false
	end
	if not targets or #targets == 0 then
		rules[unitDefID] = nil
	else
		rules[unitDefID] = {
			targets = targets,
			nextTarget = 1,
		}
	end
	if shouldSave then
		saveRules()
	end
	return true
end

local function loadStartupRules()
	for unitName, targets in pairs(startupRules) do
		local unitDefID = getUnitKey(unitName)
		if unitDefID and targets and #targets > 0 then
			setRule(unitDefID, targets, false)
		end
	end
end

local function loadSavedRules()
	if not USE_SAVED_RUNTIME_RULES then
		return
	end

	local saved = spGetConfigString(CONFIG_KEY, "")
	for _, entry in ipairs(splitList(saved, ";")) do
		local unitDefIDText, targetsText = match(entry, "^([^=]+)=?(.*)$")
		local unitDefID = tonumber(unitDefIDText)
		if unitDefID and targetsText and targetsText ~= "" then
			setRule(unitDefID, splitList(targetsText, ","), false)
		end
	end
end

local function getTeamDisplayName(teamID)
	local aiName = spGetGameRulesParam("ainame_" .. teamID)
	if aiName then
		return aiName
	end

	local players = spGetPlayerList(teamID) or {}
	for i = 1, #players do
		local name, active, spec = spGetPlayerInfo(players[i], false)
		if name and active and not spec then
			return name
		end
	end

	local _, leader = spGetTeamInfo(teamID, false)
	if leader then
		local name = spGetPlayerInfo(leader, false)
		if name then
			return name
		end
	end

	return "team " .. tostring(teamID)
end

local function resolveTargetTeam(target)
	-- Special 2v2 shortcut: "ALLY" means "the only allied teammate".
	-- This avoids needing to know the player's name or team ID before the game.
	if normalize(target) == "ally" then
		local teams = spGetTeamList(myAllyTeamID) or {}
		for i = 1, #teams do
			local teamID = teams[i]
			if teamID ~= myTeamID then
				return teamID
			end
		end
		return nil
	end

	local numericTeamID = tonumber(target)
	if numericTeamID and spGetTeamAllyTeamID(numericTeamID) == myAllyTeamID and numericTeamID ~= myTeamID then
		return numericTeamID
	end

	local wanted = normalize(target)
	local teams = spGetTeamList(myAllyTeamID) or {}
	for i = 1, #teams do
		local teamID = teams[i]
		if teamID ~= myTeamID then
			local teamName = getTeamDisplayName(teamID)
			if normalize(teamName) == wanted then
				return teamID
			end
		end
	end

	for i = 1, #teams do
		local teamID = teams[i]
		if teamID ~= myTeamID then
			local teamName = getTeamDisplayName(teamID)
			if string.find(normalize(teamName), wanted, 1, true) then
				return teamID
			end
		end
	end

	return nil
end

local function chooseTargetTeam(rule)
	local targetCount = #rule.targets
	if targetCount == 0 then
		return nil
	end

	local startIndex = rule.nextTarget or 1
	for offset = 0, targetCount - 1 do
		local index = ((startIndex + offset - 1) % targetCount) + 1
		local teamID = resolveTargetTeam(rule.targets[index])
		if teamID then
			rule.nextTarget = (index % targetCount) + 1
			return teamID
		end
	end

	return nil
end

local function getSelectedFactories()
	local selected = spGetSelectedUnits()
	local factories = {}
	for i = 1, #selected do
		local factoryID = selected[i]
		if spGetUnitTeam(factoryID) == myTeamID then
			local factoryDefID = spGetUnitDefID(factoryID)
			if factoryDefID and factoryDefIDs[factoryDefID] then
				factories[#factories + 1] = {
					id = factoryID,
					defID = factoryDefID,
				}
			end
		end
	end

	if #factories == 0 then
		return nil
	end
	return factories
end

local function getSelectedFactory()
	local factories = getSelectedFactories()
	if not factories or #factories ~= 1 then
		return nil
	end
	return factories[1].id, factories[1].defID
end

local function selectedFactoriesMatchMenu()
	local factories = getSelectedFactories()
	if not factories or #factories ~= #menu.factories then
		return false
	end

	local selectedByID = {}
	for i = 1, #factories do
		selectedByID[factories[i].id] = true
	end
	for i = 1, #menu.factories do
		if not selectedByID[menu.factories[i].id] then
			return false
		end
	end
	return true
end

local function isAllyTeam(teamID)
	return teamID and teamID ~= myTeamID and spGetTeamAllyTeamID(teamID) == myAllyTeamID
end

local function findTeamInArea(x, z)
	local foundUnits = spGetUnitsInCylinder(x, z, TARGET_RANGE, -3)
	if not foundUnits or #foundUnits == 0 then
		return nil
	end

	local bestTeamID
	local bestCount = 0
	local counts = {}
	for i = 1, #foundUnits do
		local unitTeamID = spGetUnitTeam(foundUnits[i])
		if isAllyTeam(unitTeamID) then
			counts[unitTeamID] = (counts[unitTeamID] or 0) + 1
			if counts[unitTeamID] > bestCount then
				bestTeamID = unitTeamID
				bestCount = counts[unitTeamID]
			end
		end
	end

	return bestTeamID
end

local function getTargetTeam(cmdParams)
	if #cmdParams == 1 then
		local targetUnitID = cmdParams[1]
		local targetTeamID = spGetUnitTeam(targetUnitID)
		if isAllyTeam(targetTeamID) then
			return targetTeamID
		end
	elseif #cmdParams == 3 then
		return findTeamInArea(cmdParams[1], cmdParams[3])
	end

	return nil
end

local function targetIndex(targets, targetTeamID)
	local targetTeamText = tostring(targetTeamID)
	for i = 1, #targets do
		if tostring(targets[i]) == targetTeamText or resolveTargetTeam(targets[i]) == targetTeamID then
			return i
		end
	end
	return nil
end

local function describeFactoryRule(factoryID, unitDefID)
	local rule = factoryRules[factoryID] and factoryRules[factoryID][unitDefID]
	if not rule or #rule.targets == 0 then
		return "no recipients"
	end

	local names = {}
	for i = 1, #rule.targets do
		local teamID = resolveTargetTeam(rule.targets[i])
		names[#names + 1] = teamID and getTeamDisplayName(teamID) or tostring(rule.targets[i])
	end
	return concat(names, ", ")
end

local function hasFactoryRecipient(factoryID, unitDefID, teamID)
	local rule = factoryRules[factoryID] and factoryRules[factoryID][unitDefID]
	return rule and targetIndex(rule.targets, teamID) ~= nil
end

local function factoryCanBuild(factory, unitDefID)
	local buildOptions = getFactoryBuildOptions(factory.id, factory.defID)
	for i = 1, #buildOptions do
		if buildOptions[i] == unitDefID then
			return true
		end
	end
	return false
end

local function getMenuBuildOptions()
	local seen = {}
	local result = {}
	for i = 1, #menu.factories do
		local factory = menu.factories[i]
		local buildOptions = getFactoryBuildOptions(factory.id, factory.defID)
		for j = 1, #buildOptions do
			local unitDefID = buildOptions[j]
			if not seen[unitDefID] then
				seen[unitDefID] = true
				result[#result + 1] = unitDefID
			end
		end
	end
	table.sort(result, function(a, b)
		return getDisplayUnitName(a) < getDisplayUnitName(b)
	end)
	return result
end

local function describeMenuRule(unitDefID)
	local parts = {}
	local sameDescription
	local different = false
	for i = 1, #menu.factories do
		local factory = menu.factories[i]
		if factoryCanBuild(factory, unitDefID) then
			local description = describeFactoryRule(factory.id, unitDefID)
			if not sameDescription then
				sameDescription = description
			elseif sameDescription ~= description then
				different = true
			end
			parts[#parts + 1] = description
		end
	end

	if #parts == 0 then
		return "not buildable by selected factories"
	end
	if different then
		return "mixed recipients"
	end
	return sameDescription or "no recipients"
end

local function menuRecipientState(unitDefID, teamID)
	local buildableCount = 0
	local enabledCount = 0
	for i = 1, #menu.factories do
		local factory = menu.factories[i]
		if factoryCanBuild(factory, unitDefID) then
			buildableCount = buildableCount + 1
			if hasFactoryRecipient(factory.id, unitDefID, teamID) then
				enabledCount = enabledCount + 1
			end
		end
	end

	if buildableCount == 0 or enabledCount == 0 then
		return "off"
	elseif enabledCount == buildableCount then
		return "on"
	end
	return "mixed"
end

local function toggleFactoryRecipient(factoryID, unitDefID, targetTeamID)
	factoryRules[factoryID] = factoryRules[factoryID] or {}
	local rule = factoryRules[factoryID][unitDefID] or {
		targets = {},
		nextTarget = 1,
	}
	factoryRules[factoryID][unitDefID] = rule

	local existingIndex = targetIndex(rule.targets, targetTeamID)
	if existingIndex then
		table.remove(rule.targets, existingIndex)
		if #rule.targets == 0 then
			factoryRules[factoryID][unitDefID] = nil
		end
		echo("Removed " .. getTeamDisplayName(targetTeamID) .. " from factory " .. getDisplayUnitName(unitDefID) .. " sharing.")
	else
		rule.targets[#rule.targets + 1] = tostring(targetTeamID)
		echo("Factory will share " .. getDisplayUnitName(unitDefID) .. " to " .. describeFactoryRule(factoryID, unitDefID) .. ".")
	end
end

local function setFactoryRecipient(factoryID, unitDefID, targetTeamID, enabled)
	factoryRules[factoryID] = factoryRules[factoryID] or {}
	local rule = factoryRules[factoryID][unitDefID] or {
		targets = {},
		nextTarget = 1,
	}
	factoryRules[factoryID][unitDefID] = rule

	local existingIndex = targetIndex(rule.targets, targetTeamID)
	if enabled and not existingIndex then
		rule.targets[#rule.targets + 1] = tostring(targetTeamID)
	elseif not enabled and existingIndex then
		table.remove(rule.targets, existingIndex)
	end

	if #rule.targets == 0 then
		factoryRules[factoryID][unitDefID] = nil
	end
end

local function toggleMenuRecipient(unitDefID, targetTeamID)
	local state = menuRecipientState(unitDefID, targetTeamID)
	local shouldEnable = state ~= "on"
	local changedFactories = 0
	for i = 1, #menu.factories do
		local factory = menu.factories[i]
		if factoryCanBuild(factory, unitDefID) then
			setFactoryRecipient(factory.id, unitDefID, targetTeamID, shouldEnable)
			changedFactories = changedFactories + 1
		end
	end

	local action = shouldEnable and "give" or "stop giving"
	echo("Set " .. tostring(changedFactories) .. " factory/factories to " .. action .. " " .. getDisplayUnitName(unitDefID) .. " to " .. getTeamDisplayName(targetTeamID) .. ".")
end

local function closeMenu()
	menu.open = false
	menu.factoryID = nil
	menu.factoryDefID = nil
	menu.factories = {}
	menu.selectedUnitDefID = nil
	menu.clickAreas = {}
end

local function openMenu(factories)
	menu.open = true
	menu.factories = factories
	menu.factoryID = factories[1].id
	menu.factoryDefID = factories[1].defID
	menu.clickAreas = {}

	local buildOptions = getMenuBuildOptions()
	if buildOptions[1] and (not menu.selectedUnitDefID or not UnitDefs[menu.selectedUnitDefID]) then
		menu.selectedUnitDefID = buildOptions[1]
	end
end

local function toggleMenu()
	local factories = getSelectedFactories()
	if not factories then
		echo("Select one or more factories first.")
		closeMenu()
		return
	end

	if menu.open and selectedFactoriesMatchMenu() then
		closeMenu()
	else
		openMenu(factories)
	end
end

local function getAlliedTeams()
	local result = {}
	local teams = spGetTeamList(myAllyTeamID) or {}
	for i = 1, #teams do
		local teamID = teams[i]
		if teamID ~= myTeamID then
			result[#result + 1] = teamID
		end
	end
	return result
end

local function drawBox(x1, y1, x2, y2, color)
	glColor(color[1], color[2], color[3], color[4])
	glRect(x1, y1, x2, y2)
end

local function drawLabel(text, x, y, size, color, options)
	glColor(color[1], color[2], color[3], color[4])
	glText(text, x, y, size, options or "o")
end

local function addClickArea(kind, x1, y1, x2, y2, value)
	menu.clickAreas[#menu.clickAreas + 1] = {
		kind = kind,
		x1 = x1,
		y1 = y1,
		x2 = x2,
		y2 = y2,
		value = value,
	}
end

local function installOrderMenuTranslations()
	local translations = {
		en = {
			ui = {
				orderMenu = {
					autogivefactory = "Auto Give To",
					autogivefactory_tooltip = "Choose which units this factory auto-gives, and to which allies.",
				},
			},
		},
	}

	if Spring.I18N and Spring.I18N.load then
		Spring.I18N.load(translations)
	end
	if Spring.I18N and Spring.I18N.set then
		Spring.I18N.set("en.ui.orderMenu.autogivefactory", "Auto Give To")
		Spring.I18N.set("en.ui.orderMenu.autogivefactory_tooltip", "Choose which units this factory auto-gives, and to which allies.")
	end

	local i18n = WG and WG.i18n
	if not i18n or not i18n.set then
		return
	end

	i18n.set("en.ui.orderMenu.autogivefactory", "Auto Give To")
	i18n.set("en.ui.orderMenu.autogivefactory_tooltip", "Choose which units this factory auto-gives, and to which allies.")
end

local function enqueueShare(unitID, unitDefID)
	-- Share as soon as possible after UnitFinished.
	-- This bypasses the old low-cost batching delay.
	immediateCount = immediateCount + 1
	immediateShares[immediateCount] = {
		unitID = unitID,
		unitDefID = unitDefID,
	}
end

local function shareUnitArray(unitIDs, targetTeamID)
	local oldSelection = spGetSelectedUnits()
	spSelectUnitArray(unitIDs)
	spShareResources(targetTeamID, "units")
	spSelectUnitArray(oldSelection)
end

local function getShareTarget(unitID, unitDefID)
	local factoryID = unitToFactoryID[unitID]
	local factoryRule = factoryID and factoryRules[factoryID] and factoryRules[factoryID][unitDefID]
	if factoryRule then
		return chooseTargetTeam(factoryRule), true
	end

	local rule = rules[unitDefID]
	if rule then
		return chooseTargetTeam(rule), false
	end

	return nil, false
end

local function shareUnit(unitID, unitDefID)
	local targetTeamID, fromFactory = getShareTarget(unitID, unitDefID)
	if not targetTeamID then
		echo("No valid " .. (fromFactory and "factory recipient" or "allied target") .. " for " .. getDisplayUnitName(unitDefID))
		return
	end

	shareUnitArray({ unitID }, targetTeamID)

	if announceShares then
		echo("Shared " .. getDisplayUnitName(unitDefID) .. " to " .. getTeamDisplayName(targetTeamID))
	end
end

local function processImmediateShares()
	if immediateCount == 0 then
		return
	end

	local current = immediateShares
	local currentCount = immediateCount
	immediateShares = {}
	immediateCount = 0

	for i = 1, currentCount do
		local pending = current[i]
		if pending
			and spGetUnitTeam(pending.unitID) == myTeamID
			and spGetUnitDefID(pending.unitID) == pending.unitDefID
		then
			shareUnit(pending.unitID, pending.unitDefID)
		end
	end
end

local function listRules()
	local lines = {}
	for unitDefID, rule in pairs(rules) do
		lines[#lines + 1] = getDisplayUnitName(unitDefID) .. " -> " .. concat(rule.targets, ", ")
	end
	if #lines == 0 then
		echo("No rules. Add one with: /luaui unitshare add <unit> <player-or-teamID> [more targets]")
		return
	end
	for i = 1, #lines do
		echo(lines[i])
	end
end

local function unitShareAction(_, _, params)
	local subcommand = params and params[1] and lower(params[1]) or "help"

	if subcommand == "add" then
		local unitName = params[2]
		local unitDefID = getUnitKey(unitName)
		if not unitDefID then
			echo("Unknown unit type: " .. tostring(unitName))
			return
		end

		local rawTargets = {}
		for i = 3, #params do
			rawTargets[#rawTargets + 1] = params[i]
		end
		local targets = splitList(concat(rawTargets, " "), ",")
		if #targets == 0 then
			echo("Add a target player name or team ID.")
			return
		end

		setRule(unitDefID, targets, true)
		echo("Rule set: " .. getDisplayUnitName(unitDefID) .. " -> " .. concat(targets, ", "))
	elseif subcommand == "remove" or subcommand == "rm" then
		local unitName = params[2]
		local unitDefID = getUnitKey(unitName)
		if not unitDefID then
			echo("Unknown unit type: " .. tostring(unitName))
			return
		end
		setRule(unitDefID, nil, true)
		echo("Removed rule for " .. getDisplayUnitName(unitDefID))
	elseif subcommand == "clear" then
		rules = {}
		saveRules()
		echo("Cleared all rules.")
	elseif subcommand == "list" then
		listRules()
	elseif subcommand == "on" or subcommand == "enable" then
		enabled = true
		echo("Enabled.")
	elseif subcommand == "off" or subcommand == "disable" then
		enabled = false
		echo("Disabled.")
	elseif subcommand == "announce" then
		announceShares = not announceShares
		echo("Share announcements " .. (announceShares and "enabled." or "disabled."))
	else
		echo("Usage: /luaui unitshare add <unit> <player-or-teamID> [more targets]")
		echo("Other commands: list, remove <unit>, clear, on, off, announce")
	end
end

function widget:TextCommand(command)
	local action, rest = string.match(command or "", "^%s*(%S+)%s*(.-)%s*$")
	if action ~= "unitshare" then
		return
	end

	local params = {}
	for token in string.gmatch(rest or "", "%S+") do
		params[#params + 1] = token
	end
	unitShareAction(nil, nil, params)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if not enabled or unitTeam ~= myTeamID then
		return
	end

	if SHARE_ALL_UNITS_TO_ALLY then
		if shouldShareUnit(unitDefID) then
			rules[unitDefID] = rules[unitDefID] or {
				targets = {"ALLY"},
				nextTarget = 1,
			}
			enqueueShare(unitID, unitDefID)
		end
		return
	end

	local factoryID = unitToFactoryID[unitID]
	if (factoryID and factoryRules[factoryID] and factoryRules[factoryID][unitDefID]) or rules[unitDefID] then
		enqueueShare(unitID, unitDefID)
	end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
	if unitTeam == myTeamID and builderID then
		local builderDefID = spGetUnitDefID(builderID)
		if builderDefID and factoryDefIDs[builderDefID] then
			unitToFactoryID[unitID] = builderID
		end
	end
end

local function removeUnit(unitID, unitDefID, unitTeam)
	if unitTeam == myTeamID then
		unitToFactoryID[unitID] = nil
		if factoryDefIDs[unitDefID] then
			factoryRules[unitID] = nil
		end
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	removeUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	if oldTeam == myTeamID and newTeam ~= myTeamID then
		removeUnit(unitID, unitDefID, oldTeam)
	end
end

function widget:CommandNotify(cmdID, cmdParams)
	if cmdID == CMD_FACTORY_SHARE_MENU then
		toggleMenu()
		return true
	end
end

function widget:CommandsChanged()
	local factories = getSelectedFactories()
	if not factories then
		return
	end

	menu.factories = factories
	local buildOptions = getMenuBuildOptions()
	if #buildOptions == 0 then
		return
	end
	if not menu.open then
		menu.factories = {}
	end

	local customCommands = widgetHandler.customCommands
	customCommands[#customCommands + 1] = {
		id = CMD_FACTORY_SHARE_MENU,
		type = CMDTYPE.ICON,
		name = "Auto Give To",
		tooltip = "Choose which units this factory auto-gives, and to which allies.",
		action = "autogivefactory",
	}
end

function widget:DrawScreen()
	if not menu.open then
		return
	end

	if not selectedFactoriesMatchMenu() then
		closeMenu()
		return
	end

	local buildOptions = getMenuBuildOptions()
	if #buildOptions == 0 then
		closeMenu()
		return
	end
	local selectedStillBuildable = false
	for i = 1, #buildOptions do
		if buildOptions[i] == menu.selectedUnitDefID then
			selectedStillBuildable = true
			break
		end
	end
	if not selectedStillBuildable then
		menu.selectedUnitDefID = buildOptions[1]
	end

	local vsx, vsy = spGetViewGeometry()
	local panelW = 520
	local panelH = 420
	local x1 = math.max(16, vsx - panelW - 24)
	local y2 = math.min(vsy - 80, vsy - 24)
	local y1 = y2 - panelH
	local x2 = x1 + panelW
	local headerH = 38
	local rowH = 28
	local leftW = 250
	local pad = 12

	menu.clickAreas = {}

	drawBox(x1, y1, x2, y2, { 0.05, 0.055, 0.06, 0.92 })
	drawBox(x1, y2 - headerH, x2, y2, { 0.12, 0.14, 0.16, 0.95 })
	local title = #menu.factories > 1 and ("Factory Share Setup (" .. tostring(#menu.factories) .. " factories)") or "Factory Share Setup"
	drawLabel(title, x1 + pad, y2 - 25, 16, { 1, 1, 1, 1 })

	local closeX1 = x2 - 34
	addClickArea("close", closeX1, y2 - 32, x2 - 10, y2 - 8)
	drawLabel("x", closeX1 + 7, y2 - 26, 16, { 1, 0.72, 0.72, 1 })

	drawLabel("Unit", x1 + pad, y2 - headerH - 22, 13, { 0.78, 0.86, 1, 1 })
	drawLabel("Share To", x1 + leftW + pad, y2 - headerH - 22, 13, { 0.78, 0.86, 1, 1 })

	local unitY = y2 - headerH - 54
	for i = 1, #buildOptions do
		local unitDefID = buildOptions[i]
		local uy1 = unitY - rowH + 5
		local uy2 = unitY + 4
		if unitDefID == menu.selectedUnitDefID then
			drawBox(x1 + 8, uy1, x1 + leftW - 8, uy2, { 0.18, 0.32, 0.42, 0.9 })
		else
			drawBox(x1 + 8, uy1, x1 + leftW - 8, uy2, { 0.1, 0.11, 0.12, 0.85 })
		end
		addClickArea("unit", x1 + 8, uy1, x1 + leftW - 8, uy2, unitDefID)
		drawLabel(getDisplayUnitName(unitDefID), x1 + pad, unitY - 16, 12, { 0.95, 0.95, 0.95, 1 })
		unitY = unitY - rowH
		if unitY < y1 + 58 then
			break
		end
	end

	local selectedUnitDefID = menu.selectedUnitDefID
	local playerY = y2 - headerH - 54
	local alliedTeams = getAlliedTeams()
	for i = 1, #alliedTeams do
		local teamID = alliedTeams[i]
		local py1 = playerY - rowH + 5
		local py2 = playerY + 4
		local state = selectedUnitDefID and menuRecipientState(selectedUnitDefID, teamID) or "off"
		local checked = state == "on"
		local mixed = state == "mixed"
		drawBox(x1 + leftW + 8, py1, x2 - 12, py2, checked and { 0.18, 0.38, 0.22, 0.9 } or (mixed and { 0.28, 0.26, 0.13, 0.9 } or { 0.1, 0.11, 0.12, 0.85 }))
		addClickArea("team", x1 + leftW + 8, py1, x2 - 12, py2, teamID)
		local marker = checked and "[x] " or (mixed and "[-] " or "[ ] ")
		drawLabel(marker .. getTeamDisplayName(teamID), x1 + leftW + pad, playerY - 16, 12, { 0.95, 0.95, 0.95, 1 })
		playerY = playerY - rowH
		if playerY < y1 + 58 then
			break
		end
	end

	local clearY1 = y1 + 14
	local clearY2 = y1 + 42
	addClickArea("clear", x1 + pad, clearY1, x1 + 160, clearY2)
	drawBox(x1 + pad, clearY1, x1 + 160, clearY2, { 0.24, 0.11, 0.11, 0.9 })
	drawLabel("Clear Factory", x1 + pad + 16, clearY1 + 8, 12, { 1, 0.9, 0.9, 1 })

	if selectedUnitDefID then
		drawLabel("Selected: " .. getDisplayUnitName(selectedUnitDefID) .. " -> " .. describeMenuRule(selectedUnitDefID), x1 + 175, clearY1 + 8, 11, { 0.85, 0.9, 1, 1 })
	end
end

function widget:MousePress(x, y, button)
	if not menu.open or button ~= 1 then
		return false
	end

	for i = 1, #menu.clickAreas do
		local area = menu.clickAreas[i]
		if x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 then
			if area.kind == "close" then
				closeMenu()
			elseif area.kind == "unit" then
				menu.selectedUnitDefID = area.value
			elseif area.kind == "team" and menu.selectedUnitDefID then
				toggleMenuRecipient(menu.selectedUnitDefID, area.value)
			elseif area.kind == "clear" then
				for j = 1, #menu.factories do
					factoryRules[menu.factories[j].id] = nil
				end
				echo("Cleared sharing rules for selected factory/factories.")
			end
			return true
		end
	end

	return false
end

function widget:GameFrame(frame)
	processImmediateShares()
end

function widget:PlayerChanged()
	myTeamID = spGetMyTeamID()
	myAllyTeamID = spGetTeamAllyTeamID(myTeamID)
end

function widget:Initialize()
	if spGetSpectatingState() then
		widgetHandler:RemoveWidget(self)
		return
	end

	widget:PlayerChanged()
	rebuildUnitAliases()
	loadStartupRules()
	loadSavedRules()
	installOrderMenuTranslations()

	echo("Loaded in tournament auto-share mode. Finished whitelisted units will be given to your allied teammate.")
end

function widget:Shutdown()
end
