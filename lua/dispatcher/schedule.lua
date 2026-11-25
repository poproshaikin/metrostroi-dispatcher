--------------------------------------------------------------------------------
-- Dispatcher.Schedule — timetable: build trips, track the train against them.
--
-- Trip  { id, stops = { Stop, ... }, done }
-- Stop  { platform, run, arr, dep, skip, hold,           -- plan
--         factArr, factDep, stopError, missed }          -- fact
--   run: planned run time from the previous stop (frozen when the trip is built)
--   arr/dep: planned line time (Line.Now() clock). First stop has no arr, last no dep.
--
-- Assignment (one per consist): { consist id, trips = {Trip...}, ti = current trip, ... }
--
-- Events (hook.Run):
--   Dispatcher_StopArrive (cid, trip, stop, deviation)   deviation s: + late, - early
--   Dispatcher_StopDepart (cid, trip, stop, deviation)
--   Dispatcher_StopMissed (cid, trip, stop)              passed a stop without stopping
--   Dispatcher_TripDone   (cid, trip)
--   Dispatcher_ShiftDone  (cid, assignment)
--------------------------------------------------------------------------------
local Line = Dispatcher.Line
local S = Dispatcher.Schedule or {}
Dispatcher.Schedule = S

local cvDwell = CreateConVar("dispatcher_dwell", "30", FCVAR_ARCHIVE, "Planned dwell at intermediate stations, s")
local cvTurn  = CreateConVar("dispatcher_turnover", "240", FCVAR_ARCHIVE, "Planned turnover time at a terminal, s")
local cvLearn = CreateConVar("dispatcher_learn", "1", FCVAR_ARCHIVE, "Adapt run times to actual runs")
local cvTol   = CreateConVar("dispatcher_tolerance", "15", FCVAR_ARCHIVE, "Deviation that counts as on time, s")
local cvUnload = CreateConVar("dispatcher_unload", "60", FCVAR_ARCHIVE,
    "Dwell at the arrival platform before going into a turnback siding (passengers leave), s")
local cvCab   = CreateConVar("dispatcher_cabchange", "120", FCVAR_ARCHIVE, "Planned cab change time in a siding, s")
local cvDepotRun  = CreateConVar("dispatcher_depot_run", "300", FCVAR_ARCHIVE,
    "Planned run between a depot track and the line (until learned), s")
local cvDepotPrep = CreateConVar("dispatcher_depot_prep", "180", FCVAR_ARCHIVE,
    "Time to prepare the train before leaving the depot, s")

local FALLBACK_SPEED = 45   -- km/h average, when Metrostroi can't estimate a run
local MIN_DWELL      = 15   -- s, shorter dwell is reported as a violation

S.Assignments = S.Assignments or {}   -- [consist id] = assignment

--------------------------------------------------------------------------------
-- Run times: Metrostroi estimate, refined by actual runs (saved per map)
--------------------------------------------------------------------------------
local RUNS_FILE = "dispatcher/runs_" .. game.GetMap():lower() .. ".json"
-- saved on this server, else the run times shipped in the map config
local learned = util.JSONToTable(file.Read(RUNS_FILE, "DATA") or "")
    or table.Copy((Dispatcher.MapConfig or {}).runs or {})

local function runKey(a, b)
    return a.key .. ">" .. b.key
end

-- Planned run time a -> b in seconds, and where it came from.
function S.RunTime(a, b)
    local norm = Line.TravelTime(a, b)
    local src = "metrostroi"
    if not norm then
        local d = Line.Distance(a, b)
        if d then norm, src = d / (FALLBACK_SPEED / 3.6) + 25, "distance" end
    end
    if not norm and (a.depot or b.depot) then norm, src = cvDepotRun:GetInt(), "depot" end
    if not norm then norm, src = 120, "default" end
    local l = cvLearn:GetBool() and learned[runKey(a, b)]
    if l then return math.Round(l), "learned", math.Round(norm) end
    return math.Round(norm), src, math.Round(norm)
end

local function learn(a, b, actual)
    local _, _, norm = S.RunTime(a, b)
    -- held / stuck, not a real run (depot runs vary a lot: wider window)
    local lo, hi = 0.5, 2
    if a.depot or b.depot then lo, hi = 0.3, 4 end
    if actual < norm * lo or actual > norm * hi then return end
    local k = runKey(a, b)
    learned[k] = learned[k] and (learned[k] * 0.7 + actual * 0.3) or actual
    file.CreateDir("dispatcher")
    file.Write(RUNS_FILE, util.TableToJSON(learned, true))
