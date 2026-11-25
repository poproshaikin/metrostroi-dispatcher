--------------------------------------------------------------------------------
-- Dispatcher.Comms — what the dispatcher says to the driver.
-- For now: chat lines with a radio beep, driven by schedule events.
--------------------------------------------------------------------------------
local Line, S = Dispatcher.Line, Dispatcher.Schedule
local Comms = Dispatcher.Comms or {}
Dispatcher.Comms = Comms

local PREFIX = "[ДЦХ] "
local BEEP = "buttons/blip1.wav"

-- Players to address for a consist: its driver, or everyone in it, or everybody.
local function recipients(cid)
    local c = Line.GetConsist(cid)
    local st = c and Line.GetState(c)
    if st and IsValid(st.driver) then return { st.driver } end
    return player.GetHumans()
end

function Comms.Say(cid, text)
    for _, ply in ipairs(recipients(cid)) do
        Dispatcher.Chat(ply, PREFIX .. text)
        ply:SendLua(Format("surface.PlaySound(%q)", BEEP))
    end
end

local function dur(s)
    s = math.Round(math.abs(s))
    if s < 60 then return s .. " с" end
    return Format("%d:%02d", math.floor(s / 60), s % 60)
end

local function stName(stop) return stop.platform.title end

--------------------------------------------------------------------------------
hook.Add("Dispatcher_StopArrive", "Dispatcher_Comms", function(cid, trip, s, dev)
    local tol = S.Tolerance()
    local msg
    if s.skip then
        msg = Format("%s — остановка не предусмотрена, следуйте без стоянки.", stName(s))
    elseif dev > tol then
        msg = Format("%s, прибытие с опозданием %s.", stName(s), dur(dev))
    elseif dev < -tol then
        msg = Format("%s, прибыли раньше на %s. Раньше графика не отправляться.", stName(s), dur(dev))
    else
        msg = Format("%s, по графику.", stName(s))
    end
    if s.stopError then
        if math.abs(s.stopError) > 3 then
            msg = msg .. Format(" Остановка: %s %.1f м.", s.stopError > 0 and "недоезд" or "проезд знака", math.abs(s.stopError))
        end
    end
    if s.dep then msg = msg .. " Отправление в " .. Line.FormatTime(s.dep) .. "." end
    -- next is the turnback dead end: say which track (there may be two)
    local nxt = trip.stops[(trip.cur or 1) + 1]
    if nxt and nxt.platform.siding then msg = msg .. " Оборот через " .. nxt.platform.title .. "." end
    -- next is the depot: which track to go to
    if nxt and nxt.platform.depot then
        msg = msg .. Format(" После высадки следуйте в депо: постановка на путь %s (канава %s) в %s.",
            nxt.platform.name, nxt.platform.name, Line.FormatTime(nxt.arr))
    end
    -- last stop and the next trip leaves from here backwards: turn on the platform
    local a = S.Assignments[cid]
    local nt = a and a.trips[a.ti + 1]
    if not nxt and nt and nt.stops[1].reverse and nt.stops[1].platform == s.platform then
        local after = nt.stops[2] and nt.stops[2].platform
        msg = msg .. Format(" Оборот с платформы: высадка, смена кабины, отправление обратно через съезд%s в %s.",
            after and (" на ст. " .. after.title) or "", Line.FormatTime(nt.stops[1].dep))
    end
    if s.plannedPlatform then msg = msg .. Format(" (назначен был %s — принято.)", s.plannedPlatform.title) end
    Comms.Say(cid, msg)
end)

hook.Add("Dispatcher_StopDepart", "Dispatcher_Comms", function(cid, trip, s, dev)
    local tol = S.Tolerance()
    if dev < -tol then
        Comms.Say(cid, Format("Отправились раньше графика на %s!", dur(dev)))
    elseif s.shortDwell then
        Comms.Say(cid, Format("Стоянка на ст. %s слишком короткая.", stName(s)))
    end
end)

hook.Add("Dispatcher_StopMissed", "Dispatcher_Comms", function(cid, trip, s)
    Comms.Say(cid, Format("Проследовали ст. %s без остановки! Нарушение.", stName(s)))
end)

hook.Add("Dispatcher_WrongDepotTrack", "Dispatcher_Comms", function(cid, trip, planned, actual)
    Comms.Say(cid, Format("Вы на пути %s, а постановка назначена на путь %s! Переставьте состав.", actual.name, planned.platform.name))
end)

hook.Add("Dispatcher_TripDone", "Dispatcher_Comms", function(cid, trip)
    local a = S.Assignments[cid]
    local nxt = a and a.trips[a.ti + 1]
    if nxt and nxt.stops[1].reverse then
        -- turned on the platform: already told on arrival, now just going
        Comms.Say(cid, Format("Рейс %d окончен, следуйте по графику.", trip.id))
    elseif nxt then
        local first = nxt.stops[1]
        local late = Line.Now() - first.dep
        if late > S.Tolerance() then
            -- the planned departure has already passed: say so instead of a time in the past
            Comms.Say(cid, Format("Рейс %d окончен. Отправление со ст. %s (путь %d) по графику было в %s — "
                .. "опаздываете на %s, отправляйтесь, как только будете готовы.",
                trip.id, stName(first), first.platform.index, Line.FormatTime(first.dep), dur(late)))
        else
            Comms.Say(cid, Format("Рейс %d окончен. Оборот, отправление со ст. %s (путь %d) в %s.",
                trip.id, stName(first), first.platform.index, Line.FormatTime(first.dep)))
        end
    else
        Comms.Say(cid, Format("Рейс %d окончен.", trip.id))
    end
end)

