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
        ply:ChatPrint(PREFIX .. text)
        ply:SendLua(Format("surface.PlaySound(%q)", BEEP))
    end
end

local function dur(s)
    s = math.Round(math.abs(s))
    if s < 60 then return s .. " с" end
    return Format("%d:%02d", math.floor(s / 60), s % 60)
end

local function stName(stop) return stop.platform.station.name end

--------------------------------------------------------------------------------
hook.Add("Dispatcher_StopArrive", "Dispatcher_Comms", function(cid, trip, s, dev)
    local tol = S.Tolerance()
    local msg
    if s.skip then
        msg = Format("%s — остановка не предусмотрена, следуйте без стоянки.", stName(s))
    elseif dev > tol then
        msg = Format("%s, прибытие с опозданием %s.", stName(s), dur(dev))
    elseif dev < -tol then
        msg = Format("%s, прибыли раньше на %s, стоянку не сокращать.", stName(s), dur(dev))
    else
        msg = Format("%s, по графику.", stName(s))
    end
    if s.stopError then
        if math.abs(s.stopError) > 3 then
            msg = msg .. Format(" Остановка: %s %.1f м.", s.stopError > 0 and "недоезд" or "проезд знака", math.abs(s.stopError))
        end
    end
    if s.dep then msg = msg .. " Отправление в " .. Line.FormatTime(s.dep) .. "." end
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

hook.Add("Dispatcher_TripDone", "Dispatcher_Comms", function(cid, trip)
    local a = S.Assignments[cid]
    local nxt = a and a.trips[a.ti + 1]
    if nxt then
        local first = nxt.stops[1]
        Comms.Say(cid, Format("Рейс %d окончен. Оборот, отправление со ст. %s (путь %d) в %s.",
            trip.id, stName(first), first.platform.index, Line.FormatTime(first.dep)))
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

-- Running late in the tunnel: one reminder per run
timer.Create("Dispatcher_CommsLate", 5, 0, function()
    for cid, a in pairs(S.Assignments) do
        if a.finished then continue end
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
