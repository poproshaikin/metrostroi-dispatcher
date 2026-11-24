--------------------------------------------------------------------------------
-- Debug tools for Dispatcher.Line
--   dispatcher_stations     list stations/platforms as Line sees them
--   dispatcher_where        print the state of your consist
--   dispatcher_debug 1      live state on screen + arrive/depart in chat
--------------------------------------------------------------------------------
local Line = Dispatcher.Line

local function out(ply, text)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, text) else print(text) end
end

local function allowed(ply)
    return not IsValid(ply) or game.SinglePlayer() or ply:IsSuperAdmin()
end

local function plName(pl)
    if not pl then return "-" end
    return Format("%s [%d/%d]", pl.station.name, pl.station.id, pl.index)
end

concommand.Add("dispatcher_stations", function(ply)
    if not allowed(ply) then return end
    local list = Line.GetStations()
    if #list == 0 then out(ply, "[Dispatcher] no stations (map not supported or not loaded yet)") return end
    for _, st in ipairs(list) do
        out(ply, Format("%2d. %3d  %s", st.order, st.id, st.name))
        for idx, pl in SortedPairs(st.platforms) do
            out(ply, Format("      platform %d: path #%s  x %.1f -> %.1f  (%.0f m)  %s%s  next: %s",
                idx, pl.path and pl.path.id or "?", pl.xStart, pl.xEnd, pl.length,
                pl.dir and "+x" or "-x", pl.terminal and "  TERMINAL" or "",
                plName(Line.NextPlatform(pl))))
        end
    end
    for idx = 1, 2 do
        out(ply, Format("platform %d goes %s the list", idx, Line.OrderDir(idx) > 0 and "up" or "down"))
    end
end)

local function describe(st)
    if not st then return "not in a train" end
    local lines = {
        Format("%s ×%d  driver: %s", st.head:GetClass(), st.wagons, IsValid(st.driver) and st.driver:Nick() or "-"),
        Format("speed %.1f km/h%s  doors L:%s R:%s", st.speed, st.stopped and " (stopped)" or "",
            st.doors.left and "open" or "closed", st.doors.right and "open" or "closed"),
    }
    if not st.onTrack then
        lines[#lines + 1] = "OFF TRACK"
    else
        lines[#lines + 1] = Format("path #%d  x %.1f  dir %s", st.path.id, st.x, st.dirPlus and "+x" or "-x")
        lines[#lines + 1] = "at: " .. plName(st.at)
        lines[#lines + 1] = Format("stop: %s  %s", plName(st.stop),
            st.distToStop and Format("%.1f m", st.distToStop) or "(distance unknown)")
        lines[#lines + 1] = "last stop: " .. plName(st.last)
    end
    return table.concat(lines, "\n")
end

concommand.Add("dispatcher_where", function(ply)
    if not IsValid(ply) then return end
    out(ply, describe(Line.GetPlayerState(ply)))
end)

local cvDebug = CreateConVar("dispatcher_debug", "0", FCVAR_ARCHIVE, "Show Dispatcher.Line state on screen")

timer.Create("Dispatcher_Debug", 0.5, 0, function()
    if not cvDebug:GetBool() then return end
    for _, ply in ipairs(player.GetHumans()) do
        local st = Line.GetPlayerState(ply)
        if st then ply:PrintMessage(HUD_PRINTCENTER, describe(st)) end
    end
end)

hook.Add("Dispatcher_Arrive", "Dispatcher_Debug", function(c, st, pl, err)
    if not cvDebug:GetBool() then return end
    PrintMessage(HUD_PRINTTALK, Format("[Line] ARRIVE %s, stop error %s", plName(pl),
        err and Format("%+.1f m", err) or "?"))
end)

hook.Add("Dispatcher_Depart", "Dispatcher_Debug", function(c, st, pl)
    if not cvDebug:GetBool() then return end
    PrintMessage(HUD_PRINTTALK, "[Line] DEPART " .. plName(pl))
end)
