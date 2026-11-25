--------------------------------------------------------------------------------
-- Dispatcher.Spawn — put a broken (cold, unmanned) train on the track ahead of
-- a train, for the "take the failed train to the depot" scenario.
--
--   SP.SpawnBrokenAhead(consist, opts) -> info | nil, reason
--     opts.minAhead / maxAhead  metres ahead of the cab (default 400 / 3500)
--     opts.station = true       place it at the next platform (stop mark as anchor)
--
-- The broken train is as long as the rescuing one (same number of cars), of a
-- series picked from SP.Families: any older series (the older, the rarer) or a
-- slightly newer similar one. It is spawned "fully started" with a traction
-- drive failure (SP.MakeBroken). Its spot is straight, free of switches and trains.
--------------------------------------------------------------------------------
local Line = Dispatcher.Line
local SP = Dispatcher.Spawn or {}
Dispatcher.Spawn = SP

local U2M = 0.01905

-- Series that couple with each other (standard Metrostroi coupler). Head car,
-- intermediate car, year (approximate start of production / modernisation).
-- Яуза (81-720), Юбилейный (81-722) and Ока (81-760) are left out on purpose.
SP.Families = {
    { head = "gmod_subway_81-702",       interim = "gmod_subway_81-702_int",  year = 1955, name = "81-702 (Д)" },
    { head = "gmod_subway_81-703",       interim = "gmod_subway_81-703_int",  year = 1959, name = "81-703 (Е)" },
    { head = "gmod_subway_81-502",       interim = "gmod_subway_81-501",      year = 1966, name = "81-502 (Ема)" },
    { head = "gmod_subway_81-502k",      interim = "gmod_subway_81-501k",     year = 1966, name = "81-502К" },
    { head = "gmod_subway_em508",        interim = "gmod_subway_em509",       year = 1969, name = "Ем-508" },
    { head = "gmod_subway_ezh",          interim = "gmod_subway_ezh1",        year = 1970, name = "Еж" },
    { head = "gmod_subway_ezh3",         interim = "gmod_subway_em508t",      year = 1973, name = "Еж3" },
    { head = "gmod_subway_81-717_mvm",   interim = "gmod_subway_81-714_mvm",  year = 1976, name = "81-717 (МВМ)" },
    { head = "gmod_subway_81-717_lvz",   interim = "gmod_subway_81-714_lvz",  year = 1978, name = "81-717 (ЛВЗ)" },
    { head = "gmod_subway_81-718",       interim = "gmod_subway_81-719",      year = 1991, name = "81-718 (ТИСУ)" },
    { head = "gmod_subway_81-717_2",     interim = "gmod_subway_81-714_mvm",  year = 1993, name = "81-717.2" },
    { head = "gmod_subway_81-717_5m",    interim = "gmod_subway_81-714_5m",   year = 1993, name = "81-717.5М" },
    { head = "gmod_subway_81-717_5a",    interim = "gmod_subway_81-714_5a",   year = 1995, name = "81-717.5А" },
    { head = "gmod_subway_ezh3ru1",      interim = "gmod_subway_em508tru1",   year = 1996, name = "Еж3 РУ1" },
    { head = "gmod_subway_81-7175p",     interim = "gmod_subway_81-7145p",    year = 1999, name = "81-717.5П" },
    { head = "gmod_subway_81-540_1",     interim = "gmod_subway_81-541_1",    year = 2004, name = "81-540.1" },
    { head = "gmod_subway_81-540_2_lvz", interim = "gmod_subway_81-714_lvz",  year = 2006, name = "81-540.2 (ЛВЗ)" },
    { head = "gmod_subway_81-540_2k",    interim = "gmod_subway_81-541_2k",   year = 2006, name = "81-540.2К" },
    { head = "gmod_subway_81-540_8",     interim = "gmod_subway_81-541_8",    year = 2008, name = "81-540.8" },
    { head = "gmod_subway_81-717_6",     interim = "gmod_subway_81-714_6",    year = 2009, name = "81-717.6" },
}

local function installed(class) return scripted_ents.GetStored(class) ~= nil end

