--------------------------------------------------------------------------------
-- Metrostroi Dispatcher — entry point (server only)
--------------------------------------------------------------------------------
Dispatcher = Dispatcher or {}

local function load()
    if not Metrostroi then
        MsgC(Color(255, 120, 80), "[Dispatcher] Metrostroi not found, disabled\n")
        return
    end

    -- Optional per-map config: lua/dispatcher/maps/<mapname>.lua returns a table
    local mapFile = "dispatcher/maps/" .. game.GetMap():lower() .. ".lua"
    Dispatcher.MapConfig = file.Exists(mapFile, "LUA") and include(mapFile) or {}

    include("dispatcher/line.lua")
    include("dispatcher/schedule.lua")
    include("dispatcher/comms.lua")
    include("dispatcher/debug.lua")

    MsgC(Color(120, 200, 255), "[Dispatcher] loaded, map config: ",
        file.Exists(mapFile, "LUA") and mapFile or "none", "\n")
end

-- Metrostroi loads its own files from autorun too; wait until everything is in.
if Dispatcher.Loaded then load() else
    hook.Add("Initialize", "Dispatcher_Load", function() Dispatcher.Loaded = true; load() end)
end
