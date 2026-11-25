--------------------------------------------------------------------------------
-- Dispatcher.Persist — timetables and orders survive a save / load with the
-- Metrostroi Dedicated Save addon (hooks MetrostroiSave_Save / _Load).
--
-- On load the whole plan is moved by the time the server was off: saved at
-- 13:00 with the next station due at 13:04, loaded at 18:00 -> due at 18:04.
--------------------------------------------------------------------------------
local Line, S = Dispatcher.Line, Dispatcher.Schedule
local P = Dispatcher.Persist or {}
Dispatcher.Persist = P

-- Stop fields saved as they are; platforms are saved by key
local STOP_FIELDS = { "run", "arr", "dep", "skip", "hold", "dwell", "restricted", "runOrig", "factArr", "factDep",
    "stopError", "missed", "shortDwell", "reverse", "depotEnd", "warnedLate" }
local TIME_FIELDS = { "arr", "dep", "factArr", "factDep" }

local function saveTrip(trip)
    local t = { id = trip.id, cur = trip.cur, done = trip.done, ordersGiven = trip.ordersGiven,
                lastOrderDone = trip.lastOrderDone, stops = {} }
    for j, s in ipairs(trip.stops) do
        local o = { pl = s.platform.key, planned = s.plannedPlatform and s.plannedPlatform.key }
        for _, f in ipairs(STOP_FIELDS) do o[f] = s[f] end
        t.stops[j] = o
    end
    return t
end

local function loadTrip(t, shift)
    local trip = { id = t.id, cur = t.cur, done = t.done, ordersGiven = t.ordersGiven,
                   lastOrderDone = t.lastOrderDone and t.lastOrderDone + shift, stops = {} }
    for j, o in ipairs(t.stops or {}) do
        local pl = Line.PlatformByKey(o.pl)
        if not pl then return nil, o.pl end   -- markup changed since the save
        local s = { platform = pl, plannedPlatform = Line.PlatformByKey(o.planned) }
        for _, f in ipairs(STOP_FIELDS) do s[f] = o[f] end
        for _, f in ipairs(TIME_FIELDS) do if s[f] then s[f] = s[f] + shift end end
        trip.stops[j] = s
    end
    return trip
end

local ORDER_FIELDS = { "id", "kind", "issued", "acked", "state", "text", "reason", "repeated",
    "seconds", "limit", "over", "maxSpeed" }

-- Move every time of an assignment (and its active order) by `secs`
function P.ShiftAll(a, secs)
    if secs == 0 then return end
    for _, trip in ipairs(a.trips) do
        if trip.lastOrderDone then trip.lastOrderDone = trip.lastOrderDone + secs end
        for _, s in ipairs(trip.stops) do
            for _, f in ipairs(TIME_FIELDS) do if s[f] then s[f] = s[f] + secs end end
        end
    end
    if a.started then a.started = a.started + secs end
    local order = Dispatcher.Orders and Dispatcher.Orders.Active[a.cid]
    if order then
        if order.issued then order.issued = order.issued + secs end
        if order.acked then order.acked = order.acked + secs end
    end
end

