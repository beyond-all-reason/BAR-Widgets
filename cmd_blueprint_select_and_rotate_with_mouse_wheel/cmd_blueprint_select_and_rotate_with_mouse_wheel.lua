function widget:GetInfo()
    return {
        name    = "Blueprint Mouse Wheel",
        desc    = "Mouse wheel selects blueprints; Alt+wheel rotates blueprints",
        author  = "Vvsod",
        version = "0.9",
        layer   = 0,   -- IMPORTANT: before Blueprint widget (layer 1)
        handler = true,
        enabled = true,
    }
end

local BLUEPRINT_CMD = 18200

local lastWheel = 0
local WHEEL_RATE_LIMIT = 1 / 15

local lastAltSeen = -100
local ALT_TIMEOUT = 0.25

local function triggerBlueprintAction(action, extra)
    local actions = {
        {
            command = action,
            extra = extra or "",
        }
    }

    return widgetHandler.actionHandler:KeyAction(
        true,
        0,
        nil,
        false,
        0,
        actions
    )
end

function widget:Update()
    local alt = select(1, Spring.GetModKeyState())

    if alt then
        lastAltSeen = Spring.GetGameSeconds()
    end
end

function widget:MouseWheel(up, value)

    local cmdIndex, cmdID = Spring.GetActiveCommand()

    -- Only while Place Blueprint is active.
    if not cmdIndex or cmdID ~= BLUEPRINT_CMD then
        return false
    end

    local now = Spring.GetGameSeconds()

    if now - lastWheel < WHEEL_RATE_LIMIT then
        return true
    end

    lastWheel = now

    local altDown = (now - lastAltSeen) < ALT_TIMEOUT

    -- ALT + wheel = rotate blueprint
    if altDown then

        local extra = up and "inc" or "dec"

        local handled = triggerBlueprintAction(
            "buildfacing",
            extra
        )

        return handled
    end

    -- Normal wheel = next / previous blueprint
    if up then
        triggerBlueprintAction("blueprint_next", "")
    else
        triggerBlueprintAction("blueprint_prev", "")
    end

    return true
end

function widget:Shutdown()
    lastAltSeen = -100
end