--------------------------------------------------------------------------------
-- Dispatcher.Orders — dispatcher orders that change the plan mid-route.
--
-- Order { id, kind, cid, platform, issued, acked, state, ... }
--   state: "issued" -> "done" | "violated" | "cancelled"
--
-- Kinds:
--   turnback  short turn: end the trip at an intermediate station with a
--             crossover, turn over to the opposite platform, continue the shift.
--
-- Random orders: dispatcher_orders_chance (per minute, per train with a timetable).
-- Manual:        dispatcher_order_turnback [station]   /  chat: !оборот [станция]
-- Acknowledge:   dispatcher_ack                        /  chat: !понял
--
-- Events: Dispatcher_OrderIssued (order), Dispatcher_OrderDone (order),
--         Dispatcher_OrderViolated (order)
--------------------------------------------------------------------------------
local Line, S = Dispatcher.Line, Dispatcher.Schedule
local O = Dispatcher.Orders or {}
Dispatcher.Orders = O

local cvChance = CreateConVar("dispatcher_orders_chance", "0.03", FCVAR_ARCHIVE,
    "Chance per minute that the dispatcher issues a random order to a train with a timetable (0 = off)")

local ACK_TIMEOUT   = 60    -- s, then the order is repeated once
local MIN_LEAD_DIST = 600   -- m, an order for the very next station needs at least this much warning

O.Active = O.Active or {}   -- [cid] = order (one active order per train)
O.Log = O.Log or {}         -- [cid] = { order, ... } for the shift report
local orderCounter = 0

local function say(cid, text) Dispatcher.Comms.Say(cid, text) end

local function trackName(pl) return pl.index == 1 and "I" or "II" end

-- Stations where a turnback is possible on this map
function O.IsTurnbackStation(station)
    local list = Dispatcher.MapConfig and Dispatcher.MapConfig.turnbacks
    if not list then return false end
    for _, id in ipairs(list) do if id == station.id then return true end end
    return false
end

