--------------------------------------------------------------------------------
-- Dispatcher.Routes — setting routes at route signals (switches + opening).
--
-- Automatic: when a train with a driver comes within AUTO_DIST of a route
-- signal ahead, the dispatcher picks the route:
--   with a timetable: the one leading to the path of the next planned stop
--                     (platform, turnback dead end, depot link, crossover)
--   without:          leaves it if the switches already form one of the signal's
--                     routes (someone set it by hand), else the straight one
-- and sets it once per approach. Manual: !маршрут [номер | название | куда].
--
-- Safety: a switch with a train on or next to it is never thrown; switches set
-- for one train are reserved for it until it has passed, another train's route
-- that needs them differently waits.
--------------------------------------------------------------------------------
local Line, G = Dispatcher.Line, Dispatcher.Graph
local R = Dispatcher.Routes or {}
Dispatcher.Routes = R

local cvAuto = CreateConVar("dispatcher_autoroutes", "1", FCVAR_ARCHIVE, "Set routes at route signals automatically")

local U2M = 0.01905
local AUTO_DIST     = 300   -- m: route signal this close ahead -> set the route
local ASK_DIST      = 600   -- m: !маршрут looks this far ahead
local SWITCH_BUSY   = 25    -- m: a car this close to a switch blocks throwing it
local RESERVE_AFTER = 150   -- m: a reservation is released once the train is this far past the signal

R.Reserved = R.Reserved or {}   -- [switchName] = { cid, pos ("main"|"alt"), sig }
R.Done = R.Done or {}           -- [cid] = { [signal] = true }: routes already set on this approach

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function isRouteSignal(S)
    if #S.routes > 1 then return true end
    local r = S.routes[1]
    return r and (r.manual or next(r.switches) ~= nil)
end

local function switchPos(name)
    local sw = Metrostroi.GetSwitchByName(name)
    if not IsValid(sw) then return end
    return (sw:GetSignal() ~= 0) and "alt" or "main", sw
end