hook.Add("MetrostroiSave_Save", "Dispatcher", function(ext, cars, index)
    local out = { savedAt = Line.Now(), assignments = {} }
    for cid, a in pairs(S.Assignments) do
        local c = Line.GetConsist(cid)
        if not c or a.finished then continue end
        local wagons = {}
        for _, w in ipairs(c.wagons) do if index[w] then wagons[#wagons + 1] = index[w] end end
        if #wagons == 0 then continue end

        local sa = { wagons = wagons, ti = a.ti, started = a.started, trips = {} }
        local tripIdx = {}
        for i, trip in ipairs(a.trips) do sa.trips[i] = saveTrip(trip); tripIdx[trip] = i end

        local order = Dispatcher.Orders and Dispatcher.Orders.Active[cid]
        if order and tripIdx[order.trip] then
            local so = { trip = tripIdx[order.trip], opposite = order.opposite and order.opposite.key }
            for _, f in ipairs(ORDER_FIELDS) do so[f] = order[f] end
            for j, s in ipairs(order.trip.stops) do
                if s == order.stop then so.stop = j end
                if s == order.from then so.from = j end
            end
            sa.order = so
        end
        out.assignments[#out.assignments + 1] = sa
    end
    if #out.assignments > 0 then ext.dispatcher = out end
end)

hook.Add("MetrostroiSave_Load", "Dispatcher", function(ext, cars)
    local d = ext.dispatcher
    if not d then return end
    local shift = math.max(0, Line.Now() - (d.savedAt or Line.Now()))

    for _, sa in ipairs(d.assignments or {}) do
        -- the consist that now holds the saved wagons
        local ent = cars[sa.wagons[1]]
        local consist
        if IsValid(ent) then
            for _, c in ipairs(Line.GetConsists()) do
                for _, w in ipairs(c.wagons) do if w == ent then consist = c end end
            end
        end
        if not consist then continue end

        local a = { cid = consist.id, ti = sa.ti, started = sa.started and sa.started + shift, trips = {} }
        local ok = true
        for i, t in ipairs(sa.trips) do
            local trip, missing = loadTrip(t, shift)
            if not trip then
                MsgC(Color(255, 120, 80), "[Dispatcher] Can't restore a timetable: no ", tostring(missing), " on this map any more\n")
                ok = false
                break
            end
            a.trips[i] = trip
        end
        if not ok or not a.trips[a.ti] then continue end
        -- the timetable waits for the driver: the time until he takes the seat is added then
        a.restored = { shift = shift, loadedAt = Line.Now() }
        S.Assignments[consist.id] = a

        local so = sa.order
        local O = Dispatcher.Orders
        if so and O and a.trips[so.trip] then
            local trip = a.trips[so.trip]
            local order = { cid = consist.id, trip = trip, stop = so.stop and trip.stops[so.stop],
                            from = so.from and trip.stops[so.from], opposite = Line.PlatformByKey(so.opposite) }
            for _, f in ipairs(ORDER_FIELDS) do order[f] = so[f] end
            order.platform = order.stop and order.stop.platform
            if order.issued then order.issued = order.issued + shift end
            if order.acked then order.acked = order.acked + shift end
            O.Active[consist.id] = order
            O.Log[consist.id] = O.Log[consist.id] or {}
            table.insert(O.Log[consist.id], order)
            O.Counter = math.max(O.Counter or 0, order.id or 0)
        end
        MsgC(Color(120, 200, 255), Format("[Dispatcher] Timetable restored for consist %d, moved by %d s\n", consist.id, shift))
    end
end)

-- Tell the driver when he takes the seat of a train with a restored timetable
local function dur(s)
    s = math.Round(s)
    if s < 60 then return s .. " с" end
    local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
    if h > 0 then return Format("%d ч %02d мин", h, m) end
    return Format("%d мин %02d с", m, s % 60)
end

hook.Add("PlayerEnteredVehicle", "Dispatcher_Restored", function(ply)
    timer.Simple(1.5, function()
        if not IsValid(ply) then return end
        local c = Line.GetPlayerConsist(ply)
        local a = c and S.GetAssignment(c)
        if not a or not a.restored or a.restored.told then return end
        a.restored.told = true
        local wait = math.max(0, Line.Now() - a.restored.loadedAt)
        P.ShiftAll(a, wait)
        a.restored.shift = a.restored.shift + wait
        local trip = a.trips[a.ti]
        local cur = trip.stops[trip.cur or 1]
        local nxt = trip.stops[(trip.cur or 1) + 1]
        local msg = "Наряд восстановлен"
        if a.restored.shift >= 60 then msg = msg .. ", график сдвинут на " .. dur(a.restored.shift) .. " (перерыв)" end
        if cur and cur.dep and not cur.factDep then
            msg = msg .. Format(". Отправление со ст. %s в %s.", cur.platform.title, Line.FormatTime(cur.dep))
        elseif nxt then
            msg = msg .. Format(". Следующая: %s по графику в %s.", nxt.platform.title, Line.FormatTime(nxt.arr))
        else
            msg = msg .. "."
        end
        local order = Dispatcher.Orders and Dispatcher.Orders.Active[c.id]
        if order then msg = msg .. " Действует приказ №" .. tostring(order.id) .. " (!график)." end
        Dispatcher.Comms.Say(c.id, msg)
    end)
end)
