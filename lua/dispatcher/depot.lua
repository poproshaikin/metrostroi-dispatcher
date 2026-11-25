--------------------------------------------------------------------------------
-- Dispatcher.Depot — depot tracks (канавы / пути отстоя).
--
-- Depot tracks are usually NOT in Metrostroi's track data (on Nekrasovka they
-- aren't), so a depot track is a straight segment in the world between two
-- marks: start (A) and end (B), set in game with !канава <путь> начало|конец.
-- The cab end of the driven wagon is the reference point when marking.
--
-- A consist is "on" a track when both its ends are on the segment (±DEPOT_TOL
-- along it, < LATERAL from its axis). Events reuse the Line hooks:
--   Dispatcher_Arrive (consist, nil, track)            whole train on the track, stopped
--   Dispatcher_Depart (consist, nil, track, moveTime)  moved and left it
-- Track objects are Platform-like: depot = true, key, name, title, station = Line.DepotStation.
--
-- Also learns where the depot exits to / is entered from (first platform after
-- leaving the depot / last one before arriving), or set with !выезд / !заезд.
--------------------------------------------------------------------------------
local Line = Dispatcher.Line
local D = Dispatcher.Depot or {}
Dispatcher.Depot = D

local U2M       = 0.01905
local DEPOT_TOL = 5       -- m along the track outside the marks still counted
local LATERAL   = 80      -- units (~1.5 m) from the track axis
local VERTICAL  = 120     -- units

local FILE = "dispatcher/depot_" .. game.GetMap():lower() .. ".json"

Line.DepotStation = Line.DepotStation or { id = 0, name = "Депо", order = 0, platforms = {} }
D.Objs = D.Objs or {}   -- [name] = track object (identity kept across rebuilds)

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------
local function vec(t) return t and Vector(t[1], t[2], t[3]) end
local function arr(v) return { math.Round(v.x, 2), math.Round(v.y, 2), math.Round(v.z, 2) } end

function D.Data()
    if not D._data then
        D._data = util.JSONToTable(file.Read(FILE, "DATA") or "") or {}
        D._data.tracks = D._data.tracks or {}
        -- tracks from the map config come first, saved ones override by name
        for _, t in ipairs((Dispatcher.MapConfig or {}).depotTracks or {}) do
            local found
            for _, s in ipairs(D._data.tracks) do if s.name == t.name then found = true end end
            if not found then table.insert(D._data.tracks, table.Copy(t)) end
        end
        D._data.exit = D._data.exit or (Dispatcher.MapConfig or {}).depotExit
        D._data.entry = D._data.entry or (Dispatcher.MapConfig or {}).depotEntry
    end
    return D._data
end

local function save()
    file.CreateDir("dispatcher")
    file.Write(FILE, util.TableToJSON(D._data, true))
    D._version = (D._version or 0) + 1
end

