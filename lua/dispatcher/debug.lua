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
    if pl.siding then return Format("%s [siding of %d/%d]", pl.name, pl.station.id, pl.from) end
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
        lines[#lines + 1] = Format("path #%d  x %.1f  dir %s  (tracks under cab: %d)", st.path.id, st.x,
            st.dirPlus and "+x" or "-x", st.trackCandidates or 1)
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

--------------------------------------------------------------------------------
-- Schedule
--   dispatcher_trip [N]       start N trips (default 2: there and back) from your platform
--   dispatcher_schedule       your timetable: plan vs fact
--   dispatcher_trip_cancel    drop your timetable
--   dispatcher_runs           run times between stations: estimate vs learned
--   dispatcher_runs_reset     forget learned run times
--------------------------------------------------------------------------------
local S = Dispatcher.Schedule
local T = Line.FormatTime

local function devStr(d)
    if not d then return "" end
    return Format("%+d s", math.Round(d))
end

local function printTimetable(ply, a)
    for ti, trip in ipairs(a.trips) do
        out(ply, Format("== Trip %d%s%s", trip.id, ti == a.ti and "  <- current" or "", trip.done and "  (done)" or ""))
        for j, s in ipairs(trip.stops) do
            local flags = (s.skip and " SKIP" or "") .. (s.missed and " MISSED" or "") .. (s.shortDwell and " SHORT-DWELL" or "")
                .. (s.hold and Format(" HOLD+%ds", s.hold) or "") .. (s.restricted and Format(" LIMIT %d", s.restricted) or "")
            out(ply, Format("  %s %-22s arr %s %-7s dep %s %-7s run %3ds%s%s",
                (ti == a.ti and j == trip.cur) and ">" or " ",
                s.platform.title,
                s.arr and T(s.arr) or "--:--:--", s.factArr and s.arr and devStr(s.factArr - s.arr) or "",
                s.dep and T(s.dep) or "--:--:--", s.factDep and s.dep and devStr(s.factDep - s.dep) or "",
                s.run, flags,
                s.stopError and Format("  stop %+.1f m", s.stopError) or ""))
        end
    end
end