-- Stops of the current trip still ahead of the train where a turnback can be ordered:
-- not the last stop, not behind the train, far enough to react.
function O.TurnbackCandidates(consist, anyStation)
    local trip, a = S.CurrentTrip(consist)
    if not trip or a.finished then return {} end
    local st = Line.GetState(consist)
    local list = {}
    for j = (trip.cur or 1) + 1, #trip.stops - 1 do
        local s = trip.stops[j]
        if not anyStation and not O.IsTurnbackStation(s.platform.station) then continue end
        if j == (trip.cur or 1) + 1 and trip.stops[trip.cur].factDep then
            -- already running towards it: needs enough distance to brake and plan
            if not (st and st.stop == s.platform and st.distToStop and st.distToStop > MIN_LEAD_DIST) then continue end
        end
        list[#list + 1] = s
    end
    return list
end

--------------------------------------------------------------------------------
-- Turnback
--------------------------------------------------------------------------------
function O.IssueTurnback(consist, stop, reason)
    local a = S.GetAssignment(consist)
    if not a or O.Active[consist.id] then return nil, "busy" end
    local pl = stop.platform
    local opposite = Line.OppositePlatform(pl)
    if not opposite then return nil, "no opposite platform" end

    if not S.TurnBack(a, pl) then return nil, "not on the current trip" end
    -- Last trip of the shift: still bring the train back to the terminal
    if not a.trips[a.ti + 1] then
        local back = S.BuildTrip(opposite, stop.arr + GetConVar("dispatcher_turnover"):GetInt())
        if back then a.trips[#a.trips + 1] = back end
    end
    local nextTrip = a.trips[a.ti + 1]
    local dep = nextTrip and nextTrip.stops[1].dep

    orderCounter = orderCounter + 1
    local order = {
        id = orderCounter, kind = "turnback", cid = consist.id,
        platform = pl, opposite = opposite, issued = Line.Now(), state = "issued",
        reason = reason,
    }
    O.Active[consist.id] = order
    O.Log[consist.id] = O.Log[consist.id] or {}
    table.insert(O.Log[consist.id], order)

    order.text = Format("Приказ №%d. %sОборот по ст. %s: высадка пассажиров, оборот по съезду, "
        .. "отправление со ст. %s по %s пути%s. Подтвердите: !понял",
        order.id, reason and (reason .. " ") or "", pl.station.name, opposite.station.name, trackName(opposite),
        dep and (" в " .. Line.FormatTime(dep)) or "")
    say(consist.id, order.text)
    hook.Run("Dispatcher_OrderIssued", order)
    return order
end

local REASONS = {
    "Сбой движения на линии.",
    "Неисправность на пути впереди.",
    "Выравнивание интервалов.",
    "Задымление на станции впереди.",
    "Пострадавший на путях впереди.",
}

-- Random order for one train, if a suitable station is ahead
local function tryRandomOrder(consist)
    local cands = O.TurnbackCandidates(consist)
    if #cands == 0 then return end
    return O.IssueTurnback(consist, cands[math.random(#cands)], REASONS[math.random(#REASONS)])
end

timer.Create("Dispatcher_RandomOrders", 15, 0, function()
    local chance = cvChance:GetFloat()
    if chance <= 0 then return end
    local p = 1 - (1 - math.min(chance, 1)) ^ (15 / 60)   -- per-minute chance -> per 15 s tick
    for cid, a in pairs(S.Assignments) do
        if a.finished or O.Active[cid] then continue end
        local trip = a.trips[a.ti]
        if trip.orderGiven or not trip.stops[trip.cur or 1].factDep then continue end  -- one per trip, only while running
        if math.random() < p then
            local c = Line.GetConsist(cid)
            if c and tryRandomOrder(c) then trip.orderGiven = true end
        end
    end
end)

--------------------------------------------------------------------------------
-- Acknowledge / follow-up
--------------------------------------------------------------------------------
function O.Ack(consist)
    local order = consist and O.Active[consist.id]
    if not order or order.acked then return false end
    order.acked = Line.Now()
    say(consist.id, Format("Приказ №%d подтверждён.", order.id))
    return true
end

timer.Create("Dispatcher_OrderAck", 5, 0, function()
    for cid, order in pairs(O.Active) do
        if order.acked or order.state ~= "issued" then continue end
        if not order.repeated and Line.Now() - order.issued > ACK_TIMEOUT then
            order.repeated = true
            say(cid, "Повторяю. " .. order.text)
        end
    end
end)

local function finish(order, state)
    order.state = state
    order.finished = Line.Now()
    O.Active[order.cid] = nil
end

-- Done when the train shows up at the opposite platform; violated when it
-- arrives anywhere beyond the turnback station in the old direction.
hook.Add("Dispatcher_Arrive", "Dispatcher_Orders", function(consist, st, platform)
    local order = O.Active[consist.id]
    if not order or order.kind ~= "turnback" then return end
    if platform == order.opposite then
        finish(order, "done")
        say(consist.id, Format("Оборот по ст. %s выполнен%s.", order.platform.station.name,
            order.acked and "" or " (приказ не был подтверждён)"))
        hook.Run("Dispatcher_OrderDone", order)
        return
    end
    local dir = Line.OrderDir(order.platform.index)
    if platform.index == order.platform.index
        and (platform.station.order - order.platform.station.order) * dir > 0 then
        finish(order, "violated")
        say(consist.id, Format("Нарушение приказа №%d: оборот по ст. %s не выполнен!", order.id, order.platform.station.name))
        hook.Run("Dispatcher_OrderViolated", order)
    end
end)

-- Timetable dropped -> orders go too
hook.Add("Dispatcher_ShiftDone", "Dispatcher_Orders", function(cid)
    local order = O.Active[cid]
    if order then finish(order, "cancelled") end
end)

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
-- Lowercase for Cyrillic too (string.lower only handles ASCII)
local function lower(s)
    s = string.lower(s)
    return (s:gsub("\208([\144-\175])", function(c)          -- А..Я
        local b = c:byte() + 32
        if b < 176 then return "\208" .. string.char(b) end   -- А..П -> а..п
        return "\209" .. string.char(b - 64)                  -- Р..Я -> р..я
    end):gsub("\208\129", "\209\145"))                        -- Ё -> ё
end

local function findStopByName(cands, query)
    if not query or query == "" then return cands[1] end
    local q = lower(query)
    for _, s in ipairs(cands) do
        local st = s.platform.station
        if tostring(st.id) == q or string.find(lower(st.name), q, 1, true) == 1 then return s end
    end
end

concommand.Add("dispatcher_order_turnback", function(ply, _, args)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    if not c or not S.GetAssignment(c) then ply:ChatPrint("[Dispatcher] Сначала возьми наряд: !рейс") return end
    if O.Active[c.id] then ply:ChatPrint("[Dispatcher] Уже есть невыполненный приказ.") return end
    local query = table.concat(args, " ")
    -- Prefer stations with a crossover; with an explicit name allow any station ahead
    local cands = O.TurnbackCandidates(c, query ~= "")
    local stop = findStopByName(cands, query)
    if not stop then
        local names = {}
        for _, s in ipairs(O.TurnbackCandidates(c)) do names[#names + 1] = s.platform.station.name end
        ply:ChatPrint("[Dispatcher] Нет подходящей станции впереди" ..
            (#names > 0 and (". Можно: " .. table.concat(names, ", ")) or "."))
        return
    end
    if not O.IsTurnbackStation(stop.platform.station) then
        ply:ChatPrint("[Dispatcher] Внимание: на ст. " .. stop.platform.station.name .. " съезда может не быть.")
    end
    O.IssueTurnback(c, stop, "По запросу.")
end)

concommand.Add("dispatcher_ack", function(ply)
    if not IsValid(ply) then return end
    if not O.Ack(Line.GetPlayerConsist(ply)) then ply:ChatPrint("[Dispatcher] Нет приказа для подтверждения.") end
end)