end

function S.ForgetRuns()
    learned = {}
    file.Delete(RUNS_FILE)
end

--------------------------------------------------------------------------------
-- Building trips
--------------------------------------------------------------------------------
local tripCounter = 0

-- Recompute planned arr/dep from the first departure, frozen runs, dwell, holds.
--   s.dwell overrides the default dwell (unloading before a siding, cab change in it).
--   A siding as the last stop still has a departure (after the cab change).
function S.Recalc(trip)
    local dwell = cvDwell:GetInt()
    for j = 2, #trip.stops do
        local prev, s = trip.stops[j - 1], trip.stops[j]
        s.arr = prev.dep + s.run
        if j == #trip.stops and not s.platform.siding then
            s.dep = nil
        else
            s.dep = s.arr + (s.skip and 0 or (s.dwell or dwell)) + (s.hold or 0)
        end
    end
end

-- Finish `trip` with a turnover at its last stop. With a siding marked for that
-- platform: unload there, go into the siding, change cabs. Without: a flat
-- dispatcher_turnover. Returns the platform and time the next trip departs.
function S.AppendTurnover(trip)
    local last = trip.stops[#trip.stops]
    if last.platform.siding then return Line.OppositePlatform(last.platform), last.dep and (last.dep + 60) end
    local opposite = Line.OppositePlatform(last.platform)
    -- Turn on the platform: unload, change cabs right here, go back over the
    -- crossover. The next trip starts from this same platform (third value).
    if last.platform.turnHere then
        return opposite, last.arr + cvUnload:GetInt() + cvCab:GetInt(), last.platform
    end
    local sd = Line.SidingFor(last.platform)
    if not sd then
        return opposite, last.arr + cvTurn:GetInt()
    end
    last.dwell = cvUnload:GetInt()
    trip.stops[#trip.stops + 1] = { platform = sd, run = S.RunTime(last.platform, sd), dwell = cvCab:GetInt() }
    S.Recalc(trip)
    local s = trip.stops[#trip.stops]
    -- out of the siding to the opposite platform: about as long as the way in
    return sd.opposite or opposite, s.dep + s.run + 20 + cvDwell:GetInt()
end

-- Trip from platform `from` (departing at `depTime`) along the line to `to`
-- (or to the terminal if `to` is nil).
function S.BuildTrip(from, depTime, to)
    local stops = { { platform = from, dep = depTime, run = 0 } }
    local pl, guard = from, 0
    while pl ~= to and guard < 200 do
        local nxt = Line.NextPlatform(pl)
        if not nxt then break end
        stops[#stops + 1] = { platform = nxt, run = S.RunTime(pl, nxt) }
        pl, guard = nxt, guard + 1
    end
    if #stops < 2 then return end
    tripCounter = tripCounter + 1
    local trip = { id = tripCounter, stops = stops }
    S.Recalc(trip)
    return trip
end

-- Next trip after a turnover. `reverseFrom`: the train turned on this platform
-- and departs from it backwards (it never comes to `from`, the opposite platform).
local function buildNext(from, depTime, reverseFrom)
    local trip = S.BuildTrip(from, depTime)
    if trip and reverseFrom then
        local s1, s2 = trip.stops[1], trip.stops[2]
        s1.platform, s1.reverse = reverseFrom, true
        local r, src = S.RunTime(reverseFrom, s2.platform)
        if src == "learned" then s2.run = r end
        S.Recalc(trip)
    end
    return trip
end

-- Shift route: `count` trips back and forth, turning over at the terminals.
function S.BuildRoute(from, depTime, count, reverseFrom)
    local trips, pl, t, rev = {}, from, depTime, reverseFrom
    for i = 1, count do
        local trip = buildNext(pl, t, rev)
        if not trip then break end
        trips[#trips + 1] = trip
        pl, t, rev = S.AppendTurnover(trip)
        if not pl then break end
    end
    return trips
end

-- Shift from the depot and back:
--   depot track `from` -> exit platform -> `count` circles -> entry platform -> depot track `home`.
-- A circle = out to the far terminal and back. After the circles the train
-- rides on to the depot entry station (it may be intermediate) and the shift
-- ends there.
function S.BuildDepotRoute(from, exitPl, count, home, entryPl)
    local depotDep = math.ceil((Line.Now() + cvDepotPrep:GetInt()) / 30) * 30
    if not Line.NextPlatform(exitPl) then exitPl = Line.OppositePlatform(exitPl) or exitPl end  -- exit onto a terminal's arrival side
    local first = S.BuildTrip(exitPl, 0)
    if not first then return {} end
    table.insert(first.stops, 1, { platform = from, dep = depotDep, run = 0 })
    first.stops[2].run = S.RunTime(from, exitPl)
    S.Recalc(first)

    local trips = { first }
    local pl, t, rev = S.AppendTurnover(first)
    local function addTrip()
        local trip = buildNext(pl, t, rev)
        if not trip then pl = nil return end
        trips[#trips + 1] = trip
        pl, t, rev = S.AppendTurnover(trip)
    end
    -- `count` = circles: how many times the train reaches the FAR terminal (the one
    -- the first trip from the depot runs to). Nekrasovka: 1 = Лух → Нижегородская →
    -- Лух → depot (no Некрасовка); 2 = ... → Нижегородская → Некрасовка → Нижегородская → Лух → depot.
    local function lastReal(trip)
        for j = #trip.stops, 2, -1 do
            local p = trip.stops[j].platform
            if not p.siding and not p.depot then return p end
        end
    end
    local far = lastReal(first) and lastReal(first).station
    local function farVisits()
        local n = 0
        for _, trip in ipairs(trips) do
            local p = lastReal(trip)
            if p and p.station == far then n = n + 1 end
        end
        return n
    end
    local guard = 0
    while pl and farVisits() < count and guard < 40 do addTrip(); guard = guard + 1 end

    -- The depot is entered from `entryPl`, which may be an intermediate station
    -- (Nekrasovka: Лухмановская II): after the circles, ride on until a trip
    -- passes it, and end that trip there.
    local function entryIndex(trip)
        if not entryPl then return end
        for j = 2, #trip.stops do
            if trip.stops[j].platform == entryPl then return j end
        end
    end
    -- (no extra trip if the last circle already ends right at the entry, e.g. a terminal)
    local function endsAtEntry(trip)
        local j = #trip.stops
        while j > 1 and trip.stops[j].platform.siding do j = j - 1 end
        return trip.stops[j].platform == entryPl
    end
    if entryPl and pl and not endsAtEntry(trips[#trips]) then
        local extra = 0
        repeat
            addTrip()
            extra = extra + 1
        until not pl or entryIndex(trips[#trips]) or extra >= 3
    end
    local last = trips[#trips]
    local j = entryIndex(last)
    if j then
        for k = #last.stops, j + 1, -1 do last.stops[k] = nil end
    end
    S.EndAtDepot(last, home)
    return trips
end

-- Make `trip` end on depot track `home` instead of a turnover.
function S.EndAtDepot(trip, home)
    while #trip.stops > 2 and (trip.stops[#trip.stops].platform.siding or trip.stops[#trip.stops].platform.depot) do
        table.remove(trip.stops)
    end
    local lastStop = trip.stops[#trip.stops]
    lastStop.dwell = cvUnload:GetInt()
    trip.stops[#trip.stops + 1] = { platform = home, run = S.RunTime(lastStop.platform, home), depotEnd = true }
    S.Recalc(trip)
end

-- Depot track the shift ends on, if it does
local function depotHome(a)
    local last = a.trips[#a.trips]
    local s = last and last.stops[#last.stops]
    return s and s.depotEnd and s.platform
end

--------------------------------------------------------------------------------
-- Changing the plan (for orders.lua)
--------------------------------------------------------------------------------
local function findStop(trip, platform)
    for j, s in ipairs(trip.stops) do
        if s.platform == platform then return s, j end
    end
end

-- Pass `platform` without stopping.
function S.SkipStop(trip, platform)
    local s = findStop(trip, platform)
    if not s then return false end
    s.skip = true
    S.Recalc(trip)
    return true
end

-- Hold the train at `platform` for extra `seconds`.
function S.Hold(trip, platform, seconds)
    local s = findStop(trip, platform)
    if not s or not s.dep then return false end
    s.hold = (s.hold or 0) + seconds
    S.Recalc(trip)
    return true
end

-- Speed restriction on the run into `platform` (from the previous stop):
-- the planned run time grows to what the limit allows. limit in km/h.
function S.Restrict(trip, platform, limit)
    local s, j = findStop(trip, platform)
    if not s or j < 2 then return false end
    local d = Line.Distance(trip.stops[j - 1].platform, platform)
    if d then
        local need = math.Round(d / (limit / 3.6) + 20)
        if need > s.run then s.runOrig, s.run = s.run, need end
    end
    s.restricted = limit
    S.Recalc(trip)
    return true
end

-- Move the whole trip by `seconds`.
function S.Shift(trip, seconds)
    trip.stops[1].dep = trip.stops[1].dep + seconds
    S.Recalc(trip)
end

-- Short turn: end the current trip at `platform` (+ its siding, if marked),
-- rebuild the rest of the shift from the opposite platform.
-- ensureReturn: on the last trip still add one trip back to the terminal.
function S.TurnBack(a, platform, ensureReturn)
    local trip = a.trips[a.ti]
    local _, j = findStop(trip, platform)
    if not j or j < 2 then return false end
    local home = depotHome(a)
    for k = #trip.stops, j + 1, -1 do trip.stops[k] = nil end
    local s = trip.stops[j]
    s.dep, s.skip, s.hold, s.dwell = nil, nil, nil, nil
    local nextPl, nextDep, nextRev = S.AppendTurnover(trip)
    local left = #a.trips - a.ti
    for k = #a.trips, a.ti + 1, -1 do a.trips[k] = nil end
    if left == 0 and ensureReturn then left = 1 end
    if left > 0 and nextPl then
        local rest = S.BuildRoute(nextPl, nextDep, left, nextRev)
        for _, t in ipairs(rest) do a.trips[#a.trips + 1] = t end
    end
    if home then S.EndAtDepot(a.trips[#a.trips], home) end   -- keep the way back to the depot
    return true
end

--------------------------------------------------------------------------------
-- Assignments
--------------------------------------------------------------------------------
function S.Assign(consist, trips)
    if not consist or not trips or #trips == 0 then return end
    local a = { cid = consist.id, trips = trips, ti = 1, started = Line.Now() }
    trips[1].cur = 1
    -- The train is already standing at the first platform
    local st = Line.GetState(consist)
    if st and st.at == trips[1].stops[1].platform then trips[1].stops[1].factArr = Line.Now() end
    S.Assignments[consist.id] = a
    return a
end

function S.Cancel(consist)
    if consist then S.Assignments[consist.id] = nil end
end

function S.GetAssignment(consist)
    return consist and S.Assignments[consist.id]
end

function S.CurrentTrip(consist)
    local a = S.GetAssignment(consist)
    return a and a.trips[a.ti], a
end

-- Live status for messages / HUD:
-- { trip, stop = next Stop, plannedArr, eta, deviation }  deviation: + late, - early
function S.GetStatus(consist)
    local trip = S.CurrentTrip(consist)
    if not trip then return end
    local cur = trip.stops[trip.cur or 1]
    local nxt = trip.stops[(trip.cur or 1) + 1]
    local now = Line.Now()
    if not nxt then return { trip = trip, stop = cur } end
    if not cur.factDep then
        -- Still standing: deviation is how late the departure already is
        return { trip = trip, stop = cur, plannedDep = cur.dep, deviation = math.max(0, now - cur.dep) }
    end
    local st = Line.GetState(consist)
    local eta
    local seg = Line.Distance(cur.platform, nxt.platform)
    if st and st.stop == nxt.platform and st.distToStop and seg and seg > 0 then
        eta = now + nxt.run * math.Clamp(st.distToStop / seg, 0, 1)
    else
        eta = math.max(now, cur.factDep + nxt.run)
    end
    return { trip = trip, stop = nxt, plannedArr = nxt.arr, eta = eta, deviation = eta - nxt.arr }
end

--------------------------------------------------------------------------------
-- Tracking: Line events -> plan vs fact
--------------------------------------------------------------------------------
local function advanceTrip(a, cid)
    local trip = a.trips[a.ti]
    trip.done = true
    hook.Run("Dispatcher_TripDone", cid, trip)
    a.ti = a.ti + 1
    if not a.trips[a.ti] then
        a.finished = Line.Now()
        hook.Run("Dispatcher_ShiftDone", cid, a)
        return
    end
    a.trips[a.ti].cur = 1
    return a.trips[a.ti]
end

hook.Add("Dispatcher_Arrive", "Dispatcher_Schedule", function(consist, st, platform, stopError)
    local a = S.Assignments[consist.id]
    if not a or a.finished then return end
    local trip = a.trips[a.ti]
    local now = Line.Now()

    -- Arrived at the first platform of the next trip (after turnover)
    -- (the siding at the end may have gone unregistered: then we are one stop short)
    local nextTrip = a.trips[a.ti + 1]
    local lastReal = #trip.stops - (trip.stops[#trip.stops].platform.siding and 1 or 0)
    if trip.cur >= lastReal and nextTrip and nextTrip.stops[1].platform == platform then
        trip = advanceTrip(a, consist.id)
        trip.stops[1].factArr = now
        return
    end

    for j = trip.cur + 1, #trip.stops do
        local s = trip.stops[j]
        if Line.SameTurnback(s.platform, platform) then
            -- the other track of a two-track turnback counts too
            if s.platform ~= platform then s.plannedPlatform, s.platform = s.platform, platform end
            -- Everything between was passed without stopping
            for k = trip.cur + 1, j - 1 do
                local m = trip.stops[k]
                if not m.skip then m.missed = true; hook.Run("Dispatcher_StopMissed", consist.id, trip, m) end
            end
            local prev = trip.stops[j - 1]
            -- learn only from a normal run (no stops skipped, no speed restriction)
            if j - 1 == trip.cur and prev.factDep and not prev.skip and not s.restricted then
                learn(prev.platform, s.platform, now - prev.factDep)
            end

            s.factArr, s.stopError = now, stopError
            trip.cur = j
            hook.Run("Dispatcher_StopArrive", consist.id, trip, s, now - s.arr)
            if j == #trip.stops and not a.trips[a.ti + 1] then advanceTrip(a, consist.id) end
            return
        end
    end

    -- Stood on the wrong depot track at the end of the shift
    local last = trip.stops[#trip.stops]
    if platform.depot and last.depotEnd and last.platform ~= platform and trip.cur >= #trip.stops - 1 then
        last.wrongTrack = platform
        hook.Run("Dispatcher_WrongDepotTrack", consist.id, trip, last, platform)
    end
end)

hook.Add("Dispatcher_Depart", "Dispatcher_Schedule", function(consist, st, platform, departTime)
    local a = S.Assignments[consist.id]
    if not a or a.finished then return end
    local trip = a.trips[a.ti]
    local s = trip.stops[trip.cur]
    -- Turned on the platform: leaving the last stop backwards = the next trip starts
    local nextTrip = a.trips[a.ti + 1]
    if s and s.platform == platform and not s.dep and trip.cur == #trip.stops
        and nextTrip and nextTrip.stops[1].reverse and nextTrip.stops[1].platform == platform then
        local arrived = s.factArr
        trip = advanceTrip(a, consist.id)
        if not trip then return end
        s = trip.stops[1]
        s.factArr = arrived
    end
    if not s or s.platform ~= platform or not s.dep then return end
    local now = departTime or Line.Now()
    s.factDep = now
    hook.Run("Dispatcher_StopDepart", consist.id, trip, s, now - s.dep)
end)

-- Detect passing a planned stop without stopping, right when it happens:
-- the head left the platform's stop mark behind and the train never stopped.
timer.Create("Dispatcher_ScheduleWatch", 0.5, 0, function()
    for cid, a in pairs(S.Assignments) do
        if a.finished or S.IsPaused(a) then continue end
        local trip = a.trips[a.ti]
        local cur = trip.stops[trip.cur]
        local nxt = trip.stops[trip.cur + 1]
        if not nxt or nxt.missed or nxt.skip or not cur.factDep then continue end
        for _, c in ipairs(Line.GetConsists()) do
            if c.id ~= cid then continue end
            local st = Line.GetState(c)
            -- the next stop mark ahead is already beyond nxt: nxt was passed
            local dBeyond = st and st.stop and st.stop ~= nxt.platform and Line.Distance(cur.platform, st.stop)
            local dNext = Line.Distance(cur.platform, nxt.platform)
            if dBeyond and dNext and dBeyond > dNext then
                nxt.missed = true
                hook.Run("Dispatcher_StopMissed", cid, trip, nxt)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Violations that schedule can see on its own
--------------------------------------------------------------------------------
hook.Add("Dispatcher_StopDepart", "Dispatcher_ScheduleChecks", function(cid, trip, s, dev)
    if s.factArr and s.factDep - s.factArr < MIN_DWELL and s ~= trip.stops[1] then
        s.shortDwell = true
    end
end)

S.Tolerance = function() return cvTol:GetInt() end

-- Restored from a save and the driver hasn't taken the seat yet: the timetable
-- waits (no lateness, no orders) — see persist.lua
function S.IsPaused(a)
    return a and a.restored ~= nil and not a.restored.told
end