concommand.Add("dispatcher_trip", function(ply, _, args)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    local st = Line.GetState(c)
    if not st or not st.at or not st.stopped then
        ply:ChatPrint("[Dispatcher] Встань на платформе станции и остановись.") return
    end
    local from, prep = st.at, 60
    if not Line.NextPlatform(from) then
        -- at the terminal arrival side: first a turnover to the departure platform
        from, prep = Line.OppositePlatform(from), GetConVar("dispatcher_turnover"):GetInt()
    end
    local count = math.Clamp(tonumber(args[1]) or 2, 1, 20)
    local dep = math.ceil((Line.Now() + prep) / 30) * 30
    local trips = S.BuildRoute(from, dep, count)
    if #trips == 0 then ply:ChatPrint("[Dispatcher] Не удалось построить рейс отсюда.") return end
    local a = S.Assign(c, trips)
    local first = trips[1]
    Dispatcher.Comms.Say(c.id, Format("Маршрут принят: %d рейс(а). Отправление со ст. %s в %s, до ст. %s в %s. График — в консоли.",
        #trips, first.stops[1].platform.title, T(first.stops[1].dep),
        first.stops[#first.stops].platform.station.name, T(first.stops[#first.stops].arr)))
    printTimetable(ply, a)
end)

concommand.Add("dispatcher_schedule", function(ply)
    if not IsValid(ply) then return end
    local a = S.GetAssignment(Line.GetPlayerConsist(ply))
    if not a then out(ply, "no timetable, use dispatcher_trip") return end
    out(ply, "Now " .. T(Line.Now()))
    local order = Dispatcher.Orders and Dispatcher.Orders.Active[a.cid]
    if order then out(ply, "Active order: " .. (order.text or order.kind) .. (order.acked and "  [ack]" or "  [NOT ACKED]")) end
    printTimetable(ply, a)
end)

concommand.Add("dispatcher_trip_cancel", function(ply)
    if not IsValid(ply) then return end
    S.Cancel(Line.GetPlayerConsist(ply))
    ply:ChatPrint("[Dispatcher] График снят.")
end)

concommand.Add("dispatcher_runs", function(ply)
    if not allowed(ply) then return end
    for _, st in ipairs(Line.GetStations()) do
        for idx, pl in SortedPairs(st.platforms) do
            local nxt = Line.NextPlatform(pl)
            if nxt then
                local t, src, norm = S.RunTime(pl, nxt)
                local d = Line.Distance(pl, nxt)
                out(ply, Format("%-22s -> %-22s %4.0f m  %3ds (%s, estimate %ds)%s",
                    pl.station.name, nxt.station.name, d or -1, t, src, norm,
                    d and Format("  avg %.0f km/h", d / t * 3.6) or ""))
            end
        end
    end
end)

concommand.Add("dispatcher_runs_reset", function(ply)
    if not allowed(ply) then return end
    S.ForgetRuns()
    out(ply, "learned run times cleared")
end)

--------------------------------------------------------------------------------
-- Stop mark calibration
--   dispatcher_stopmark [all]   stand with the cab at the real stop sign
--   dispatcher_stopmark_reset
--------------------------------------------------------------------------------
concommand.Add("dispatcher_stopmark", function(ply, _, args)
    if not IsValid(ply) then return end
    if not allowed(ply) then ply:ChatPrint("[Dispatcher] Калибровать знаки может только суперадмин.") return end
    local all = args[1] == "all" or args[1] == "все"
    local offset, pl = Line.CalibrateStopMark(Line.GetPlayerConsist(ply), all)
    if not offset then ply:ChatPrint("[Dispatcher] Не удалось: " .. pl .. ".") return end
    ply:ChatPrint(Format("[Dispatcher] Знак остановки %s: %+.1f м от конца платформы. %s",
        all and "для всех платформ" or ("ст. " .. pl.station.name .. ", путь " .. pl.index), offset,
        all and "Платформы с собственной калибровкой не тронуты." or "Действует сразу."))
end)

concommand.Add("dispatcher_stopmark_reset", function(ply)
    if IsValid(ply) and not allowed(ply) then return end
    Line.ResetStopMarks()
    if IsValid(ply) then ply:ChatPrint("[Dispatcher] Калибровка знаков сброшена.") else print("stop marks reset") end
end)

--------------------------------------------------------------------------------
-- Sidings (turnback dead ends)
--   dispatcher_siding_add [name]   mark: stand in the dead end at the stop mark
--   dispatcher_siding_del <name>
--   dispatcher_sidings
--------------------------------------------------------------------------------
concommand.Add("dispatcher_siding_add", function(ply, _, args)
    if not IsValid(ply) then return end
    if not allowed(ply) then ply:ChatPrint("[Dispatcher] Размечать тупики может только суперадмин.") return end
    local def, err = Line.AddSiding(Line.GetPlayerConsist(ply), table.concat(args, " "))
    if not def then ply:ChatPrint("[Dispatcher] Не удалось: " .. err .. ".") return end
    local st = Line.GetStation(def.station)
    ply:ChatPrint(Format("[Dispatcher] Тупик «%s» сохранён: после ст. %s (путь %d), выезд на путь %d. Действует для новых нарядов.",
        def.name, st and st.name or def.station, def.from, def.from == 1 and 2 or 1))
end)

concommand.Add("dispatcher_siding_del", function(ply, _, args)
    if IsValid(ply) and not allowed(ply) then return end
    local name = table.concat(args, " ")
    local ok = Line.RemoveSiding(name)
    local msg = ok and ("[Dispatcher] Тупик «" .. name .. "» удалён.") or ("[Dispatcher] Нет тупика «" .. name .. "» (список: !тупики).")
    if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
end)

concommand.Add("dispatcher_sidings", function(ply)
    local list = Line.GetSidings()
    local lines = {}
    if #list == 0 then lines[1] = "[Dispatcher] Тупиков нет. Разметить: заехать в тупик, встать у знака/упора, !тупик [название]" end
    for _, sd in ipairs(list) do
        lines[#lines + 1] = Format("[Dispatcher] %s — после %s (путь %d) -> выезд на путь %d",
            sd.name, sd.station.name, sd.from, sd.opposite and sd.opposite.index or 0)
    end
    for _, l in ipairs(lines) do
        if IsValid(ply) then ply:ChatPrint(l) else print(l) end
    end
end)
