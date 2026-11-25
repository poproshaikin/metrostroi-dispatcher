--------------------------------------------------------------------------------
-- Dispatcher.Line — clean facade over Metrostroi's rail network.
--
-- Everything that knows about Metrostroi internals (paths, nodes, wagons,
-- platforms entities) lives here. Other modules work only with:
--   Station  { id, name, order, platforms = { [idx] = Platform } }
--   Platform { station, index, path, xStart, xEnd, dir, length, terminal, ent }
--   Consist  { id, wagons = {...} }
--   State    (see Line.GetState)
--
-- Units: distances in metres along the track, speed in km/h.
--
-- Events (hook.Run), fired for consists that have a driver:
--   Dispatcher_Arrive (consist, state, platform, stopError)  stopped at a platform
--                     (or in a siding: platform.siding == true)
--                     stopError: metres to the stop mark (+ short, - overrun)
--   Dispatcher_Depart (consist, state, platform, departTime) left the platform;
--                     departTime: Line.Now() when the train started moving
--------------------------------------------------------------------------------
Dispatcher = Dispatcher or {}
local Line = Dispatcher.Line or {}
Dispatcher.Line = Line

local U2M          = 0.01905  -- source units -> metres
local CAB_FRONT    = 470      -- local X of the wagon's cab end, units
local STOP_OVERRUN = 15       -- metres past the stop mark still counted "at platform"
local STOP_SPEED   = 0.5      -- km/h, below this the train is "stopped"
local SIDING_ACCEPT = 80      -- metres short of a siding's stop mark still counted "in the siding"

--------------------------------------------------------------------------------
-- Stations
--------------------------------------------------------------------------------
local cache = {}

local function stationName(id)
    local cfg = Dispatcher.MapConfig
    if cfg and cfg.names and cfg.names[id] then return cfg.names[id] end
    local sc = Metrostroi.StationConfigurations and Metrostroi.StationConfigurations[id]
    if sc and sc.names and sc.names[1] then return sc.names[1] end
    return tostring(id)
end

