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

local FALLBACK_SPEED = 45   -- km/h average, when Metrostroi can't estimate a run
local MIN_DWELL      = 15   -- s, shorter dwell is reported as a violation

S.Assignments = S.Assignments or {}   -- [consist id] = assignment

--------------------------------------------------------------------------------
-- Run times: Metrostroi estimate, refined by actual runs (saved per map)
--------------------------------------------------------------------------------
local RUNS_FILE = "dispatcher/runs_" .. game.GetMap():lower() .. ".json"
local learned = util.JSONToTable(file.Read(RUNS_FILE, "DATA") or "") or {}

local function runKey(a, b)
    return Format("%d/%d>%d/%d", a.station.id, a.index, b.station.id, b.index)
end

-- Planned run time a -> b in seconds, and where it came from.
function S.RunTime(a, b)
    local norm = Line.TravelTime(a, b)
    local src = "metrostroi"
    if not norm then
        local d = Line.Distance(a, b)
        if d then norm, src = d / (FALLBACK_SPEED / 3.6) + 25, "distance" end
    end
    if not norm then norm, src = 120, "default" end
    local l = cvLearn:GetBool() and learned[runKey(a, b)]
    if l then return math.Round(l), "learned", math.Round(norm) end
    return math.Round(norm), src, math.Round(norm)
end

local function learn(a, b, actual)
    local _, _, norm = S.RunTime(a, b)
    if actual < norm * 0.5 or actual > norm * 2 then return end   -- held / stuck, not a real run
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
function S.Recalc(trip)
    local dwell = cvDwell:GetInt()
    for j = 2, #trip.stops do
        local prev, s = trip.stops[j - 1], trip.stops[j]
        s.arr = prev.dep + s.run
        if j == #trip.stops then
            s.dep = nil
        else
            s.dep = s.arr + (s.skip and 0 or dwell) + (s.hold or 0)
        end
    end
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

-- Shift route: `count` trips back and forth, turning over at the terminals.
function S.BuildRoute(from, depTime, count)
    local trips, pl, t = {}, from, depTime
    for _ = 1, count do
        local trip = S.BuildTrip(pl, t)
        if not trip then break end
        trips[#trips + 1] = trip
        local last = trip.stops[#trip.stops]
        pl = Line.OppositePlatform(last.platform)
        t = last.arr + cvTurn:GetInt()
        if not pl then break end
    end
    return trips
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

-- Move the whole trip by `seconds`.
function S.Shift(trip, seconds)
    trip.stops[1].dep = trip.stops[1].dep + seconds
    S.Recalc(trip)
end

-- Short turn: end the current trip at `platform`, rebuild the rest of the shift
-- from the opposite platform.
function S.TurnBack(a, platform)
    local trip = a.trips[a.ti]
    local _, j = findStop(trip, platform)
    if not j or j < 2 then return false end
    for k = #trip.stops, j + 1, -1 do trip.stops[k] = nil end
    trip.stops[j].dep, trip.stops[j].skip, trip.stops[j].hold = nil, nil, nil
    local left = #a.trips - a.ti
    for k = #a.trips, a.ti + 1, -1 do a.trips[k] = nil end
    if left > 0 then
        local rest = S.BuildRoute(Line.OppositePlatform(platform), trip.stops[j].arr + cvTurn:GetInt(), left)
        for _, t in ipairs(rest) do a.trips[#a.trips + 1] = t end
    end
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
    local nextTrip = a.trips[a.ti + 1]
    if trip.cur == #trip.stops and nextTrip and nextTrip.stops[1].platform == platform then
        trip = advanceTrip(a, consist.id)
        trip.stops[1].factArr = now
        return
    end

    for j = trip.cur + 1, #trip.stops do
        local s = trip.stops[j]
        if s.platform == platform then
            -- Everything between was passed without stopping
            for k = trip.cur + 1, j - 1 do
                local m = trip.stops[k]
                if not m.skip then m.missed = true; hook.Run("Dispatcher_StopMissed", consist.id, trip, m) end
            end
            local prev = trip.stops[j - 1]
            if j - 1 == trip.cur and prev.factDep and not prev.skip then learn(prev.platform, s.platform, now - prev.factDep) end

            s.factArr, s.stopError = now, stopError
            trip.cur = j
            hook.Run("Dispatcher_StopArrive", consist.id, trip, s, now - s.arr)
            if j == #trip.stops and not a.trips[a.ti + 1] then advanceTrip(a, consist.id) end
            return
        end
    end
end)

hook.Add("Dispatcher_Depart", "Dispatcher_Schedule", function(consist, st, platform)
    local a = S.Assignments[consist.id]
    if not a or a.finished then return end
    local trip = a.trips[a.ti]
    local s = trip.stops[trip.cur]
    if not s or s.platform ~= platform or not s.dep then return end
    local now = Line.Now()
    s.factDep = now
    hook.Run("Dispatcher_StopDepart", consist.id, trip, s, now - s.dep)
end)

-- Detect passing a planned stop without stopping, right when it happens:
-- the head left the platform's stop mark behind and the train never stopped.
timer.Create("Dispatcher_ScheduleWatch", 0.5, 0, function()
    for cid, a in pairs(S.Assignments) do
        if a.finished then continue end
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