-- Family of a consist: by the class of its head (driven) wagon, else any wagon
function SP.FamilyOf(consist, head)
    local classes = {}
    if IsValid(head) then classes[1] = head:GetClass() end
    for _, w in ipairs(consist.wagons) do classes[#classes + 1] = w:GetClass() end
    for _, cls in ipairs(classes) do
        for _, f in ipairs(SP.Families) do if f.head == cls then return f end end
    end
    for _, cls in ipairs(classes) do
        for _, f in ipairs(SP.Families) do if f.interim == cls then return f end end
    end
end

-- Families a train of family `f` can meet broken on the line: any older series,
-- and newer ones only if close in time (similar trains, e.g. 81-718 for an 81-717).
local NEWER_MAX = 20   -- years

function SP.Compatible(f)
    local list = {}
    for _, c in ipairs(SP.Families) do
        if c.year <= f.year + NEWER_MAX and installed(c.head) and installed(c.interim) then list[#list + 1] = c end
    end
    return list
end

-- How likely a series is: the own generation most, older ones rarer and rarer
-- (halving every 5 years: 81-702 for an 81-717 is very unlikely), a bit newer
-- ones nearly as likely as the own one.
local function weight(c, f)
    if c.year <= f.year then return 10 * 0.5 ^ ((f.year - c.year) / 5) end
    return 10 * 0.9 ^ ((c.year - f.year) / 5)
end

function SP.PickFamily(f)
    local list = SP.Compatible(f)
    if #list == 0 then return end
    local total = 0
    for _, c in ipairs(list) do c._w = weight(c, f); total = total + c._w end
    local r = math.random() * total
    for _, c in ipairs(list) do
        r = r - c._w
        if r <= 0 then return c end
    end
    return list[#list]
end

--------------------------------------------------------------------------------
-- Track geometry (Metrostroi paths: arrays of nodes with x in metres)
--------------------------------------------------------------------------------
local function nodeIndex(path, x)
    local lo, hi = 1, #path
    if x <= path[1].x then return 1 end
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if path[mid].x <= x then lo = mid else hi = mid end
    end
    return lo
end

-- World position and direction (towards +x) of a point on a path
function SP.TrackAt(path, x)
    local i = nodeIndex(path, x)
    local n = path[i]
    if not n.length or n.length <= 0 then
        local p = path[i - 1] or n
        return n.pos, p.dir
    end
    local t = math.Clamp((x - n.x) / n.length, 0, 1)
    return n.pos + n.vec * t, n.dir
end

-- Horizontal bend (degrees) of the path between x1 and x2
local function bend(path, x1, x2)
    if x1 > x2 then x1, x2 = x2, x1 end
    local i1, i2 = nodeIndex(path, x1), nodeIndex(path, x2)
    local d0 = path[i1].dir
    if not d0 then return 0 end
    d0 = Vector(d0.x, d0.y, 0):GetNormalized()
    local worst = 0
    for i = i1, i2 do
        local d = path[i].dir
        if d and d:LengthSqr() > 0 then
            d = Vector(d.x, d.y, 0):GetNormalized()
            worst = math.max(worst, math.deg(math.acos(math.Clamp(d0:Dot(d), -1, 1))))
        end
    end
    return worst
end

local function switchPositions()
    local list = {}
    for _, e in ipairs(ents.FindByClass("prop_door_rotating")) do
        local n = e:GetName()
        if n:find("switch") or n:find("swh") or n:find("swit") then list[#list + 1] = e:GetPos() end
    end
    for _, e in ipairs(ents.FindByClass("gmod_track_switch")) do list[#list + 1] = e:GetPos() end
    return list
end

-- Is the stretch [x1, x2] of `path` a good place: straight, no switches, no trains
local SWITCH_CLEAR = 60 / U2M      -- units
local TRAIN_CLEAR  = 150 / U2M
local MAX_BEND     = 2             -- degrees over the whole train

local function goodStretch(path, x1, x2, switches, trainPoints)
    if x1 > x2 then x1, x2 = x2, x1 end
    if x1 < 5 or x2 > path.length - 5 then return false, "конец пути" end
    if bend(path, x1, x2) > MAX_BEND then return false, "кривая" end
    for x = x1, x2, 10 do
        local p = SP.TrackAt(path, x)
        for _, s in ipairs(switches) do
            if p:DistToSqr(s) < SWITCH_CLEAR * SWITCH_CLEAR then return false, "стрелка" end
        end
        for _, t in ipairs(trainPoints) do
            if p:DistToSqr(t) < TRAIN_CLEAR * TRAIN_CLEAR then return false, "поезд" end
        end
    end
    return true
end

-- Platforms of the path, to keep a tunnel spot off them
local function onPlatform(path, x1, x2)
    if x1 > x2 then x1, x2 = x2, x1 end
    for _, st in ipairs(Line.GetStations()) do
        for _, pl in pairs(st.platforms) do
            if pl.path == path then
                local a, b = math.min(pl.xStart, pl.xEnd) - 20, math.max(pl.xStart, pl.xEnd) + 20
                if x2 > a and x1 < b then return pl end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- The fault: traction drive failure. After the car's own think the bogeys get no
-- motor power: no traction and no electric braking. Everything else (lights,
-- control, pneumatics — so it brakes from the rescuer's brake line) works.
--------------------------------------------------------------------------------
function SP.MakeBroken(ent)
    if not IsValid(ent) or ent.DispatcherBroken then return end
    ent.DispatcherBroken = true
    local orig = ent.Think
    ent.Think = function(self, ...)
        local r = orig(self, ...)
        if self.DispatcherBroken then
            if IsValid(self.FrontBogey) then self.FrontBogey.MotorPower = 0 end
            if IsValid(self.RearBogey) then self.RearBogey.MotorPower = 0 end
        end
        return r
    end
end

-- The fault survives a save / load (Metrostroi Dedicated Save)
hook.Add("MetrostroiSave_Save", "Dispatcher_Broken", function(ext, cars, index)
    local list = {}
    for _, car in ipairs(cars) do if car.DispatcherBroken and index[car] then list[#list + 1] = index[car] end end
    if #list > 0 then ext.dispatcher_broken = list end
end)
hook.Add("MetrostroiSave_Load", "Dispatcher_Broken", function(ext, cars)
    for _, i in ipairs(ext.dispatcher_broken or {}) do SP.MakeBroken(cars[i]) end
end)

--------------------------------------------------------------------------------
-- Spawning (same steps as Metrostroi's train spawner tool)
--------------------------------------------------------------------------------
local function spawnerValue(set)
    if set[1] == "SpawnMode" then return 1 end          -- "Запущен полностью": a train that stopped on the line
    if set[3] == "List" then return 1 end
    if set[3] == "Boolean" then return set[4] == true end
    if set[3] == "Slider" then return set[7] or set[5] or 0 end
end

local function applySpawner(ENT, ent, rot, i, wagnum, settings)
    local sp = ENT.Spawner
    if not sp then return end
    for _, set in ipairs(sp) do
        local val = settings[set[1]]
        local fn = (set[3] == "List" and set[6]) or (set[3] == "Boolean" and set[5]) or (set[3] == "Slider" and set[8])
        if isfunction(fn) then
            pcall(fn, ent, val, rot, i, wagnum)
        elseif val ~= nil then
            if isnumber(val) then ent:SetNW2Int(set[1], val)
            elseif isstring(val) then ent:SetNW2String(set[1], val)
            elseif isbool(val) then ent:SetNW2Bool(set[1], val) end
        end
    end
    if sp.func then pcall(sp.func, ent, i, wagnum, rot) end
    if sp.wagfunc and ent.GenerateWagonNumber then
        pcall(ent.GenerateWagonNumber, ent, function(_, number) return sp.wagfunc(ent, i, number) end)
    end
    if ent.TrainSpawnerUpdate then pcall(ent.TrainSpawnerUpdate, ent) end
    hook.Run("MetrostroiSpawnerUpdate", ent, settings)
    if ent.UpdateTextures then pcall(ent.UpdateTextures, ent) end
end

-- Spawn `wagnum` cars of family `fam`: the head car's front at path x `xFront`,
-- facing `dirPlus` (towards +x of the path), the rest behind it.
function SP.SpawnTrain(fam, wagnum, path, xFront, dirPlus, owner)
    local ENTH = scripted_ents.Get(fam.head)
    if not ENTH then return nil, "серия не установлена" end
    local s = dirPlus and 1 or -1

    -- first car: centre half a car behind the front
    local first = ents.Create(fam.head)
    if not IsValid(first) then return nil, "не удалось создать вагон" end
    local half = (first:OBBMaxs().x - first:OBBMins().x) / 2 * U2M
    if half < 5 then half = 9.6 end
    local pos, dir = SP.TrackAt(path, xFront - s * half)
    dir = dir * s
    first:SetPos(pos + Vector(0, 0, 60))
    first:SetAngles(Angle(0, dir:Angle().y, 0))
    first.Owner = owner
    first:Spawn()
    first:Activate()
    Metrostroi.RerailTrain(first)

    local settings = {}
    for _, set in ipairs(ENTH.Spawner or {}) do settings[set[1]] = spawnerValue(set) end

    local trains = { first }
    local LastRot, LastEnt = false, first
    applySpawner(ENTH, first, false, 1, wagnum, settings)
    first.FrontAutoCouple, first.RearAutoCouple = false, true

    for i = 2, wagnum do
        local rot = (i == wagnum) or math.random() > 0.5
        local cls = (i ~= wagnum) and fam.interim or fam.head
        local ent = ents.Create(cls)
        if not IsValid(ent) then break end
        ent.Owner = owner
        ent:Spawn()
        -- chain behind the previous car exactly like the spawner tool
        local couplL1 = LastRot and LastEnt.FrontCouple or LastEnt.RearCouple
        local couplE1, couplE2, bogeyE1, bogeyE2
        if rot then
            bogeyE1, bogeyE2 = ent.RearBogey, ent.FrontBogey
            couplE1, couplE2 = ent.FrontCouple, ent.RearCouple
        else
            bogeyE1, bogeyE2 = ent.FrontBogey, ent.RearBogey
            couplE1, couplE2 = ent.RearCouple, ent.FrontCouple
        end
        if IsValid(couplL1) and IsValid(couplE1) then
            couplE1:SetPos(couplL1:LocalToWorld(Vector(
                couplL1.CouplingPointOffset.x * 1.1 + couplE1.CouplingPointOffset.x * 1.1,
                couplL1.CouplingPointOffset.y - couplE1.CouplingPointOffset.y,
                couplL1.CouplingPointOffset.z - couplE1.CouplingPointOffset.z)))
            couplE1:SetAngles(couplL1:LocalToWorldAngles(Angle(0, 180, 0)))
            couplE2:SetAngles(couplE1:LocalToWorldAngles(Angle(0, 180, 0)))
            ent:SetPos(couplE1:LocalToWorld(couplE1.SpawnPos * Vector(rot and -1 or 1, -1, -1)))
            ent:SetAngles(LastEnt:LocalToWorldAngles(Angle(0, rot ~= LastRot and 180 or 0, 0)))
            bogeyE1:SetPos(ent:LocalToWorld(bogeyE1.SpawnPos))
            bogeyE2:SetPos(ent:LocalToWorld(bogeyE2.SpawnPos))
            bogeyE1:SetAngles(ent:LocalToWorldAngles(bogeyE1.SpawnAng))
            bogeyE2:SetAngles(ent:LocalToWorldAngles(bogeyE1.SpawnAng))
        end
        Metrostroi.RerailTrain(ent)
        LastRot = rot
        trains[#trains + 1] = ent
        applySpawner(ENTH, ent, LastRot, i, wagnum, settings)
        ent.FrontAutoCouple = i < wagnum
        ent.RearAutoCouple = true
        LastEnt = ent
    end
    if ENTH.Spawner and ENTH.Spawner.postfunc then pcall(ENTH.Spawner.postfunc, trains, wagnum) end

    -- couple them like the spawner: push together by the last car, then hold
    local coupled, stopped = 0, false
    local function stop()
        if stopped then return end
        stopped = true
        for _, t in ipairs(trains) do
            if IsValid(t) then
                t.FrontBogey.BrakeCylinderPressure, t.RearBogey.BrakeCylinderPressure = 3, 3
                t.FrontBogey.MotorPower, t.RearBogey.MotorPower = 0, 0
                t.OnCoupled = nil
            end
        end
        timer.Simple(1, function() for _, t in ipairs(trains) do if IsValid(t) then t.IgnoreEngine = false end end end)
    end
    for i, t in ipairs(trains) do
        t.IgnoreEngine = true
        t.RearBogey.MotorForce, t.FrontBogey.MotorForce = 40000, 40000
        t.RearBogey.PneumaticBrakeForce, t.FrontBogey.PneumaticBrakeForce = 50000, 50000
        t.RearBogey.MotorPower = (i == #trains) and 1 or 0
        t.FrontBogey.MotorPower = 0
        local held = (i == 1) and 3 or 0
        t.FrontBogey.BrakeCylinderPressure, t.RearBogey.BrakeCylinderPressure = held, held
        t.OnCoupled = function()
            coupled = coupled + 0.5
            if coupled >= #trains - 1 then stop() end
        end
    end
    -- the fault: only once the spawner's push-together is over (it needs the motors)
    timer.Simple(4 + #trains, function()
        for _, t in ipairs(trains) do SP.MakeBroken(t) end
    end)
    timer.Simple(3 + #trains, stop)
    return trains
end

--------------------------------------------------------------------------------
-- Broken train ahead
--------------------------------------------------------------------------------
local function trainLength(consist)
    local L = 0
    for _, w in ipairs(consist.wagons) do L = L + (w:OBBMaxs().x - w:OBBMins().x) * U2M + 1 end
    return L
end

local function stationBetween(path, x, s)
    -- names of the platforms just behind and ahead of x on this path, in travel direction
    local back, ahead, db, da = nil, nil, math.huge, math.huge
    for _, st in ipairs(Line.GetStations()) do
        for _, pl in pairs(st.platforms) do
            if pl.path == path then
                local d = (pl.xEnd - x) * s
                if d >= 0 and d < da then da, ahead = d, pl end
                if d < 0 and -d < db then db, back = -d, pl end
            end
        end
    end
    return back, ahead
end

function SP.SpawnBrokenAhead(consist, opts)
    opts = opts or {}
    local st = Line.GetState(consist)
    if not st or not st.onTrack then return nil, "поезд не на путях Метростроя" end
    local fam = SP.FamilyOf(consist, st.head)
    if not fam then return nil, "серия твоего поезда не поддерживается (Яуза, Юбилейный, Ока и т.п.)" end
    local pick = SP.PickFamily(fam)
    if not pick then return nil, "нет подходящей установленной серии" end

    local path, s = st.path, st.dirPlus and 1 or -1
    local L = trainLength(consist)
    local switches = switchPositions()
    local trainPoints = {}
    for _, c in ipairs(Line.GetConsists()) do
        for _, w in ipairs(c.wagons) do trainPoints[#trainPoints + 1] = w:GetPos() end
    end

    local xFront, why
    if opts.station then
        -- next platform ahead long enough: the head car at its stop mark
        local best
        for _, s2 in ipairs(Line.GetStations()) do
            for _, pl in pairs(s2.platforms) do
                local d = (pl.xEnd - st.x) * s
                if pl.path == path and pl.dir == st.dirPlus and d > (opts.minAhead or 300) and pl.length >= L - 10
                    and (not best or d < best.d) then
                    best = { pl = pl, d = d }
                end
            end
        end
        if best then
            local ok, r = goodStretch(path, best.pl.xEnd, best.pl.xEnd - s * L, {}, trainPoints)
            if ok then xFront = best.pl.xEnd else why = r end
        end
    else
        local from, to = opts.minAhead or 400, opts.maxAhead or 3500
        local start = from + math.random() * math.min(600, (to - from) / 2)   -- not always the same spot
        for d = start, to, 10 do
            local xTail = st.x + s * d
            local xF = xTail + s * L
            local ok, r = goodStretch(path, xTail, xF, switches, trainPoints)
            if ok and not onPlatform(path, xTail, xF) then xFront = xF break end
            why = r
        end
    end
    if not xFront then return nil, "впереди нет подходящего места" .. (why and (" (" .. why .. ")") or "") end

    local trains, err = SP.SpawnTrain(pick, #consist.wagons, path, xFront, st.dirPlus, st.driver)
    if not trains then return nil, err end
    local back, ahead = stationBetween(path, xFront - s * L, s)
    return {
        trains = trains, family = pick, distance = math.abs(xFront - s * L - st.x),
        between = { back, ahead }, atStation = opts.station == true,
    }
end

--------------------------------------------------------------------------------
-- Command: dispatcher_spawn_broken [станция]   (chat: !неисправный)
--------------------------------------------------------------------------------
concommand.Add("dispatcher_spawn_broken", function(ply, _, args)
    if not IsValid(ply) then return end
    if not (game.SinglePlayer() or ply:IsSuperAdmin()) then
        Dispatcher.Chat(ply, "[Dispatcher] Только суперадмин.") return
    end
    local c = Line.GetPlayerConsist(ply)
    if not c then Dispatcher.Chat(ply, "[Dispatcher] Сядь в кабину своего поезда.") return end
    local station = args[1] and (Line.Lower(args[1]) == "станция" or args[1] == "station")
    local info, err = SP.SpawnBrokenAhead(c, { station = station })
    if not info then Dispatcher.Chat(ply, "[Dispatcher] Не удалось: " .. err .. ".") return end
    local back, ahead = info.between[1], info.between[2]
    local where
    if info.atStation and ahead then
        where = "на ст. " .. ahead.station.name
    elseif back and ahead then
        where = "на перегоне " .. back.station.name .. " — " .. ahead.station.name
    else
        where = "на пути впереди"
    end
    Dispatcher.Chat(ply, Format("[Dispatcher] Неисправный поезд %s ×%d поставлен %s, в %.0f м впереди.",
        info.family.name, #info.trains, where, info.distance))
end)