hook.Add("Dispatcher_ShiftDone", "Dispatcher_Comms", function(cid, a)
    local total, onTime, missed = 0, 0, 0
    for _, trip in ipairs(a.trips) do
        for j = 2, #trip.stops do
            local s = trip.stops[j]
            if s.missed then missed = missed + 1 end
            if s.factArr and not s.skip then
                total = total + 1
                if math.abs(s.factArr - s.arr) <= S.Tolerance() then onTime = onTime + 1 end
            end
        end
    end
    Comms.Say(cid, Format("Смена окончена. Рейсов: %d, прибытий по графику: %d из %d, пропущено остановок: %d.",
        #a.trips, onTime, total, missed))
end)

-- Help
local HELP = {
    "Диспетчер ДЦХ — команды в чат:",
    "  !рейс [N] — взять наряд: N рейсов от текущей платформы (по умолчанию 2, туда и обратно)",
    "  !график — план и факт по станциям (в консоли ~)",
    "  !где — что диспетчер видит про твой поезд (в консоли ~)",
    "  !понял — подтвердить приказ",
    "  !готов — состав принят/готов раньше: отправление через минуту, график сдвигается (из депо, с первой станции, после оборота)",
    "Запросить приказ (станция — необязательно, по умолчанию ближайшая подходящая):",
    "  !приказ — случайный приказ прямо сейчас",
    "  !оборот [станция] — оборот (сократить рейс)",
    "  !проследовать [станция] — проследовать станцию без остановки",
    "  !задержка [сек] [станция] — задержать отправление (по умолчанию 120 с)",
    "  !ограничение [км/ч] [станция] — ограничение скорости на перегоне до станции (по умолчанию 40)",
    "  !отмена — снять наряд",
    "  !тупики — размеченные оборотные тупики; !тупик [название] — разметить (стоя в тупике у знака, админ)",
    "  !съезд [название] — оборот прямо с этой платформы назад через съезд (стоя у платформы, админ)",
    "  !знак — откалибровать знак остановки этой платформы (встать кабиной точно у знака, админ); !знак все — для всех",
    "Депо:",
    "  !канава <путь> начало / !канава <путь> конец — разметить путь депо (торец кабины у маркера, админ)",
    "  !канавы — пути депо, куда выезд и откуда заезд; !канава_удалить <путь>",
    "  !выезд <станция> [путь], !заезд <станция> [путь] — задать вручную (обычно запоминается само)",
    "  !рейс [N], стоя целиком на канаве, — наряд из депо на N кругов до дальней конечной и обратно (по умолчанию 1), постановка обратно в депо",
    "  !метки — показать/скрыть метки в мире (канавы, тупики, знаки остановки)",
    "  !экспорт — сохранить всю разметку карты в файл (для другого сервера или аддона, админ)",
    "  !помощь — эта справка",
    "Наряд берётся, стоя у платформы (или на канаве) на месте машиниста. Время — по станционным часам.",
}
local HELP_ADMIN = {
    "Настройки (консоль сервера): dispatcher_dwell (стоянка, 30), dispatcher_turnover (оборот без тупика, 240),",
    "  dispatcher_unload (высадка перед тупиком, 60), dispatcher_cabchange (смена кабины в тупике, 120),",
    "  dispatcher_tolerance (допуск, 15), dispatcher_orders_chance (случайные приказы, 0.08/мин), dispatcher_orders_per_trip (2),",
    "  dispatcher_learn (учиться на поездках, 1). Отладка: dispatcher_stations, dispatcher_runs, dispatcher_debug 1",
}

concommand.Add("dispatcher_help", function(ply)
    local lines = table.Copy(HELP)
    if not IsValid(ply) or game.SinglePlayer() or ply:IsSuperAdmin() then
        for _, l in ipairs(HELP_ADMIN) do lines[#lines + 1] = l end
    end
    for _, l in ipairs(lines) do
        if IsValid(ply) then Dispatcher.Chat(ply, l) else print(l) end
    end
end)

-- Chat commands -> console commands
local CHAT = {
    ["!рейс"] = "dispatcher_trip", ["!trip"] = "dispatcher_trip",
    ["!график"] = "dispatcher_schedule", ["!schedule"] = "dispatcher_schedule",
    ["!отмена"] = "dispatcher_trip_cancel", ["!cancel"] = "dispatcher_trip_cancel",
    ["!где"] = "dispatcher_where", ["!where"] = "dispatcher_where",
    ["!понял"] = "dispatcher_ack", ["!ack"] = "dispatcher_ack",
    ["!готов"] = "dispatcher_ready", ["!ready"] = "dispatcher_ready",
    ["!часы"] = "dispatcher_clock", ["!clock"] = "dispatcher_clock",
    ["!оборот"] = "dispatcher_order_turnback", ["!turnback"] = "dispatcher_order_turnback",
    ["!помощь"] = "dispatcher_help", ["!help"] = "dispatcher_help", ["!дцх"] = "dispatcher_help",
    ["!тупик"] = "dispatcher_siding_add", ["!siding"] = "dispatcher_siding_add",
    ["!тупики"] = "dispatcher_sidings", ["!sidings"] = "dispatcher_sidings",
    ["!тупик_удалить"] = "dispatcher_siding_del",
    ["!съезд"] = "dispatcher_platform_turn", ["!сьезд"] = "dispatcher_platform_turn",
    ["!оборот_платформа"] = "dispatcher_platform_turn",
    ["!знак"] = "dispatcher_stopmark", ["!stopmark"] = "dispatcher_stopmark",
    ["!знак_сброс"] = "dispatcher_stopmark_reset",
    ["!проследовать"] = "dispatcher_order_skip", ["!skip"] = "dispatcher_order_skip",
    ["!задержка"] = "dispatcher_order_hold", ["!hold"] = "dispatcher_order_hold",
    ["!ограничение"] = "dispatcher_order_restrict", ["!limit"] = "dispatcher_order_restrict",
    ["!приказ"] = "dispatcher_order_random", ["!order"] = "dispatcher_order_random",
    ["!канава"] = "dispatcher_depot_mark", ["!канавы"] = "dispatcher_depot_list", ["!депо"] = "dispatcher_depot_list",
    ["!канава_удалить"] = "dispatcher_depot_del",
    ["!выезд"] = "dispatcher_depot_exit", ["!заезд"] = "dispatcher_depot_entry",
    ["!экспорт"] = "dispatcher_export", ["!export"] = "dispatcher_export",
}
local SILENT = { dispatcher_trip = true, dispatcher_trip_cancel = true, dispatcher_ack = true,
    dispatcher_order_turnback = true, dispatcher_help = true,
    dispatcher_siding_add = true, dispatcher_sidings = true, dispatcher_siding_del = true,
    dispatcher_platform_turn = true,
    dispatcher_stopmark = true, dispatcher_stopmark_reset = true,
    dispatcher_ready = true, dispatcher_clock = true, dispatcher_order_skip = true, dispatcher_order_hold = true, dispatcher_order_restrict = true,
    dispatcher_order_random = true,
    dispatcher_depot_mark = true, dispatcher_depot_list = true, dispatcher_depot_del = true,
    dispatcher_depot_exit = true, dispatcher_depot_entry = true, dispatcher_export = true }
hook.Add("PlayerSay", "Dispatcher_ChatCommands", function(ply, text)
    local args = string.Explode(" ", string.Trim(text))
    local first = Line.Lower(args[1] or "")
    if first == "!метки" or first == "!marks" then
        ply:ConCommand("dispatcher_marks_toggle")   -- client-side toggle
        return ""
    end
    local cmd = CHAT[first]
    if not cmd then return end
    table.remove(args, 1)
    concommand.Run(ply, cmd, args, table.concat(args, " "))
    if not SILENT[cmd] then
        Dispatcher.Chat(ply, "[Dispatcher] Ответ в консоли (~).")
    end
    return ""
end)

-- Hint when someone takes the driver's seat without a timetable
hook.Add("PlayerEnteredVehicle", "Dispatcher_Hint", function(ply)
    timer.Simple(1, function()
        if not IsValid(ply) then return end
        local c = Line.GetPlayerConsist(ply)
        local st = c and Line.GetState(c)
        if not st or st.driver ~= ply or S.GetAssignment(c) then return end
        local ds = Dispatcher.Depot and Dispatcher.Depot.State(c)
        if ds and ds.full then
            Dispatcher.Chat(ply, PREFIX .. Format("Машинист, вы в депо на пути %s. Для наряда напишите !рейс. Все команды: !помощь", ds.track.name))
        elseif st.at then
            Dispatcher.Chat(ply, PREFIX .. Format("Машинист, вы на ст. %s. Для наряда напишите !рейс (или !рейс 4 — четыре рейса). Все команды: !помощь", st.at.station.name))
        else
            Dispatcher.Chat(ply, PREFIX .. "Для наряда встаньте на платформу и напишите !рейс.")
        end
    end)
end)

-- Running late in the tunnel: one reminder per run
timer.Create("Dispatcher_CommsLate", 5, 0, function()
    for cid, a in pairs(S.Assignments) do
        if a.finished or S.IsPaused(a) then continue end
        local c = Line.GetConsist(cid)
        local status = c and S.GetStatus(c)
        if not status or not status.eta then continue end
        local s = status.stop
        if not s.warnedLate and status.deviation > S.Tolerance() * 2 then
            s.warnedLate = true
            Comms.Say(cid, Format("Опаздываете на %s, ст. %s по графику в %s.",
                dur(status.deviation), stName(s), Line.FormatTime(s.arr)))
        end
    end
end)