local function build()
    local src = Metrostroi.Stations
    if not src then return false end
    if cache.src == src and cache.stations and cache.sidingsVersion == Line._sidingsVersion then return true end

    -- Station/Platform tables keep their identity across rebuilds and Lua reloads,
    -- so trips and orders holding them stay valid (they compare platforms with ==).
    Line._objs = Line._objs or { stations = {}, platforms = {} }
    local objs = Line._objs

    local stations, byId, platforms = {}, {}, {}
    for id, plats in pairs(src) do
        if not isnumber(id) then continue end
        local st = objs.stations[id] or {}
        objs.stations[id] = st
        st.id, st.name, st.platforms = id, stationName(id), {}
        for idx, p in pairs(plats) do
            local node = p.node_end or p.node_start
            if not node then continue end
            local key = id .. "/" .. idx
            local pl = objs.platforms[key] or {}
            objs.platforms[key] = pl
            pl.station  = st
            pl.index    = idx
            pl.path     = node.path
            pl.xStart   = p.x_start
            pl.dir      = p.x_end > p.x_start      -- trains moving towards +x use it
            -- stop mark (head of the train): platform end, moved by a calibration if any
            pl.xEndRaw  = p.x_end
            pl.xEnd     = p.x_end + (pl.dir and 1 or -1) * Line.StopMarkOffset(key)
            pl.length   = p.length
            pl.terminal = IsValid(p.ent) and p.ent.PlatformLast or false
            pl.ent      = p.ent
            pl.node     = p.node_end               -- opaque, for Line.TravelTime only
            pl.key      = key                      -- stable id, for saving
            pl.title    = st.name                  -- what to call it in messages
            st.platforms[idx] = pl
            platforms[#platforms + 1] = pl
        end
        stations[#stations + 1] = st
        byId[id] = st
    end
    table.sort(stations, function(a, b) return a.id < b.id end)
    for i, st in ipairs(stations) do st.order = i end

    -- Which way along the station list does each platform index go?
    -- A terminal platform at the first station means that index runs "down".
    local orderDir = {}
    for _, pl in ipairs(platforms) do
        if pl.terminal then
            orderDir[pl.index] = (pl.station.order == 1) and -1 or 1
        end
    end

    -- Sidings (turnback dead ends): Platform-like stop marks off the station list.
    --   siding = true, name, station (parent), from (arrival platform index),
    --   opposite (departure platform after the cab change)
    local sidings = {}
    for _, def in ipairs(Line.SidingDefs()) do
        local st = byId[def.station]
        local path = Metrostroi.Paths and Metrostroi.Paths[def.path]
        if not st or not path then continue end
        local node
        for _, n in ipairs(path) do
            if n.x <= def.x then node = n else break end
        end
        local key = "siding:" .. def.name
        local sd = objs.platforms[key] or {}
        objs.platforms[key] = sd
        local s = def.dir and 1 or -1
        sd.siding   = true
        sd.name     = def.name
        sd.title    = def.name
        sd.key      = key
        sd.station  = st
        sd.index    = 0
        sd.from     = def.from
        sd.opposite = st.platforms[def.from == 1 and 2 or 1]
        sd.path     = path
        sd.xEnd     = def.x
        sd.xStart   = def.x - s * SIDING_ACCEPT
        sd.dir      = def.dir
        sd.length   = SIDING_ACCEPT
        sd.terminal = false
        sd.node     = node
        sidings[#sidings + 1] = sd
        platforms[#platforms + 1] = sd
    end

    cache = { src = src, stations = stations, byId = byId, platforms = platforms, orderDir = orderDir,
              sidings = sidings, sidingsVersion = Line._sidingsVersion }
    return true
end

--------------------------------------------------------------------------------
-- Stop mark calibration (!знак): where on the platform the head should stop,
-- in metres along the direction of travel relative to the platform end
-- (negative = before it). Per platform, or a default for the whole map.
--------------------------------------------------------------------------------
local MARKS_FILE = "dispatcher/stopmarks_" .. game.GetMap():lower() .. ".json"

local function marks()
    if not Line._stopMarks then
        Line._stopMarks = util.JSONToTable(file.Read(MARKS_FILE, "DATA") or "") or {}
    end
    return Line._stopMarks
end

function Line.StopMarkOffset(key)
    local m = marks()
    local cfg = (Dispatcher.MapConfig or {}).stopMarks or {}
    return m[key] or cfg[key] or m.default or cfg.default or 0
end

-- Calibrate with the train standing at the real stop sign of its platform.
-- all = true: use this offset as the default for every platform without its own.
function Line.CalibrateStopMark(consist, all)
    local st = Line.GetState(consist)
    if not st or not st.at or st.at.siding then return nil, "встань у знака остановки на платформе" end
    if not st.stopped then return nil, "остановись" end
    local pl = st.at
    local offset = (st.x - pl.xEndRaw) * (pl.dir and 1 or -1)
    local m = marks()
    if all then m.default = offset else m[pl.key] = offset end
    file.CreateDir("dispatcher")
    file.Write(MARKS_FILE, util.TableToJSON(m, true))
    Line._sidingsVersion = (Line._sidingsVersion or 0) + 1   -- rebuild platforms
    return offset, pl
end

function Line.ResetStopMarks()
    Line._stopMarks = {}
    file.Delete(MARKS_FILE)
    Line._sidingsVersion = (Line._sidingsVersion or 0) + 1
end

--------------------------------------------------------------------------------
-- Sidings: marked in game (!тупик) and saved per map, or listed in the map config
--------------------------------------------------------------------------------
local SIDINGS_FILE = "dispatcher/sidings_" .. game.GetMap():lower() .. ".json"

function Line.SidingDefs()
    if not Line._sidingDefs then
        Line._sidingDefs = util.JSONToTable(file.Read(SIDINGS_FILE, "DATA") or "") or {}
    end
    -- map config first; a saved siding with the same name replaces it
    local list, byName = {}, {}
    local function add(d)
        if byName[d.name] then list[byName[d.name]] = d else list[#list + 1] = d; byName[d.name] = #list end
    end
    for _, d in ipairs((Dispatcher.MapConfig or {}).sidings or {}) do add(d) end
    for _, d in ipairs(Line._sidingDefs) do add(d) end
    return list
end

local function saveSidings()
    file.CreateDir("dispatcher")
    file.Write(SIDINGS_FILE, util.TableToJSON(Line._sidingDefs, true))
    Line._sidingsVersion = (Line._sidingsVersion or 0) + 1
end

function Line.GetSidings()
    if not build() then return {} end
    return cache.sidings
end

-- Siding where a train that arrived at `platform` goes for the cab change.
function Line.SidingFor(platform)
    if not build() or not platform or platform.siding then return end
    for _, sd in ipairs(cache.sidings) do
        if sd.station == platform.station and sd.from == platform.index then return sd end
    end
end

-- Mark the current cab position of `consist` as a siding stop mark.
-- Returns the siding definition, or nil + error text.
function Line.AddSiding(consist, name)
    local st = Line.GetState(consist)
    if not st or not st.onTrack then return nil, "поезд не на путях" end
    if not st.stopped then return nil, "остановись" end
    if st.at and not st.at.siding then return nil, "ты на платформе, а не в тупике" end
    local from = Line.GetMemory(consist).passed
    if not from or from.siding then return nil, "не знаю, от какой станции этот тупик: сначала проедь её платформу" end
    name = (name and name ~= "") and name or ("Тупик ст. " .. from.station.name)
    Line._sidingDefs = Line._sidingDefs or {}
    for i = #Line._sidingDefs, 1, -1 do
        if Line._sidingDefs[i].name == name then table.remove(Line._sidingDefs, i) end
    end
    local def = { name = name, station = from.station.id, from = from.index, path = st.path.id, x = st.x, dir = st.dirPlus }
    table.insert(Line._sidingDefs, def)
    saveSidings()
    return def
end

function Line.RemoveSiding(name)
    Line.SidingDefs()
    for i = #Line._sidingDefs, 1, -1 do
        if Line._sidingDefs[i].name == name then
            table.remove(Line._sidingDefs, i)
            saveSidings()
            return true
        end
    end
    return false
end

-- Ordered list of stations (by station index). Empty table if not ready yet.
function Line.GetStations()
    if not build() then return {} end
    return cache.stations
end

function Line.GetStation(id)
    if not build() then return end
    return cache.byId[id]
end

-- +1: trains on this platform index go up the station list, -1: down.
function Line.OrderDir(platformIndex)
    build()
    return (cache.orderDir and cache.orderDir[platformIndex]) or (platformIndex == 1 and 1 or -1)
end

-- Next platform in line order after `platform` (same platform index). nil at a terminal.
function Line.NextPlatform(platform)
    if not build() or not platform then return end
    local st = cache.stations[platform.station.order + Line.OrderDir(platform.index)]
    return st and st.platforms[platform.index]
end

-- Lowercase for Cyrillic too (string.lower only handles ASCII)
function Line.Lower(s)
    s = string.lower(s)
    return (s:gsub("\208([\144-\175])", function(c)          -- А..Я
        local b = c:byte() + 32
        if b < 176 then return "\208" .. string.char(b) end   -- А..П -> а..п
        return "\209" .. string.char(b - 64)                  -- Р..Я -> р..я
    end):gsub("\208\129", "\209\145"))                        -- Ё -> ё
end

-- Station by id or name prefix ("окс", "108")
function Line.FindStation(query)
    if not query or query == "" then return end
    local q = Line.Lower(query)
    for _, st in ipairs(Line.GetStations()) do
        if tostring(st.id) == q or string.find(Line.Lower(st.name), q, 1, true) == 1 then return st end
    end
end

-- Line time in seconds: the same clock the station clocks show (UTC-based, as
-- Metrostroi draws them with os.date("!...")). Use Line.FormatTime to print.
function Line.Now()
    return Metrostroi.GetSyncTime and Metrostroi.GetSyncTime() or os.time()
end

function Line.FormatTime(t, withSeconds)
    return os.date(withSeconds == false and "!%H:%M" or "!%H:%M:%S", math.floor(t))
end

-- The other platform of the same station (where a train departs after turnover).
function Line.OppositePlatform(platform)
    if not platform then return end
    if platform.siding then return platform.opposite end
    return platform.station.platforms[platform.index == 1 and 2 or 1]
end

-- Distance between two stop marks in metres, if both are on the same track path.
function Line.Distance(a, b)
    if not a or not b or a.path ~= b.path then return end
    return math.abs(b.xEnd - a.xEnd)
end

-- Normative run time stop mark -> stop mark, seconds (Metrostroi's own estimate:
-- 82% of the ARS limit on every section + 25 s for acceleration/braking).
-- nil if it can't be computed (different paths, no ARS data).
local travelCache = setmetatable({}, { __mode = "k" })
function Line.TravelTime(a, b)
    if not a or not b or not a.node or not b.node or a.path ~= b.path then return end
    travelCache[a] = travelCache[a] or {}
    local c = travelCache[a][b]
    if c == nil then
        local ok, t = pcall(Metrostroi.GetTravelTime, a.node, b.node)
        c = (ok and isnumber(t) and t > 0) and (t + 25) or false
        travelCache[a][b] = c
    end
    return c or nil
end

--------------------------------------------------------------------------------
-- Consists
--------------------------------------------------------------------------------
local function isWagon(e)
    return IsValid(e) and (e.Base == "gmod_subway_base") and not e.NoTrain
end

local consistCache, consistTime = {}, -1

-- All consists on the map. A consist = electrically connected wagons.
function Line.GetConsists()
    if consistTime == CurTime() then return consistCache end
    local seen, list = {}, {}
    for _, e in ipairs(ents.FindByClass("gmod_subway_*")) do
        if not isWagon(e) or seen[e] then continue end
        local wagons = {}
        for _, w in ipairs(e.WagonList or { e }) do
            if isWagon(w) and not seen[w] then seen[w] = true; wagons[#wagons + 1] = w end
        end
        if not seen[e] then seen[e] = true; wagons[#wagons + 1] = e end
        local id = math.huge
        for _, w in ipairs(wagons) do id = math.min(id, w:EntIndex()) end
        list[#list + 1] = { id = id, wagons = wagons }
    end
    consistCache, consistTime = list, CurTime()
    return list
end

function Line.GetConsist(id)
    for _, c in ipairs(Line.GetConsists()) do
        if c.id == id then return c end
    end
end

-- Consist the player drives / sits in / stands on.
function Line.GetPlayerConsist(ply)
    local veh = ply:InVehicle() and ply:GetVehicle()
    local wagon = IsValid(veh) and veh:GetParent()
    if not isWagon(wagon) then wagon = ply:GetGroundEntity() end
    if not isWagon(wagon) then return end
    for _, c in ipairs(Line.GetConsists()) do
        for _, w in ipairs(c.wagons) do
            if w == wagon then return c end
        end
    end
end

-- Head wagon: the one with a driver, else a cab wagon at an end of the consist.
local function findHead(consist)
    for _, w in ipairs(consist.wagons) do
        local drv = w.GetDriver and w:GetDriver()
        if IsValid(drv) then return w, drv end
    end
    for _, w in ipairs(consist.wagons) do
        if IsValid(w.DriverSeat) and (not IsValid(w.FrontTrain) or not IsValid(w.RearTrain)) then return w end
    end
    return consist.wagons[1]
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
-- Per consist (not per head wagon: the head changes when the driver changes cabs)
Line._memory = Line._memory or {}
local memory = Line._memory

function Line.GetMemory(consist)
    local mem = memory[consist.id] or {}
    memory[consist.id] = mem
    return mem
end

local function locate(path, x, dirPlus)
    local s = dirPlus and 1 or -1
    local at, stop, best
    for _, pl in ipairs(cache.platforms) do
        if pl.path ~= path or pl.dir ~= dirPlus then continue end
        local toEnd     = (pl.xEnd - x) * s
        local fromStart = (x - pl.xStart) * s
        if toEnd < -STOP_OVERRUN then continue end
        if fromStart >= 0 and (not at or at.siding) then at = pl end   -- a real platform wins
        if not best or toEnd < best then best, stop = toEnd, pl end
    end
    return at, stop, best
end

--[[ Line.GetState(consist) ->
{
    consist, head, driver,          -- head wagon and its driver (Player or nil)
    wagons      = 6,
    onTrack     = true,             -- false: off the rail network (depot props, etc.)
    path, x,                        -- raw track position of the cab end (avoid using outside line.lua)
    dirPlus     = true,             -- raw direction, cab-forward
    speed       = 54.2,             -- km/h
    stopped     = false,
    doors       = { left = false, right = true },
    at          = Platform | nil,   -- platform the head is currently along
    stop        = Platform | nil,   -- next stop mark ahead (may be `at`)
    distToStop  = 312.5 | nil,      -- metres to `stop` mark; nil if unknown (other track path)
    last        = Platform | nil,   -- last platform the train stopped at
}
]]
function Line.GetState(consist)
    if not build() or not consist then return end
    local head, driver = findHead(consist)
    if not IsValid(head) then return end

    -- Which end is the cab: driver seat local X sign
    local cabSign = 1
    if IsValid(head.DriverSeat) then
        cabSign = head:WorldToLocal(head.DriverSeat:GetPos()).x >= 0 and 1 or -1
    end

    local st = {
        consist = consist,
        head    = head,
        driver  = driver,
        wagons  = #consist.wagons,
        speed   = math.abs(head.Speed or 0),
        doors   = { left = head.LeftDoorsOpen == true, right = head.RightDoorsOpen == true },
    }
    st.stopped = st.speed < STOP_SPEED

    local mem = Line.GetMemory(consist)
    st.last = mem.last

    -- Near switches / parallel tracks several track paths can be under the cab.
    -- Pick: the one along a platform > the one we were on before > the nearest.
    -- Cab end from the wagon's own bounds (differs per series), not a constant
    local fx = cabSign > 0 and head:OBBMaxs().x or head:OBBMins().x
    if math.abs(fx) < 300 or math.abs(fx) > 700 then fx = CAB_FRONT * cabSign end   -- odd bounds: fallback
    local front = head:LocalToWorld(Vector(fx, 0, 0))
    local positions = Metrostroi.GetPositionOnTrack(front, head:GetAngles())
    st.onTrack = positions[1] ~= nil
    if not st.onTrack then return st end

    local pos, at, stop, dist
    for i, p in ipairs(positions) do
        -- distance = units from the track axis (incl. height of the body); a parallel
        -- track is ~200 units away, a switch branch that we are actually on is close
        if p.distance > positions[1].distance + 100 then break end
        local dirPlus = (p.forward == (cabSign > 0))
        local a, s, d = locate(p.path, p.x, dirPlus)
        local score = (a and 3 or 0) + (p.path == mem.path and 2 or 0) + (s and 1 or 0)
        if not pos or score > pos.score then
            pos = { p = p, dirPlus = dirPlus, score = score }
            at, stop, dist = a, s, d
        end
    end
    if not pos then
        local p = positions[1]
        pos = { p = p, dirPlus = (p.forward == (cabSign > 0)) }
        at, stop, dist = locate(p.path, p.x, pos.dirPlus)
    end
    st.path, st.x, st.dirPlus = pos.p.path, pos.p.x, pos.dirPlus
    st.trackCandidates = #positions
    mem.path = st.path
    st.at = at
    if at and not at.siding then mem.passed = at end   -- passed through, stopped or not
    if stop then
        st.stop, st.distToStop = stop, dist
    elseif mem.passed then
        -- The next platform is on another track path (after a switch / path split):
        -- we know which one by line order, but not the exact distance.
        st.stop = Line.NextPlatform(mem.passed)
    end
    return st
end

function Line.GetPlayerState(ply)
    return Line.GetState(Line.GetPlayerConsist(ply))
end

--------------------------------------------------------------------------------
-- Arrive / depart events
--------------------------------------------------------------------------------
local nextTick = 0
hook.Add("Think", "Dispatcher_LineEvents", function()
    if CurTime() < nextTick then return end
    nextTick = CurTime() + 0.25
    if not build() then return end

    for _, c in ipairs(Line.GetConsists()) do
        local st = Line.GetState(c)
        if not st or not IsValid(st.driver) then continue end
        local mem = Line.GetMemory(c)

        if st.at and st.stopped and mem.arrived ~= st.at then
            mem.arrived, mem.last, mem.moveStart, mem.arrivedHead = st.at, st.at, nil, st.head
            local err = st.stop == st.at and st.distToStop or nil
            hook.Run("Dispatcher_Arrive", c, st, st.at, err)
        elseif mem.arrived then
            -- Departure time = when the train started moving, not when the head
            -- cleared the platform (that is 15+ m and several seconds later).
            -- Creeping up to the stop mark and stopping again resets it.
            if st.stopped then
                mem.moveStart = nil
            elseif not mem.moveStart and st.speed > 1 then
                mem.moveStart = Line.Now()
            end
            local pl = mem.arrived
            -- A siding is left the other way round, after a cab change (the head is
            -- now the other end of the train): moving at all = departed.
            -- A platform: the head has left it AND the train has moved (a cab change
            -- while standing at a platform must not count as a departure).
            local departed
            if pl.siding then
                -- creeping up to the buffer with the same cab is not a departure
                departed = mem.moveStart ~= nil and st.head ~= mem.arrivedHead
            else
                departed = st.at ~= pl and mem.moveStart ~= nil
            end
            if departed then
                mem.arrived = nil
                hook.Run("Dispatcher_Depart", c, st, pl, mem.moveStart)
                mem.moveStart = nil
            end
        end
    end
end)
