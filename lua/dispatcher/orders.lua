--------------------------------------------------------------------------------
-- Dispatcher.Orders — dispatcher orders that change the plan mid-route.
--
-- Order { id, kind, cid, trip, stop, platform, issued, acked, state, text, ... }
--   state: "issued" -> "done" | "violated" | "cancelled"
--
-- Kinds:
--   turnback  short turn at an intermediate station with a crossover / siding
--   skip      pass a station without stopping (station closed)
--   hold      hold the departure from a station for N seconds
--   restrict  speed restriction on the run into a station
--
-- One active order per train. Random orders: dispatcher_orders_chance (per minute).
-- Chat: !оборот [ст.] !проследовать [ст.] !задержка [сек] [ст.] !ограничение [км/ч] [ст.]
--       !приказ (random order now) !понял (acknowledge)
--
-- Events: Dispatcher_OrderIssued / OrderDone / OrderViolated (order)
--------------------------------------------------------------------------------
local Line, S = Dispatcher.Line, Dispatcher.Schedule
local O = Dispatcher.Orders or {}
Dispatcher.Orders = O

local cvChance = CreateConVar("dispatcher_orders_chance", "0.03", FCVAR_ARCHIVE,
    "Chance per minute that the dispatcher issues a random order to a train with a timetable (0 = off)")

local ACK_TIMEOUT   = 60    -- s, then the order is repeated once
local MIN_LEAD_DIST = 600   -- m, an order for the very next station needs at least this much warning
local OVERSPEED_TOL = 2     -- km/h over the limit tolerated
local OVERSPEED_MAX = 2     -- s over the limit -> violation

O.Active = O.Active or {}   -- [cid] = order
O.Log = O.Log or {}         -- [cid] = { order, ... } for the shift report
O.Counter = O.Counter or 0