-- Positions of every car (for "is something on this switch")
local function carPositions()
    local list = {}
    for _, c in ipairs(Line.GetConsists()) do
        for _, w in ipairs(c.wagons) do
            list[#list + 1] = { pos = w:GetPos(), cid = c.id, half = (w:OBBMaxs().x - w:OBBMins().x) / 2, ent = w }
        end
    end
    return list
end

local function switchOccupied(sw, cars)
    local p = sw:GetPos()
    for _, c in ipairs(cars) do
        -- distance from the switch to the car's centre line segment
        local fwd = c.ent:GetForward()
        local rel = p - c.pos
        local along = math.Clamp(rel:Dot(fwd), -c.half, c.half)
        if (rel - fwd * along):Length() * U2M < SWITCH_BUSY then return true end
    end
    return false
end

-- Does the route already stand (switches in place, a manual route opened)?
function R.IsSet(S, r)
    for name, want in pairs(r.switches) do
        if switchPos(name) ~= want then return false end
    end
    if r.manual then
        local raw = S.ent.Routes and S.ent.Routes[r.index]
        if not (raw and raw.IsOpened) then return false end
    end
    return true
end

-- A route with no signal after it ("X"): the data does not say where it goes
-- (a stub where the map ends, a wrong-direction exit, an unsignalled depot track).
-- Never chosen automatically; a map config can name the ones that lead somewhere.
-- Exception: r.depot, routes the map config lists in depotRoutes (into the depot).
local function noSignal(r) return not r.target and r.next == "X" and not r.depot end

-- What is the route's target path (where the train ends up)
local function targetPath(S, r)
    if r.target then return r.target.path end
    return S.path   -- "*": on to the line, stays on this path
end

-- Name of what lies at x on path P: a siding (only near its end mark) or the
-- nearest platform. The same path can hold a platform here and a dead end at the
-- other end of the line (path #1: Некрасовка … Нижегородская т3).
local function placeAt(P, x)
    for _, sd in ipairs(Line.GetSidings()) do
        if sd.path and sd.path.id == P.id and sd.xEnd and math.abs(sd.xEnd - x) < 400 then return sd.name end
    end
    local best, bestD
    for _, pl in ipairs(P.platforms) do
        local d = math.abs((pl.xEnd or 0) - x)
        if not pl.siding and (not bestD or d < bestD) then best, bestD = pl, d end
    end
    if best and bestD < 1500 then return best.station.name .. " (путь " .. (best.index or "?") .. ")" end
    if P.kind == "depotlink" then return "путь #" .. P.id .. " (к депо)" end
    return "путь #" .. P.id
end

local function describeTarget(S, r)
    if r.target then return placeAt(r.target.path, r.target.x) .. ", светофор " .. (r.target.name or "?") end
    if r.depot then return "в депо (без светофора)" end
    if noSignal(r) then return "без светофора впереди" end
    -- "*": on along this path, to the next platform in the signal's direction
    local best, bestD
    for _, pl in ipairs(S.path.platforms) do
        local d = ((pl.xEnd or 0) - S.x) * S.dir
        if not pl.siding and d > 0 and (not bestD or d < bestD) then best, bestD = pl, d end
    end
    -- a dead end on this same path that comes first (Нижегородская т3 lies on path #1)
    for _, sd in ipairs(Line.GetSidings()) do
        local d = sd.path and sd.path == S.path.raw and sd.xEnd and (sd.xEnd - S.x) * S.dir
        if d and d > 0 and d < 1000 and (not bestD or d < bestD) then return "в " .. sd.name end
    end
    if best then return "на " .. best.station.name .. " (путь " .. (best.index or "?") .. ")" end
    return "дальше по пути #" .. S.path.id
end

--------------------------------------------------------------------------------
-- Setting a route
--------------------------------------------------------------------------------
-- Returns true, or false + reason
function R.Set(S, r, cid)
    if R.IsSet(S, r) then return true end
    local cars = carPositions()
    for name, want in pairs(r.switches) do
        local cur, sw = switchPos(name)
        if not sw then return false, "нет стрелки " .. name end
        if cur ~= want then
            local res = R.Reserved[name]
            if res and res.cid ~= cid and res.pos ~= want then return false, "стрелка " .. name .. " занята маршрутом другого поезда" end
            if switchOccupied(sw, cars) then return false, "на стрелке " .. name .. " стоит поезд" end
        end
    end
    -- close the signal's other MANUAL route first (it stays "opened" otherwise).
    -- Not for ordinary routes: Metrostroi's CloseRoute throws every switch of the
    -- route to "+" (it compares an undefined SwitchState), even ones nobody asked for.
    local ent = S.ent
    local last = ent.LastOpenedRoute and ent.Routes[ent.LastOpenedRoute]
    if last and last.Manual and ent.LastOpenedRoute ~= r.index then
        pcall(ent.CloseRoute, ent, ent.LastOpenedRoute)
    end
    local ok = pcall(ent.OpenRoute, ent, r.index)
    if not ok then return false, "светофор не принял маршрут" end
    for name, want in pairs(r.switches) do R.Reserved[name] = { cid = cid, pos = want, sig = S } end
    hook.Run("Dispatcher_RouteSet", cid, S, r)
    return true
end

-- Release reservations of trains that have passed their signal
timer.Create("Dispatcher_RouteRelease", 1, 0, function()
    for name, res in pairs(R.Reserved) do
        local c = Line.GetConsist(res.cid)
        local st = c and Line.GetState(c)
        local passed = not st or not st.onTrack or (st.path == res.sig.path.raw and (st.x - res.sig.x) * res.sig.dir > RESERVE_AFTER)
            or (st.path ~= res.sig.path.raw)
        if passed then R.Reserved[name] = nil end
    end
end)

--------------------------------------------------------------------------------
-- Choosing a route
--------------------------------------------------------------------------------
-- Route signals ahead of a train state, nearest first: { {S, dist}, ... }
function R.SignalsAhead(st, maxDist, any)   -- any: every signal, not only route ones
    local g = G.Get()
    if not g or not st or not st.onTrack then return {} end
    local P = g.paths[st.path.id]
    if not P then return {} end
    local s = st.dirPlus and 1 or -1
    local list = {}
    for _, S in ipairs(P.signals) do
        local d = (S.x - st.x) * s
        if S.dir == s and d > -5 and d < maxDist and (any or isRouteSignal(S)) then list[#list + 1] = { S = S, dist = d } end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- Path the timetable wants next (nil if no timetable)
local function plannedPath(consist)
    local S = Dispatcher.Schedule
    local trip, a = S.CurrentTrip(consist)
    if not trip or a.finished then return end
    local nxt = trip.stops[(trip.cur or 1) + 1]
    if not nxt then
        local nt = a.trips[a.ti + 1]
        nxt = nt and nt.stops[1]
    end
    if not nxt then return end
    local pl = nxt.platform
    if pl.depot then return "depot" end
    return pl.path and pl.path.id
end

-- The route at S for this train
function R.Choose(S, consist)
    local g = G.Get()
    local want = plannedPath(consist)
    if want then
        -- 1) straight to the wanted path, 2) to a path that can reach it
        -- (routes without a signal after them are never picked: unknown where they go)
        if want == "depot" then
            for _, r in ipairs(S.routes) do if r.depot then return r, "plan" end end
        end
        for _, r in ipairs(S.routes) do
            local P = targetPath(S, r)
            if not noSignal(r) and not r.depot and ((want == "depot" and P.kind == "depotlink") or P.id == want) then return r, "plan" end
        end
        for _, r in ipairs(S.routes) do
            local P = targetPath(S, r)
            if not noSignal(r) and want ~= "depot" and P.reach[want] then return r, "plan" end
        end
    end
    -- no plan (or it does not go through here): keep what is set by hand, else straight
    for _, r in ipairs(S.routes) do
        if not noSignal(r) and next(r.switches) ~= nil and R.IsSet(S, r) then return nil, "set" end
    end
    for _, r in ipairs(S.routes) do
        if noSignal(r) then continue end
        local straight = true
        for _, pos in pairs(r.switches) do if pos ~= "main" then straight = false end end
        if straight then return r, "default" end
    end
    for _, r in ipairs(S.routes) do if not noSignal(r) then return r, "default" end end
    return nil, "set"
end

--------------------------------------------------------------------------------
-- Automatic
--------------------------------------------------------------------------------
local nextTick = 0
hook.Add("Think", "Dispatcher_AutoRoutes", function()
    if CurTime() < nextTick then return end
    nextTick = CurTime() + 1
    if not cvAuto:GetBool() or not G.Get() then return end
    for _, c in ipairs(Line.GetConsists()) do
        local st = Line.GetState(c)
        if not st or not IsValid(st.driver) then continue end
        local done = R.Done[c.id] or {}
        R.Done[c.id] = done
        local ahead = R.SignalsAhead(st, AUTO_DIST)
        -- forget signals this train is no longer approaching
        local near = {}
        for _, a in ipairs(ahead) do near[a.S] = true end
        for S in pairs(done) do if not near[S] then done[S] = nil end end

        for _, a in ipairs(ahead) do
            if done[a.S] then continue end
            local r, why = R.Choose(a.S, c)
            if not r then done[a.S] = true continue end
            local ok, err = R.Set(a.S, r, c.id)
            if ok then
                done[a.S] = true
                if why == "plan" or a.S.ent.Routes[r.index].Manual then
                    Dispatcher.Comms.Say(c.id, Format("Маршрут на %s приготовлен (светофор %s).", describeTarget(a.S, r), a.S.name or "?"))
                end
            elseif not a.S.waitTold then
                a.S.waitTold = CurTime()
                Dispatcher.Comms.Say(c.id, Format("Светофор %s: маршрут на %s пока не готов — %s. Ожидайте.",
                    a.S.name or "?", describeTarget(a.S, r), err))
            elseif CurTime() - a.S.waitTold > 30 then
                a.S.waitTold = nil
            end
            break   -- one signal at a time: the nearest
        end
    end
end)

--------------------------------------------------------------------------------
-- Manual: !маршрут [номер | название | куда]
--------------------------------------------------------------------------------
concommand.Add("dispatcher_route", function(ply, _, args)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    local st = c and Line.GetState(c)
    local ahead = R.SignalsAhead(st, ASK_DIST)
    local a = ahead[1]
    if not a then
        -- say what is near, to tell "none" from "facing the other way"
        local g, near = G.Get(), {}
        local P = g and st and st.onTrack and g.paths[st.path.id]
        for _, S2 in ipairs(P and P.signals or {}) do
            local d = math.abs(S2.x - st.x)
            if d < 300 and isRouteSignal(S2) then
                near[#near + 1] = Format("%s (%.0f м, для направления %s)", S2.name or "?", d, S2.dir > 0 and "+" or "-")
            end
        end
        Dispatcher.Chat(ply, "[ДЦХ] Впереди нет маршрутного светофора." .. (#near > 0 and
            Format(" Рядом: %s; ты едешь в направлении %s, путь #%s.", table.concat(near, ", "), st.dirPlus and "+" or "-", st.path.id) or ""))
        return
    end
    local S = a.S
    local q = Line.Lower(table.concat(args, " "))
    if q == "" then
        Dispatcher.Chat(ply, Format("[ДЦХ] Светофор %s в %.0f м. Маршруты:", S.name or "?", a.dist))
        for _, r in ipairs(S.routes) do
            local sws = {}
            for name, pos in SortedPairs(r.switches) do sws[#sws + 1] = name .. (pos == "alt" and "-" or "+") end
            Dispatcher.Chat(ply, Format("  %d. %s → %s%s%s", r.index, r.name or "", describeTarget(S, r),
                #sws > 0 and (" [" .. table.concat(sws, ",") .. "]") or "", R.IsSet(S, r) and "  (установлен)" or ""))
        end
        Dispatcher.Chat(ply, "  Выбрать: !маршрут <номер>  или  !маршрут <куда>, например !маршрут т4")
        return
    end
    local pick
    for _, r in ipairs(S.routes) do
        local tgt = Line.Lower(describeTarget(S, r))
        if tostring(r.index) == q or (r.name and Line.Lower(r.name) == q) or tgt:find(q, 1, true) then pick = r break end
    end
    if not pick then Dispatcher.Chat(ply, "[ДЦХ] Нет такого маршрута. Список: !маршрут") return end
    local ok, err = R.Set(S, pick, c.id)
    local done = R.Done[c.id] or {}
    R.Done[c.id] = done
    done[S] = true   -- the automatic one must not overrule a manual choice
    Dispatcher.Comms.Say(c.id, ok and Format("Маршрут на %s приготовлен (светофор %s).", describeTarget(S, pick), S.name or "?")
        or Format("Маршрут на %s приготовить нельзя: %s.", describeTarget(S, pick), err))
end)

hook.Add("Dispatcher_Rekey", "Dispatcher_Routes", function(old, new)
    R.Done[new], R.Done[old] = R.Done[old], nil
    for _, res in pairs(R.Reserved) do if res.cid == old then res.cid = new end end
end)