local built, builtVersion = {}, -1
function D.Tracks()
    if builtVersion == D._version and builtVersion ~= -1 then return built end
    built = {}
    for _, def in ipairs(D.Data().tracks) do
        local a, b = vec(def.a), vec(def.b)
        local t = D.Objs[def.name] or {}
        D.Objs[def.name] = t
        t.depot, t.name, t.key = true, def.name, "depot:" .. def.name
        t.title = "Депо, путь " .. def.name
        t.station, t.index = Line.DepotStation, 0
        t.a, t.b = a, b
        t.complete = a ~= nil and b ~= nil
        if t.complete then
            local d = b - a
            t.len = d:Length()
            t.length = t.len * U2M
            t.u = d:GetNormalized()
            t.mid = (a + b) / 2
        end
        built[#built + 1] = t
    end
    builtVersion = D._version or 0
    D._version = builtVersion
    return built
end

function D.Track(name)
    for _, t in ipairs(D.Tracks()) do if t.name == name then return t end end
end

-- Mark the start ("a") or end ("b") of depot track `name` at the cab end of `consist`.
function D.Mark(consist, name, which)
    local st = Line.GetState(consist)
    if not st then return nil, "сядь в кабину" end
    if not st.stopped then return nil, "остановись" end
    local data = D.Data()
    local def
    for _, t in ipairs(data.tracks) do if t.name == name then def = t end end
    if not def then def = { name = name }; table.insert(data.tracks, def) end
    def[which] = arr(D.CabEnd(st.head))
    save()
    return def
end

function D.Remove(name)
    local data = D.Data()
    for i = #data.tracks, 1, -1 do
        if data.tracks[i].name == name then table.remove(data.tracks, i); save(); return true end
    end
    return false
end

function D.SetExit(platform)  D.Data().exit = platform and platform.key; save() end
function D.SetEntry(platform) D.Data().entry = platform and platform.key; save() end

local function platformByKey(key)
    if not key then return end
    for _, st in ipairs(Line.GetStations()) do
        for _, pl in pairs(st.platforms) do if pl.key == key then return pl end end
    end
end
function D.Exit()  return platformByKey(D.Data().exit) end
function D.Entry() return platformByKey(D.Data().entry) end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------
-- World position of the cab end of the head wagon (same reference as Line)
function D.CabEnd(head)
    local cabSign = 1
    if IsValid(head.DriverSeat) then
        cabSign = head:WorldToLocal(head.DriverSeat:GetPos()).x >= 0 and 1 or -1
    end
    local fx = cabSign > 0 and head:OBBMaxs().x or head:OBBMins().x
    if math.abs(fx) < 300 or math.abs(fx) > 700 then fx = 470 * cabSign end
    return head:LocalToWorld(Vector(fx, 0, 0))
end

-- Along-track coordinate (metres from A) of a point, or nil if it is off this track
local function project(t, p)
    local rel = p - t.a
    local along = rel:Dot(t.u)
    local side = rel - t.u * along
    if math.abs(side.z) > VERTICAL then return end
    side.z = 0
    if side:Length() > LATERAL then return end
    return along * U2M
end

-- Span of the consist along track t: lo, hi (metres from A), or nil if any end is off it
local function span(consist, t)
    local lo, hi
    for _, w in ipairs(consist.wagons) do
        for _, ex in ipairs({ w:OBBMins().x, w:OBBMaxs().x }) do
            local x = project(t, w:LocalToWorld(Vector(ex, 0, 0)))
            if not x then return end
            lo = lo and math.min(lo, x) or x
            hi = hi and math.max(hi, x) or x
        end
    end
    return lo, hi
end

-- { track, full, lo, hi } for the depot track the consist is on (wholly or partly)
function D.State(consist)
    local tracks = D.Tracks()
    if #tracks == 0 or not consist then return end
    local pos = consist.wagons[1]:GetPos()
    local best
    for _, t in ipairs(tracks) do
        if not t.complete then continue end
        if pos:Distance(t.mid) > t.len / 2 + 300 / U2M then continue end
        local lo, hi = span(consist, t)
        if lo and hi >= -DEPOT_TOL and lo <= t.length + DEPOT_TOL then
            local full = lo >= -DEPOT_TOL and hi <= t.length + DEPOT_TOL
            if not best or (full and not best.full) then best = { track = t, full = full, lo = lo, hi = hi } end
        end
    end
    return best
end

-- Is anything (other than `except`) standing on track t?
function D.Occupied(t, except)
    for _, c in ipairs(Line.GetConsists()) do
        if except and c.id == except.id then continue end
        local s = D.State(c)
        if s and s.track == t then return true end
    end
    return false
end

-- A free complete track, preferring `prefer` if it is free
function D.FreeTrack(except, prefer)
    if prefer and prefer.complete and not D.Occupied(prefer, except) then return prefer end
    local free = {}
    for _, t in ipairs(D.Tracks()) do
        if t.complete and not D.Occupied(t, except) then free[#free + 1] = t end
    end
    return free[math.random(math.max(#free, 1))] or prefer
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local nextTick = 0
hook.Add("Think", "Dispatcher_DepotEvents", function()
    if CurTime() < nextTick then return end
    nextTick = CurTime() + 0.5
    if #D.Tracks() == 0 then return end

    for _, c in ipairs(Line.GetConsists()) do
        local mem = Line.GetMemory(c)
        local s = D.State(c)
        local head = c.wagons[1]
        local speed = 0
        for _, w in ipairs(c.wagons) do speed = math.max(speed, math.abs(w.Speed or 0)) end
        local stopped = speed < 0.5

        if s and s.full and stopped and mem.depotArrived ~= s.track then
            mem.depotArrived, mem.depotMove = s.track, nil
            mem.depotState = s
            -- learn where the depot is entered from
            if not D.Data().entry and mem.passed then D.SetEntry(mem.passed) end
            hook.Run("Dispatcher_Arrive", c, nil, s.track, nil)
        elseif mem.depotArrived then
            if stopped then
                mem.depotMove = nil
            elseif not mem.depotMove and speed > 1 then
                mem.depotMove = Line.Now()
            end
            if mem.depotMove and not (s and s.full and s.track == mem.depotArrived) then
                local t = mem.depotArrived
                mem.depotArrived, mem.fromDepot = nil, t
                hook.Run("Dispatcher_Depart", c, nil, t, mem.depotMove)
                mem.depotMove = nil
            end
        end
    end
end)

-- learn where the depot exits to
hook.Add("Dispatcher_Arrive", "Dispatcher_DepotLearn", function(consist, st, platform)
    if platform.depot or platform.siding then return end
    local mem = Line.GetMemory(consist)
    if mem.fromDepot then
        if not D.Data().exit then D.SetExit(platform) end
        mem.fromDepot = nil
    end
end)

--------------------------------------------------------------------------------
-- Markers for the client (!метки)
--------------------------------------------------------------------------------
util.AddNetworkString("dispatcher_marks")

function D.SendMarks(ply)
    local marks = {}
    for _, t in ipairs(D.Tracks()) do
        if t.a then marks[#marks + 1] = { t.a, "Путь " .. t.name .. ": начало", 1 } end
        if t.b then marks[#marks + 1] = { t.b, "Путь " .. t.name .. ": конец", 2 } end
    end
    for _, sd in ipairs(Line.GetSidings()) do
        local pos = Metrostroi.GetTrackPosition(sd.path, sd.xEnd)
        if pos then marks[#marks + 1] = { pos, sd.name, 3 } end
    end
    for _, st in ipairs(Line.GetStations()) do
        for _, pl in pairs(st.platforms) do
            local pos = pl.path and Metrostroi.GetTrackPosition(pl.path, pl.xEnd)
            if pos then marks[#marks + 1] = { pos, "Знак: " .. st.name .. " (путь " .. pl.index .. ")", 4 } end
        end
    end
    net.Start("dispatcher_marks")
    net.WriteUInt(#marks, 12)
    for _, m in ipairs(marks) do
        net.WriteVector(m[1]); net.WriteString(m[2]); net.WriteUInt(m[3], 3)
    end
    net.Send(ply)
end

net.Receive("dispatcher_marks", function(_, ply) D.SendMarks(ply) end)