local function say(cid, text) Dispatcher.Comms.Say(cid, text) end
local function trackName(pl) return pl.index == 1 and "I" or "II" end
local function T(t) return Line.FormatTime(t) end
local function pick(t) return t[math.random(#t)] end

local function dur(s)
    s = math.Round(s)
    if s < 60 then return s .. " с" end
    if s % 60 == 0 then return (s / 60) .. " мин" end
    return Format("%d мин %d с", math.floor(s / 60), s % 60)
end

-- Stations where a turnback is possible on this map
function O.IsTurnbackStation(station)
    local list = Dispatcher.MapConfig and Dispatcher.MapConfig.turnbacks
    if not list then return false end
    for _, id in ipairs(list) do if id == station.id then return true end end
    return false
end

--------------------------------------------------------------------------------
-- Where an order can apply
--------------------------------------------------------------------------------
local function lastRealIndex(trip)
    return #trip.stops - (trip.stops[#trip.stops].platform.siding and 1 or 0)
end

-- Stops of the current trip ahead of the train that the driver can still react to.
--   opts.current   include the current stop while still standing there
--   opts.last      include the last station of the trip
-- Returns { {stop=, j=}, ... }
function O.StopsAhead(consist, opts)
    opts = opts or {}
    local trip, a = S.CurrentTrip(consist)
    if not trip or a.finished then return {} end
    local cur = trip.cur or 1
    local running = trip.stops[cur].factDep ~= nil
    local st = Line.GetState(consist)
    local list = {}
    if opts.current and not running and trip.stops[cur].dep then
        list[#list + 1] = { stop = trip.stops[cur], j = cur }
    end
    local last = lastRealIndex(trip) - (opts.last and 0 or 1)
    for j = cur + 1, last do
        local s = trip.stops[j]
        if j == cur + 1 and running then
            -- already running towards it: needs enough distance to brake and plan
            if not (st and st.stop == s.platform and st.distToStop and st.distToStop > MIN_LEAD_DIST) then continue end
        end
        list[#list + 1] = { stop = s, j = j }
    end
    return list, trip
end

local function indexOf(trip, stop)
    for j, s in ipairs(trip.stops) do if s == stop then return j end end
end

--------------------------------------------------------------------------------
-- Issuing
--------------------------------------------------------------------------------
local function newOrder(consist, kind, trip, stop, reason)
    O.Counter = O.Counter + 1
    local order = {
        id = O.Counter, kind = kind, cid = consist.id, trip = trip, stop = stop,
        platform = stop and stop.platform, issued = Line.Now(), state = "issued", reason = reason,
    }
    O.Active[consist.id] = order
    O.Log[consist.id] = O.Log[consist.id] or {}
    table.insert(O.Log[consist.id], order)
    return order
end

local function announce(order, body)
    order.text = Format("Приказ №%d. %s%s Подтвердите: !понял", order.id,
        order.reason and (order.reason .. " ") or "", body)
    say(order.cid, order.text)
    hook.Run("Dispatcher_OrderIssued", order)
    return order
end

local REASONS = {
    turnback = { "Сбой движения на линии.", "Неисправность на пути впереди.", "Выравнивание интервалов.",
                 "Пострадавший на путях впереди." },
    skip     = { "Станция закрыта на вход и выход.", "Задымление на станции.", "Станция закрыта по техническим причинам." },
    hold     = { "Выравнивание интервалов.", "Задержка впереди идущего поезда.", "Сбой движения впереди." },
    restrict = { "Путевые работы.", "Неисправность пути.", "Люди на пути.", "Отказ рельсовой цепи." },
}

-- Turnback at `stop` (an intermediate station of the current trip)
function O.IssueTurnback(consist, stop, reason)
    local a = S.GetAssignment(consist)
    if not a or O.Active[consist.id] then return nil, "busy" end
    local pl = stop.platform
    local trip = a.trips[a.ti]
    -- (on the last trip of the shift still bring the train back to the terminal)
    if not S.TurnBack(a, pl, true) then return nil, "not on the current trip" end
    local nextTrip = a.trips[a.ti + 1]
    local opposite = nextTrip and nextTrip.stops[1].platform or Line.OppositePlatform(pl)
    if not opposite then return nil, "no opposite platform" end
    local sd = Line.SidingFor(pl)
    local dep = nextTrip and nextTrip.stops[1].dep

    local order = newOrder(consist, "turnback", trip, stop, reason)
    order.opposite = opposite
    return announce(order, Format("Оборот по ст. %s: высадка пассажиров, оборот %s, отправление со ст. %s по %s пути%s.",
        pl.station.name, sd and ("через " .. sd.name) or "по съезду",
        opposite.station.name, trackName(opposite), dep and (" в " .. T(dep)) or ""))
end

-- Pass `stop` without stopping
function O.IssueSkip(consist, stop, reason)
    if O.Active[consist.id] then return nil, "busy" end
    local trip = S.CurrentTrip(consist)
    if not trip or not S.SkipStop(trip, stop.platform) then return nil, "not on the current trip" end
    local order = newOrder(consist, "skip", trip, stop, reason)
    return announce(order, Format("Ст. %s проследовать без остановки, двери не открывать.", stop.platform.title))
end

-- Hold the departure from `stop` for `seconds`
function O.IssueHold(consist, stop, seconds, reason)
    if O.Active[consist.id] then return nil, "busy" end
    local trip = S.CurrentTrip(consist)
    if not trip or not S.Hold(trip, stop.platform, seconds) then return nil, "not on the current trip" end
    local order = newOrder(consist, "hold", trip, stop, reason)
    order.seconds = seconds
    local here = trip.stops[trip.cur] == stop and not stop.factDep
    return announce(order, Format("%s ст. %s задержать отправление на %s, отправление в %s.",
        here and "На" or "По прибытии на", stop.platform.title, dur(seconds), T(stop.dep)))
end

-- Speed restriction on the run into `stop`
function O.IssueRestrict(consist, stop, limit, reason)
    if O.Active[consist.id] then return nil, "busy" end
    local trip = S.CurrentTrip(consist)
    local j = trip and indexOf(trip, stop)
    if not j or j < 2 or not S.Restrict(trip, stop.platform, limit) then return nil, "not on the current trip" end
    local order = newOrder(consist, "restrict", trip, stop, reason)
    order.limit, order.from, order.over, order.maxSpeed = limit, trip.stops[j - 1], 0, 0
    return announce(order, Format("На перегоне %s — %s скорость не более %d км/ч. Прибытие на ст. %s по графику в %s.",
        order.from.platform.title, stop.platform.title, limit, stop.platform.title, T(stop.arr)))
end

--------------------------------------------------------------------------------
-- Random orders
--------------------------------------------------------------------------------
local HOLD_TIMES = { 60, 90, 120, 150, 180 }
local LIMITS = { 25, 35, 40, 50 }

-- Every kind that can be given right now: { kind, fn }
local function options(consist)
    local opts = {}
    local turn = {}
    for _, c in ipairs(O.StopsAhead(consist)) do
        if O.IsTurnbackStation(c.stop.platform.station) then turn[#turn + 1] = c.stop end
    end
    if #turn > 0 then
        opts[#opts + 1] = function() return O.IssueTurnback(consist, pick(turn), pick(REASONS.turnback)) end
    end

    local skip = {}
    for _, c in ipairs(O.StopsAhead(consist)) do
        if not c.stop.skip and not c.stop.platform.siding then skip[#skip + 1] = c.stop end
    end
    if #skip > 0 then
        opts[#opts + 1] = function() return O.IssueSkip(consist, pick(skip), pick(REASONS.skip)) end
    end

    local hold = O.StopsAhead(consist, { current = true })
    if #hold > 0 then
        local c = hold[1]   -- the nearest: holding far ahead makes little sense
        opts[#opts + 1] = function() return O.IssueHold(consist, c.stop, pick(HOLD_TIMES), pick(REASONS.hold)) end
        opts[#opts + 1] = opts[#opts]   -- holds are the most common
    end

    local restr = {}
    for _, c in ipairs(O.StopsAhead(consist, { last = true })) do
        if c.j >= 2 and not c.stop.restricted then restr[#restr + 1] = c.stop end
    end
    if #restr > 0 then
        opts[#opts + 1] = function() return O.IssueRestrict(consist, restr[1], pick(LIMITS), pick(REASONS.restrict)) end
        opts[#opts + 1] = opts[#opts]
    end
    return opts
end

function O.IssueRandom(consist)
    local opts = options(consist)
    if #opts == 0 then return nil end
    return pick(opts)()
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
            if c and O.IssueRandom(c) then trip.orderGiven = true end
        end
    end
end)

--------------------------------------------------------------------------------
-- Acknowledge / resolution
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

local function finish(order, state, text)
    order.state = state
    order.finished = Line.Now()
    O.Active[order.cid] = nil
    if text then
        if state == "done" and not order.acked then text = text .. " (приказ не был подтверждён)" end
        say(order.cid, text)
    end
    hook.Run(state == "done" and "Dispatcher_OrderDone" or "Dispatcher_OrderViolated", order)
end

-- Turnback: done at the opposite platform; violated beyond the turnback station.
hook.Add("Dispatcher_Arrive", "Dispatcher_Orders", function(consist, st, platform)
    local order = O.Active[consist.id]
    if not order or order.kind ~= "turnback" then return end
    if platform == order.opposite then
        return finish(order, "done", Format("Оборот по ст. %s выполнен.", order.platform.station.name))
    end
    local dir = Line.OrderDir(order.platform.index)
    if platform.index == order.platform.index
        and (platform.station.order - order.platform.station.order) * dir > 0 then
        finish(order, "violated", Format("Нарушение приказа №%d: оборот по ст. %s не выполнен!", order.id, order.platform.station.name))
    end
end)

hook.Add("Dispatcher_StopArrive", "Dispatcher_Orders", function(cid, trip, stop)
    local order = O.Active[cid]
    if not order or order.trip ~= trip then return end
    local jOrder, jNow = indexOf(trip, order.stop), indexOf(trip, stop)
    if not jOrder or not jNow then return end

    if order.kind == "skip" then
        if jNow == jOrder then
            finish(order, "violated", Format("Нарушение приказа №%d: остановка на ст. %s, где она отменена!", order.id, stop.platform.title))
        elseif jNow > jOrder then
            finish(order, "done", Format("Ст. %s проследована без остановки, приказ выполнен.", order.stop.platform.title))
        end
    elseif order.kind == "hold" and jNow > jOrder then
        finish(order, "violated", Format("Нарушение приказа №%d: ст. %s проследована без задержки!", order.id, order.stop.platform.title))
    elseif order.kind == "restrict" and jNow >= jOrder then
        if order.over > OVERSPEED_MAX then
            finish(order, "violated", Format("Нарушение приказа №%d: превышение ограничения %d км/ч (макс. %.0f).",
                order.id, order.limit, order.maxSpeed))
        else
            finish(order, "done", Format("Ограничение %d км/ч соблюдено, приказ выполнен.", order.limit))
        end
    end
end)

hook.Add("Dispatcher_StopDepart", "Dispatcher_Orders", function(cid, trip, stop, dev)
    local order = O.Active[cid]
    if not order or order.kind ~= "hold" or order.stop ~= stop then return end
    if dev < -S.Tolerance() then
        finish(order, "violated", Format("Нарушение приказа №%d: отправление со ст. %s до окончания задержки!", order.id, stop.platform.title))
    else
        finish(order, "done", "Задержка выдержана, приказ выполнен.")
    end
end)

hook.Add("Dispatcher_StopMissed", "Dispatcher_Orders", function(cid, trip, stop)
    local order = O.Active[cid]
    if order and order.kind == "hold" and order.stop == stop then
        finish(order, "violated", Format("Нарушение приказа №%d: ст. %s проследована без задержки!", order.id, stop.platform.title))
    end
end)

-- Speed watch on restricted runs
timer.Create("Dispatcher_OrderSpeed", 0.5, 0, function()
    for cid, order in pairs(O.Active) do
        if order.kind ~= "restrict" then continue end
        local trip = order.trip
        local jFrom = indexOf(trip, order.from)
        -- the restricted run: departed from `from`, not yet at the order's stop
        if not jFrom or (trip.cur or 1) ~= jFrom or not order.from.factDep then continue end
        local c = Line.GetConsist(cid)
        local st = c and Line.GetState(c)
        if not st then continue end
        order.maxSpeed = math.max(order.maxSpeed, st.speed)
        if st.speed > order.limit + OVERSPEED_TOL then
            order.over = order.over + 0.5
            if not order.warned or CurTime() - order.warned > 15 then
                order.warned = CurTime()
                say(cid, Format("Превышение! Ограничение %d км/ч, у вас %.0f.", order.limit, st.speed))
            end
        end
    end
end)

-- Shift over -> pending orders are void
hook.Add("Dispatcher_ShiftDone", "Dispatcher_Orders", function(cid)
    local order = O.Active[cid]
    if order then order.state, order.finished, O.Active[cid] = "cancelled", Line.Now(), nil end
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

local function findStop(cands, query)
    if not query or query == "" then return cands[1] and cands[1].stop end
    local q = lower(query)
    for _, c in ipairs(cands) do
        local st = c.stop.platform.station
        if tostring(st.id) == q or string.find(lower(c.stop.platform.title), q, 1, true) == 1 then return c.stop end
    end
end

local function names(cands)
    local t = {}
    for _, c in ipairs(cands) do t[#t + 1] = c.stop.platform.title end
    return table.concat(t, ", ")
end

-- Common checks; returns consist or nil
local function orderPrecheck(ply)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    if not c or not S.GetAssignment(c) then ply:ChatPrint("[Dispatcher] Сначала возьми наряд: !рейс") return end
    if O.Active[c.id] then ply:ChatPrint("[Dispatcher] Уже есть невыполненный приказ: " .. (O.Active[c.id].text or "")) return end
    return c
end

local function noStation(ply, cands)
    ply:ChatPrint("[Dispatcher] Нет подходящей станции впереди" .. (#cands > 0 and (". Можно: " .. names(cands)) or "."))
end

concommand.Add("dispatcher_order_turnback", function(ply, _, args)
    local c = orderPrecheck(ply) if not c then return end
    local query = table.concat(args, " ")
    local all = O.StopsAhead(c)
    local turn = {}
    for _, x in ipairs(all) do if O.IsTurnbackStation(x.stop.platform.station) then turn[#turn + 1] = x end end
    -- by name: any station ahead; without: the nearest station with a crossover
    local stop = findStop(query ~= "" and all or turn, query)
    if not stop then return noStation(ply, turn) end
    if not O.IsTurnbackStation(stop.platform.station) then
        ply:ChatPrint("[Dispatcher] Внимание: на ст. " .. stop.platform.station.name .. " съезда может не быть.")
    end
    O.IssueTurnback(c, stop, "По запросу.")
end)

concommand.Add("dispatcher_order_skip", function(ply, _, args)
    local c = orderPrecheck(ply) if not c then return end
    local cands = O.StopsAhead(c)
    local stop = findStop(cands, table.concat(args, " "))
    if not stop then return noStation(ply, cands) end
    O.IssueSkip(c, stop, "По запросу.")
end)

concommand.Add("dispatcher_order_hold", function(ply, _, args)
    local c = orderPrecheck(ply) if not c then return end
    local seconds = tonumber(args[1])
    if seconds then table.remove(args, 1) end
    seconds = math.Clamp(seconds or 120, 10, 1800)
    local cands = O.StopsAhead(c, { current = true })
    local stop = findStop(cands, table.concat(args, " "))
    if not stop then return noStation(ply, cands) end
    O.IssueHold(c, stop, seconds, "По запросу.")
end)

concommand.Add("dispatcher_order_restrict", function(ply, _, args)
    local c = orderPrecheck(ply) if not c then return end
    local limit = tonumber(args[1])
    if limit then table.remove(args, 1) end
    limit = math.Clamp(limit or 40, 5, 80)
    local cands = {}
    for _, x in ipairs(O.StopsAhead(c, { last = true })) do if x.j >= 2 then cands[#cands + 1] = x end end
    local stop = findStop(cands, table.concat(args, " "))
    if not stop then return noStation(ply, cands) end
    O.IssueRestrict(c, stop, limit, "По запросу.")
end)

concommand.Add("dispatcher_order_random", function(ply)
    local c = orderPrecheck(ply) if not c then return end
    if not O.IssueRandom(c) then ply:ChatPrint("[Dispatcher] Сейчас нечего приказать: впереди нет подходящих станций.") end
end)

concommand.Add("dispatcher_ack", function(ply)
    if not IsValid(ply) then return end
    if not O.Ack(Line.GetPlayerConsist(ply)) then ply:ChatPrint("[Dispatcher] Нет приказа для подтверждения.") end
end)
