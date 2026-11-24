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
--                     stopError: metres to the stop mark (+ short, - overrun)
--   Dispatcher_Depart (consist, state, platform)             left the platform
--------------------------------------------------------------------------------
Dispatcher = Dispatcher or {}
local Line = Dispatcher.Line or {}
Dispatcher.Line = Line

local U2M          = 0.01905  -- source units -> metres
local CAB_FRONT    = 470      -- local X of the wagon's cab end, units
local STOP_OVERRUN = 15       -- metres past the stop mark still counted "at platform"
local STOP_SPEED   = 0.5      -- km/h, below this the train is "stopped"

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
    if cache.src == src and cache.stations then return true end

    local stations, byId, platforms = {}, {}, {}
    for id, plats in pairs(src) do
        if not isnumber(id) then continue end
        local st = { id = id, name = stationName(id), platforms = {} }
        for idx, p in pairs(plats) do
            local node = p.node_end or p.node_start
            if not node then continue end
            local pl = {
                station  = st,
                index    = idx,
                path     = node.path,
                xStart   = p.x_start,
                xEnd     = p.x_end,                 -- stop mark (head of the train)
                dir      = p.x_end > p.x_start,     -- trains moving towards +x use it
                length   = p.length,
                terminal = IsValid(p.ent) and p.ent.PlatformLast or false,
                ent      = p.ent,
            }
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

    cache = { src = src, stations = stations, byId = byId, platforms = platforms, orderDir = orderDir }
    return true
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
local memory = setmetatable({}, { __mode = "k" })  -- per head wagon: lastPlatform etc.

local function locate(path, x, dirPlus)
    local s = dirPlus and 1 or -1
    local at, stop, best
    for _, pl in ipairs(cache.platforms) do
        if pl.path ~= path or pl.dir ~= dirPlus then continue end
        local toEnd     = (pl.xEnd - x) * s
        local fromStart = (x - pl.xStart) * s
        if toEnd < -STOP_OVERRUN then continue end
        if fromStart >= 0 then at = pl end
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

    local mem = memory[head] or {}
    memory[head] = mem
    st.last = mem.last

    local front = head:LocalToWorld(Vector(CAB_FRONT * cabSign, 0, 0))
    local pos = Metrostroi.GetPositionOnTrack(front, head:GetAngles())[1]
    st.onTrack = pos ~= nil
    if not pos then return st end

    st.path, st.x = pos.path, pos.x
    st.dirPlus = (pos.forward == (cabSign > 0))

    local at, stop, dist = locate(pos.path, pos.x, st.dirPlus)
    st.at = at
    if at then mem.passed = at end   -- passed through, stopped or not
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
        local mem = memory[st.head]

        if st.at and st.stopped and mem.arrived ~= st.at then
            mem.arrived, mem.last = st.at, st.at
            local err = st.stop == st.at and st.distToStop or nil
            hook.Run("Dispatcher_Arrive", c, st, st.at, err)
        elseif mem.arrived and st.at ~= mem.arrived then
            local pl = mem.arrived
            mem.arrived = nil
            hook.Run("Dispatcher_Depart", c, st, pl)
        end
    end
end)
