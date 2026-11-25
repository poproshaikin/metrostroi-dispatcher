--------------------------------------------------------------------------------
-- Metrostroi Dispatcher — entry point (server only)
--------------------------------------------------------------------------------
Dispatcher = Dispatcher or {}

AddCSLuaFile("autorun/client/dispatcher_cl.lua")   -- marks drawn on the client

-- Chat line to a player. A chat message is limited to 255 bytes (and a
-- Cyrillic letter takes 2), longer ones are silently dropped by the engine:
-- split at spaces into parts of at most MAX bytes.
local MAX = 190
-- kind: nil = chat, or HUD_PRINTCONSOLE / HUD_PRINTCENTER; multi-line text is sent line by line
function Dispatcher.Chat(ply, text, kind)
    if not IsValid(ply) then print(text) return end
    text = tostring(text)
    if text:find("\n", 1, true) then
        for _, line in ipairs(string.Explode("\n", text)) do Dispatcher.Chat(ply, line, kind) end
        return
    end
    if text == "" then return end
    local first = true
    while #text > 0 do
        local part = text
        if #part > MAX then
            local cut = MAX
            -- back off to a space, else at least to a UTF-8 character start
            local sp = part:sub(1, MAX):match(".*() ")
            if sp and sp > MAX / 2 then cut = sp - 1
            else
                while cut > 1 and part:byte(cut + 1) and part:byte(cut + 1) >= 128 and part:byte(cut + 1) < 192 do cut = cut - 1 end
            end
            part = text:sub(1, cut)
        end
        part = first and part or ("  " .. part)
        if kind then ply:PrintMessage(kind, part) else ply:ChatPrint(part) end
        text = string.TrimLeft(text:sub(#part + 1))
        first = false
    end
end

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
    include("dispatcher/orders.lua")
    include("dispatcher/depot.lua")
    include("dispatcher/graph.lua")
    include("dispatcher/routes.lua")
    include("dispatcher/persist.lua")
    include("dispatcher/spawn.lua")
    include("dispatcher/debug.lua")

    MsgC(Color(120, 200, 255), "[Dispatcher] loaded, map config: ",
        file.Exists(mapFile, "LUA") and mapFile or "none", "\n")
end

-- Re-include every module without a map change (GMod's auto-refresh does not
-- always pick up changed included files). Timetables and markup are kept.
concommand.Add("dispatcher_reload", function(ply)
    if IsValid(ply) and not (game.SinglePlayer() or ply:IsSuperAdmin()) then return end
    load()
    if IsValid(ply) then ply:ChatPrint("[Dispatcher] Модули перезагружены.") end
end)

-- Metrostroi loads its own files from autorun too; wait until everything is in.
if Dispatcher.Loaded then load() else
    hook.Add("Initialize", "Dispatcher_Load", function() Dispatcher.Loaded = true; load() end)
end
