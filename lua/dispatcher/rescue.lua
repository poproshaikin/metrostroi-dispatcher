--------------------------------------------------------------------------------
-- Dispatcher.Rescue — scenario "вывод неисправного поезда" (!вывод).
--
-- 1. A broken train stands ahead (spawned now / in N minutes, or one already there).
--    The driver's timetable is cancelled: run as a reserve, (unload passengers at a
--    station on the way), stop before it, ask !пс, couple.
-- 2. Once coupled, a plan to the depot is made over the track graph:
--      drive along a path, take a crossover facing, or run past a trailing one,
--      change cabs and take it, until a signal route into the depot.
--    Running against the normal direction costs WRONG_W times more, so the plan
--    pushes / pulls the right way and uses the wrong track only for the short
--    reversal through a crossover (a platform turnback). Lengths: the whole
--    coupled train must clear a switch before reversing over it; the depot track
--    must hold both trains.
-- 3. The dispatcher leads it step by step: sets the routes / switches, says when
--    to stop and change cabs, watches the speed, the unloading of the broken
--    train's passengers, the depot track, the uncoupling. Nothing is blocked:
--    deviations are only counted (sandbox).
--------------------------------------------------------------------------------
local Line, G, R = Dispatcher.Line, Dispatcher.Graph, Dispatcher.Routes
local RS = Dispatcher.Rescue or {}
Dispatcher.Rescue = RS

local cvSpeed = CreateConVar("dispatcher_rescue_speed", "35", FCVAR_ARCHIVE, "Speed limit when towing / pushing a broken train, km/h")
local cvWrong = CreateConVar("dispatcher_rescue_wrong_speed", "20", FCVAR_ARCHIVE, "Speed limit on the wrong track during a rescue, km/h")

local U2M        = 0.01905
local WRONG_W    = 6      -- a metre against the normal direction costs this many
local REV_COST   = 400    -- changing cabs, in "metres"
local CLEAR      = 15     -- m past a switch for the whole train before reversing over it
local SET_DIST   = 400    -- m before a crossover / depot signal: set its route
local UNLOAD_T   = 60     -- s standing at a platform to unload
local TOL        = 2      -- km/h over the limit before a warning

RS.Missions = RS.Missions or {}   -- [cid] = mission

local function say(cid, text) Dispatcher.Comms.Say(cid, text) end
local function sgn(b) return b and 1 or -1 end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------
local function carLen(w) return (w:OBBMaxs().x - w:OBBMins().x) * U2M + 1 end
local function lenOf(cars) local L = 0 for _, w in ipairs(cars) do if IsValid(w) then L = L + carLen(w) end end return L end

-- lo, hi (m) of the cars' ends on raw path `path`; missing = ends not on it
local function spanOn(cars, path)
    local lo, hi, missing = nil, nil, 0
    for _, w in ipairs(cars) do
        if not IsValid(w) then continue end
        for _, ex in ipairs({ w:OBBMins().x, w:OBBMaxs().x }) do
            local found
            for _, c in ipairs(Metrostroi.GetPositionOnTrack(w:LocalToWorld(Vector(ex, 0, 0)), w:GetAngles()) or {}) do
                if c.path == path then found = c.x break end
            end
            if found then
                lo = lo and math.min(lo, found) or found
                hi = hi and math.max(hi, found) or found
            else
                missing = missing + 1
            end
        end
    end
    return lo, hi, missing
end

local function placeName(P, x)
    local best, bestD
    for _, pl in ipairs(P.platforms) do
        local d = math.abs((pl.xEnd or 0) - x)
        if not pl.siding and (not bestD or d < bestD) then best, bestD = pl, d end
    end
    return best and best.station.name or ("путь #" .. P.id)
end

local function brokenOf(c)
    for _, w in ipairs(c.wagons) do if w.DispatcherBroken then return true end end
end

-- Is the rescue consist coupled (mechanically or merged) to the broken train?
local function coupled(M, c)
    local set = {}
    for _, w in ipairs(M.broken) do if IsValid(w) then set[w] = true end end
    for _, w in ipairs(c.wagons) do
        if set[w] then return true end
        for _, cp in ipairs({ w.FrontCouple, w.RearCouple }) do
            local o = IsValid(cp) and cp.CoupledEnt
            local car = IsValid(o) and o:GetNW2Entity("TrainEntity")
            if IsValid(car) and set[car] then return true end
        end
    end
    return false
end

-- Rescue cars without the broken ones (when the consists merged electrically)
local function ownCars(M, c)
    local set, own = {}, {}
    for _, w in ipairs(M.broken) do set[w] = true end
    for _, w in ipairs(c.wagons) do if not set[w] then own[#own + 1] = w end end
    return own
end

local function allCars(M, c)
    local list, seen = {}, {}
    for _, w in ipairs(c.wagons) do if not seen[w] then seen[w] = true list[#list + 1] = w end end
    for _, w in ipairs(M.broken) do if IsValid(w) and not seen[w] then seen[w] = true list[#list + 1] = w end end
    return list
end

--------------------------------------------------------------------------------
-- Planner
--------------------------------------------------------------------------------
-- Ways into the depot: signal routes the map config marks as depot routes
local function depotGoals(g)
    local list = {}
    for _, S in ipairs(g.signals) do
        if #S.path.platforms == 0 then continue end
        for _, r in ipairs(S.routes) do
            if r.depot then list[#list + 1] = { path = S.path, x = S.x, dir = S.dir, signal = S, route = r } end
        end
    end
    return list
end

local function pathName(P)
    for _, sd in ipairs(Line.GetSidings()) do
        if sd.path and sd.path.id == P.id then return Format("%s (путь #%d)", sd.name, P.id) end
    end
    return "путь #" .. P.id
end

local function findLink(S, r)
    for _, L in ipairs(G.Get().links) do
        if L.from == S and L.route == r then return L end
    end
end

-- Run-around through the depot fan, for when the rescue train would enter the
-- depot first (it pulls) and be shut in behind the broken one: leave the broken
-- train on the depot-link path Pd the depot route leads to, go alone into the
-- depot, out by another depot-link path Pe, along a main path, change cabs, back
-- into Pd from its outer end, couple from the other side and push it in.
-- Every depot-link path end is taken to be joined to every other through the
-- depot fan (the depot tracks are not in the track data).
function RS.RunAround(gl)
    local g = G.Get()
    local L0 = findLink(gl.signal, gl.route)
    local Pd = L0 and L0.to.path
    if not Pd or Pd.kind ~= "depotlink" then return end
    local dd = Pd.depotEnds["end"] and 1 or -1           -- direction towards the depot along Pd
    local best
    for _, Pe in pairs(g.paths) do
        if Pe == Pd or Pe.kind ~= "depotlink" then continue end
        local de = Pe.depotEnds["end"] and 1 or -1
        for _, L1 in ipairs(Pe.links or {}) do
            -- out of the depot along Pe onto a main path
            if L1.from.dir ~= -de or L1.to.path.kind ~= "main" then continue end
            local Pm, d1 = L1.to.path, L1.to.dir
            for _, L2 in ipairs(Pm.links or {}) do
                -- after a cab change on Pm, back into Pd towards the depot
                if L2.to.path ~= Pd or L2.to.dir ~= dd or L2.from.dir ~= -d1 then continue end
                local cost = math.abs(L2.from.x - L1.to.x) + (G.NormalDir(Pm) == d1 and 0 or 1000)
                if not best or cost < best.cost then
                    best = { cost = cost, Pd = Pd, dd = dd, Pe = Pe, Pm = Pm, d1 = d1, L1 = L1, L2 = L2 }
                end
            end
        end
    end
    return best
end

-- From the coupling point x on graph path P, moving d, broken part ahead = b.
-- Returns legs (list) or nil, reason.
function RS.Plan(P, x, d, b, Lb, Lr)
    local g = G.Get()
    if not g then return nil, "нет схемы путей" end
    local entries = {}
    for _, E in ipairs(G.Crossovers()) do if E.signal or E.sw then entries[#entries + 1] = E end end
    local goals = depotGoals(g)
    if #goals == 0 then return nil, "на карте не размечены маршруты в депо (depotRoutes в конфиге карты)" end

    local open, best, seen = {}, nil, {}
    local function push(n) open[#open + 1] = n end
    push({ P = P, d = d, x = x, b = b, cost = 0, start = true })
    local guard = 0
    while #open > 0 and guard < 5000 do
        guard = guard + 1
        table.sort(open, function(a, c) return a.cost < c.cost end)
        local n = table.remove(open, 1)
        if best and n.cost >= best.cost then break end
        local key = n.P.id .. ":" .. n.d .. ":" .. math.floor(n.x / 5) .. ":" .. tostring(n.b)
        if seen[key] then continue end
        seen[key] = true
        local nd = G.NormalDir(n.P)
        local w = (nd == nil or nd == n.d) and 1 or WRONG_W
        local Lfront = n.b and Lb or Lr
        local Lrear = n.b and Lr or Lb

        for _, gl in ipairs(goals) do
            local dist = (gl.x - n.x) * n.d
            if gl.path == n.P and gl.dir == n.d and dist > Lfront then
                local c = n.cost + dist * w
                if not best or c < best.cost then best = { cost = c, prev = n, edge = { kind = "depot", goal = gl } } end
            end
        end
        for _, E in ipairs(entries) do
            if E.from ~= n.P then continue end
            local dist = (E.x - n.x) * n.d
            if E.dir == n.d and dist > Lfront + 5 then
                -- facing: take it
                push({ P = E.to, d = E.toDir, x = E.toX, b = n.b, cost = n.cost + dist * w + 50, prev = n,
                       edge = { kind = "cross", E = E } })
            elseif E.dir == -n.d then
                -- trailing: run the whole train past it, change cabs, take it back
                local x2 = E.x + n.d * (Lrear + CLEAR)
                local d2 = (x2 - n.x) * n.d
                if d2 > 0 and x2 >= 0 and x2 <= n.P.length then
                    push({ P = n.P, d = -n.d, x = x2, b = not n.b, cost = n.cost + d2 * w + REV_COST, prev = n,
                           edge = { kind = "passrev", E = E } })
                end
            end
        end
        if n.start then
            push({ P = n.P, d = -n.d, x = n.x, b = not n.b, cost = n.cost + REV_COST, prev = n, edge = { kind = "reverse" } })
        end
    end
    if not best then return nil, "не найден путь до депо" end

    local legs = {}
    local cur = best
    while cur and cur.edge do
        local from = cur.prev
        table.insert(legs, 1, { kind = cur.edge.kind, E = cur.edge.E, goal = cur.edge.goal,
            path = from.P, dir = from.d, x = from.x, pushing = from.b })
        cur = from
    end
    -- pulling into the depot = the rescue train goes in first: run around instead
    local last = legs[#legs]
    if last and last.kind == "depot" and not last.pushing then
        local ra = RS.RunAround(last.goal)
        if not ra then
            -- another depot route from the same signal may allow it
            for _, r in ipairs(last.goal.signal.routes) do
                if r.depot and r ~= last.goal.route then
                    local gl2 = { path = last.goal.path, x = last.goal.x, dir = last.goal.dir, signal = last.goal.signal, route = r }
                    ra = RS.RunAround(gl2)
                    if ra then last.goal = gl2 break end
                end
            end
        end
        if ra then
            last.kind, last.ra = "park", ra
            legs[#legs + 1] = { kind = "runaround", ra = ra, path = ra.Pm, dir = ra.d1, x = ra.L1.to.x }
        end
    end
    return legs
end

-- Human text of a plan
local function describeLeg(L)
    local where = placeName(L.path, L.E and L.E.x or (L.goal and L.goal.x) or L.x)
    local how = L.pushing and "толкать" or "тянуть"
    local nd = G.NormalDir(L.path)
    local wrong = nd and nd ~= L.dir and " по НЕПРАВИЛЬНОМУ пути" or ""
    if L.kind == "reverse" then return "сменить кабину" end
    if L.kind == "cross" then
        return Format("%s%s по пути #%d до %s, съездом (%s) на путь #%d", how, wrong, L.path.id, where, L.E.switches, L.E.to.id)
    end
    if L.kind == "passrev" then
        return Format("%s%s по пути #%d до %s, весь состав за стрелку %s, стоп, сменить кабину", how, wrong, L.path.id, where,
            L.E.switches:match("^[^,%+%-]+") or "?")
    end
    if L.kind == "depot" then
        return Format("%s%s по пути #%d до %s, маршрут в депо (светофор %s)", how, wrong, L.path.id, where, L.goal.signal.name or "?")
    end
    if L.kind == "park" then
        return Format("%s%s по пути #%d до %s, маршрут на %s (светофор %s): ваш поезд уходит в депо, неисправный целиком встаёт на %s — стоп, расцепка",
            how, wrong, L.path.id, where, pathName(L.ra.Pd), L.goal.signal.name or "?", pathName(L.ra.Pd))
    end
    if L.kind == "runaround" then
        local ra = L.ra
        return Format("одному: в депо на свободную канаву, смена кабины, выезд по %s (светофор %s) на путь #%d; за светофором %s стоп, смена кабины; маршрут на %s (светофор %s), по !пс к неисправному, сцепка; толкать его в депо на свободную канаву",
            pathName(ra.Pe), ra.L1.from.name or "?", ra.Pm.id, ra.L2.from.name or "?", pathName(ra.Pd), ra.L2.from.name or "?")
    end
    return L.kind
end

--------------------------------------------------------------------------------
-- Routes the mission wants (asked by Routes.Choose)
--------------------------------------------------------------------------------
function RS.RouteFor(S, consist)
    local M = consist and RS.Missions[consist.id]
    return M and M.routeAt and S.name and M.routeAt[S.name]
end

-- While towing, running under ОЧ (no codes on the wrong track, behind a dead train)
-- is part of the order: no "moving without leave" violation.
function RS.CoversOCh(cid)
    local M = RS.Missions[cid]
    return M ~= nil and (M.phase == "tow" or M.phase == "depot" or M.phase == "uncouple")
end

local function wantRoute(M, cid, S, r)
    M.routeAt[S.name] = r
    if R.Done[cid] then R.Done[cid][S] = nil end   -- let the automatic routes look again
end

local function throwSwitches(sw)
    for name, pos in pairs(sw) do
        local s = Metrostroi.GetSwitchByName(name)
        if IsValid(s) and ((s:GetSignal() ~= 0) and "alt" or "main") ~= pos then s:SendSignal(pos, nil, true) end
    end
end

--------------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------------
local function violation(M, text)
    M.violations[#M.violations + 1] = text
    if Dispatcher.Invite then Dispatcher.Invite.Violation(M.cid, text) end
end

function RS.Finish(M, text)
    RS.Missions[M.cid] = nil
    local mins = (CurTime() - M.started) / 60
    say(M.cid, Format("%s Вывод занял %.0f мин, наибольшая скорость со сцепом %.0f км/ч%s.", text, mins, M.maxSpeed,
        #M.violations > 0 and (", замечаний: " .. #M.violations) or ", без замечаний"))
    for _, v in ipairs(M.violations) do say(M.cid, "  • " .. v) end
    hook.Run("Dispatcher_RescueDone", M.cid, M)
end

-- Nearest broken train ahead on the same path: its wagons, distance
local function brokenAhead(c, st)
    local s = sgn(st.dirPlus)
    local best, bestD
    for _, c2 in ipairs(Line.GetConsists()) do
        if c2.id == c.id or not brokenOf(c2) then continue end
        local lo, hi = spanOn(c2.wagons, st.path)
        if lo then
            local d = ((s > 0 and lo or hi) - st.x) * s
            if d > 0 and (not bestD or d < bestD) then best, bestD = c2, d end
        end
    end
    return best, bestD
end

local function begin(c, st, brokenWagons, dist)
    local cid = c.id
    local M = { cid = cid, broken = brokenWagons, phase = "approach", started = CurTime(), maxSpeed = 0,
                violations = {}, routeAt = {}, legs = nil, li = 0, told = {} }
    M.Lb, M.Lr = lenOf(brokenWagons), lenOf(c.wagons)
    RS.Missions[cid] = M

    local a = Dispatcher.Schedule.GetAssignment(c)
    if a then Dispatcher.Schedule.Cancel(c) end
    -- where is it
    local s = sgn(st.dirPlus)
    local P = G.Get() and G.Get().paths[st.path.id]
    local lo, hi = spanOn(brokenWagons, st.path)
    local near = lo and (s > 0 and lo or hi) or (st.x + s * dist)
    local back, ahead
    for _, pl in ipairs(P and P.platforms or {}) do
        if pl.dir ~= st.dirPlus then continue end
        local d = (pl.xEnd - near) * s
        if d >= 0 and (not ahead or d < (ahead.xEnd - near) * s) then ahead = pl end
        if d < 0 and (not back or -d < (near - back.xEnd) * s) then back = pl end
    end
    local where = (back and ahead) and ("на перегоне " .. back.station.name .. " — " .. ahead.station.name)
        or (ahead and ("перед ст. " .. ahead.station.name)) or "впереди по вашему пути"
    -- a platform between us and it: unload our passengers there
    local unloadAt
    for _, pl in ipairs(P and P.platforms or {}) do
        local d1 = (pl.xEnd - st.x) * s
        if pl.dir == st.dirPlus and d1 > 20 and (pl.xEnd - near) * s < -20 then
            if not unloadAt or d1 < (unloadAt.xEnd - st.x) * s then unloadAt = pl end
        end
    end
    M.unloadOwn = unloadAt
    say(cid, Format("Внимание! %s стоит неисправный поезд, %d ваг., в %.0f м от вас (путь %s).%s",
        where, #brokenWagons, dist, P and P.id or "?", a and " Ваш наряд снят." or ""))
    say(cid, Format("Вам: %sследовать резервом к неисправному поезду, остановиться перед ним, запросить !пс и сцепиться. План вывода в депо — после сцепки.",
        unloadAt and ("на ст. " .. unloadAt.station.name .. " высадить пассажиров (стоянка не менее 1 мин), ") or ""))
    hook.Run("Dispatcher_RescueStart", cid, M)
    return M
end

concommand.Add("dispatcher_rescue", function(ply, _, args)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    local st = c and Line.GetState(c)
    if not st or st.driver ~= ply or not st.onTrack then Dispatcher.Chat(ply, "[ДЦХ] Сядьте на место машиниста.") return end
    local arg = Line.Lower(args[1] or "")
    if arg == "отмена" or arg == "cancel" then
        local M = RS.Missions[c.id]
        if M then RS.Missions[c.id] = nil; say(c.id, "Вывод неисправного поезда отменён.") end
        if RS.Pending and RS.Pending[ply] then timer.Remove(RS.Pending[ply]); RS.Pending[ply] = nil end
        return
    end
    if RS.Missions[c.id] then Dispatcher.Chat(ply, "[ДЦХ] Вывод уже идёт. !вывод отмена — отменить.") return end

    local tries = 0
    local start
    function start()
        if not IsValid(ply) then return end
        local c2 = Line.GetPlayerConsist(ply)
        local st2 = c2 and Line.GetState(c2)
        if not st2 or not st2.onTrack then return end
        local b, d = brokenAhead(c2, st2)
        if b then begin(c2, st2, table.Copy(b.wagons), d) return end
        local SP = Dispatcher.Spawn
        if not SP then Dispatcher.Chat(ply, "[ДЦХ] Нет модуля спавна.") return end
        local info, err = SP.SpawnBrokenAhead(c2, { minAhead = 700, maxAhead = 3500, onFail = function()
            -- it went wrong (physics / off the rails) and was removed: try again a few times
            tries = tries + 1
            if tries < 3 then timer.Simple(1, start) else Dispatcher.Chat(ply, "[ДЦХ] Неисправный поезд не встаёт ровно, попробуйте в другом месте.") end
        end })
        if not info then Dispatcher.Chat(ply, "[ДЦХ] Неисправный поезд поставить не удалось: " .. err .. ".") return end
        -- the cars settle for a few seconds before they count as a train
        timer.Simple(8, function()
            if not IsValid(ply) then return end
            local c3 = Line.GetPlayerConsist(ply)
            local st3 = c3 and Line.GetState(c3)
            local ok = {}
            for _, t in ipairs(info.trains) do if IsValid(t) then ok[#ok + 1] = t end end
            if #ok == 0 then return end   -- removed as crooked: onFail spawns again
            if not st3 then Dispatcher.Chat(ply, "[ДЦХ] Сядьте на место машиниста и повторите !вывод.") return end
            begin(c3, st3, ok, info.distance)
        end)
    end

    local mins = tonumber(args[1])
    if mins and mins > 0 then
        RS.Pending = RS.Pending or {}
        local id = "Dispatcher_Rescue_" .. ply:EntIndex()
        RS.Pending[ply] = id
        timer.Create(id, mins * 60 * (0.5 + math.random()), 1, function() RS.Pending[ply] = nil start() end)
        Dispatcher.Chat(ply, Format("[ДЦХ] Принято: поломка случится в ближайшие ~%d мин где-то впереди.", math.ceil(mins * 1.5)))
    else
        start()
    end
end)

--------------------------------------------------------------------------------
-- Leading the mission
--------------------------------------------------------------------------------
local function startTow(M, c, st)
    local g = G.Get()
    local P = g and g.paths[st.path.id]
    if not P then say(M.cid, "Поезд вне схемы путей, план не построить — выводите по указаниям вручную.") return end
    local s = sgn(st.dirPlus)
    -- is the broken train ahead of our cab (we push) or behind it (we pull)?
    M.Lr = lenOf(ownCars(M, c))
    local lo, hi = spanOn(M.broken, st.path)
    local b = true
    if lo then b = (((s > 0) and hi or lo) - st.x) * s > 0 end
    -- the coupling point: at our cab when pushing, our train's length behind it when pulling
    local xc = b and st.x or (st.x - s * M.Lr)
    local legs, err = RS.Plan(P, xc, s, b, M.Lb, M.Lr)
    if not legs then say(M.cid, "Сцепка есть, но план вывода не построен: " .. err .. ". Выводите вручную, маршруты — !маршрут.") return end
    M.legs, M.li, M.phase = legs, 1, "tow"
    -- pushing it into the depot: only the broken train has to fit on the depot track
    local last = legs[#legs]
    if last and last.kind == "depot" and last.pushing then M.needLen = M.Lb end
    say(M.cid, Format("Сцепка есть. Общая длина %.0f м. План вывода в депо:", M.Lb + M.Lr))
    for i, L in ipairs(legs) do say(M.cid, Format("  %d) %s", i, describeLeg(L))) end
    say(M.cid, Format("Скорость со сцепом не более %d км/ч, по неправильному пути не более %d. Пассажиров неисправного поезда высадить на первой станции.",
        cvSpeed:GetInt(), cvWrong:GetInt()))
end

local function legDone(M)
    M.li = M.li + 1
    M.told = {}
end

-- unloading at a platform: cars (the ones with passengers) stand at it, stopped
local function platformUnder(cars, path)
    local lo, hi = spanOn(cars, path)
    if not lo then return end
    for _, stn in ipairs(Line.GetStations()) do
        for _, pl in pairs(stn.platforms) do
            if pl.path == path and pl.length then
                local a = pl.xEndRaw or pl.xEnd
                local b = a - sgn(pl.dir) * pl.length
                local pLo, pHi = math.min(a, b), math.max(a, b)
                local overlap = math.min(hi, pHi) - math.max(lo, pLo)
                if overlap > math.min(pl.length, hi - lo) * 0.6 then return pl end
            end
        end
    end
end

local function watchUnload(M, key, cars, st)
    local U = M[key]
    if U and U.done then return end
    local pl = st.stopped and platformUnder(cars, st.path)
    if pl then
        if not U or U.pl ~= pl then
            M[key] = { pl = pl, since = CurTime() }
            say(M.cid, Format("Ст. %s: высадка пассажиров %s, стоянка не менее %d с.", pl.station.name,
                key == "unloadB" and "неисправного поезда" or "вашего поезда", UNLOAD_T))
        elseif CurTime() - U.since >= UNLOAD_T and not U.ok then
            U.ok = true
            say(M.cid, "Высадка окончена, можно следовать.")
        end
    elseif U and not st.stopped then
        if not U.ok then violation(M, Format("высадка на ст. %s короче %d с", U.pl.station.name, UNLOAD_T)) end
        U.done = true
    end
end

-- A random free depot track for a train of length `need` (the marks may sit a
-- few metres inside the real track ends: Depot counts ±5 m beyond them)
local function freeCanal(need, except)
    local D = Dispatcher.Depot
    if not D then return end
    local free = {}
    for _, t in ipairs(D.Tracks()) do
        if t.complete and t.length + 8 >= need and not D.Occupied(t, except) then free[#free + 1] = t end
    end
    return free[math.random(math.max(#free, 1))]
end

-- the park leg: the broken train wholly on Pd, clear of the entry from the main track
local function parked(M, ra)
    local lo, hi, missing = spanOn(M.broken, ra.Pd.raw)
    if not lo or missing > 0 then return false end
    local outer = ra.dd > 0 and lo or hi      -- the end facing away from the depot
    return (outer - ra.L2.to.x) * ra.dd > 10
end

local nextTick = 0
hook.Add("Think", "Dispatcher_Rescue", function()
    if CurTime() < nextTick then return end
    nextTick = CurTime() + 1
    for cid, M in pairs(RS.Missions) do
        local c = Line.GetConsist(cid)
        local st = c and Line.GetState(c)
        local valid = {}
        for _, w in ipairs(M.broken) do if IsValid(w) then valid[#valid + 1] = w end end
        M.broken = valid
        if #valid == 0 then RS.Missions[cid] = nil say(cid, "Неисправный поезд убран — вывод отменён.") continue end
        if not st then continue end
        -- the depot tracks are usually not in the track data: off the track = in the depot
        local curLeg = M.phase == "tow" and M.legs and M.legs[M.li]
        if not st.onTrack then
            if curLeg and curLeg.kind == "depot" then M.phase = "depot" end
            local inDepotLeg = curLeg and (curLeg.kind == "park" or curLeg.kind == "runaround")
            if M.phase ~= "depot" and M.phase ~= "uncouple" and not inDepotLeg then continue end
        end
        local s = sgn(st.dirPlus)
        local together = coupled(M, c)

        if M.phase == "approach" then
            if M.unloadOwn and not (M.unloadA and M.unloadA.done) then watchUnload(M, "unloadA", c.wagons, st) end
            if coupled(M, c) and st.stopped then
                if M.unloadOwn and not (M.unloadA and M.unloadA.ok) then
                    violation(M, "пассажиры вашего поезда не высажены на ст. " .. M.unloadOwn.station.name)
                end
                startTow(M, c, st)
            end
            continue
        end

        -- speed with the broken train
        local g = G.Get()
        local P = g and st.path and g.paths[st.path.id]
        local nd = P and G.NormalDir(P)
        local wrong = nd and nd ~= s
        local lim = wrong and cvWrong:GetInt() or cvSpeed:GetInt()
        M.maxSpeed = math.max(M.maxSpeed, st.speed)
        if together and st.speed > lim + TOL and (not M.warnedAt or CurTime() - M.warnedAt > 10) then
            M.warnedAt = CurTime()
            say(cid, Format("Превышение со сцепом! Не более %d км/ч, у вас %.0f.", lim, st.speed))
            if not M.overNoted then M.overNoted = true violation(M, Format("превышение со сцепом (%.0f км/ч при %d)", st.speed, lim)) end
        end
        if together and st.onTrack and not (M.unloadB and M.unloadB.done) then watchUnload(M, "unloadB", M.broken, st) end

        if M.phase == "tow" then
            local L = M.legs[M.li]
            if not L then M.phase = "depot" continue end
            local onLeg = st.path == L.path.raw
            if L.kind == "reverse" then
                if not M.told.rev then M.told.rev = true say(cid, "Смените кабину.") end
                if s == -L.dir then legDone(M) end
            elseif L.kind == "passrev" then
                local E = L.E
                if not M.told.go then
                    M.told.go = true
                    say(cid, Format("Следуйте до %s и проследуйте всем составом за стрелку %s, дальше — по команде «Стоп».",
                        placeName(L.path, E.x), E.switches:match("^[^,%+%-]+") or "?"))
                end
                if onLeg and not M.told.stop then
                    local lo, hi = spanOn(allCars(M, c), st.path)
                    local rear = lo and (L.dir > 0 and lo or hi)
                    if rear and (rear - E.x) * L.dir > 10 then
                        M.told.stop = true
                        say(cid, "Стоп! Состав за стрелкой. Остановитесь и смените кабину.")
                    end
                end
                if M.told.stop and st.stopped and s == -L.dir then
                    legDone(M)
                    say(cid, "Кабина сменена.")
                end
            elseif L.kind == "cross" then
                local E = L.E
                if st.path == E.to.raw then
                    legDone(M)
                    if wrong then say(cid, Format("Вы на неправильном пути. Не более %d км/ч.", cvWrong:GetInt())) end
                elseif onLeg and math.abs(E.x - st.x) < SET_DIST and not M.told.set then
                    M.told.set = true
                    if E.signal and E.route then
                        wantRoute(M, cid, E.signal, E.route)
                        say(cid, Format("Готовлю маршрут через съезд на путь #%d (светофор %s).", E.to.id, E.signal.name or "?"))
                    elseif E.sw then
                        throwSwitches(E.sw)
                        say(cid, Format("Стрелки %s переведены на съезд, путь #%d. Следуйте по съезду.", E.switches, E.to.id))
                    end
                end
            elseif L.kind == "depot" then
                local gl = L.goal
                if onLeg and math.abs(gl.x - st.x) < SET_DIST and not M.told.set then
                    M.told.set = true
                    wantRoute(M, cid, gl.signal, gl.route)
                    say(cid, Format("Готовлю маршрут в депо (светофор %s).", gl.signal.name or "?"))
                end
                if not P or #P.platforms == 0 then M.phase = "depot" end
            elseif L.kind == "park" then
                local gl, ra = L.goal, L.ra
                if onLeg and math.abs(gl.x - st.x) < SET_DIST and not M.told.set then
                    M.told.set = true
                    wantRoute(M, cid, gl.signal, gl.route)
                    say(cid, Format("Готовлю маршрут на %s (светофор %s). Ваш поезд уходит в депо, неисправный должен целиком встать на %s — скажу «Стоп».",
                        pathName(ra.Pd), gl.signal.name or "?", pathName(ra.Pd)))
                end
                if together and not M.told.parked and parked(M, ra) then
                    M.told.parked = true
                    say(cid, Format("Стоп! Неисправный целиком на %s. Остановитесь и расцепитесь.", pathName(ra.Pd)))
                end
                if not together then
                    if not M.told.parked then violation(M, "расцепка до того, как неисправный встал на " .. pathName(ra.Pd)) end
                    legDone(M)
                end
            elseif L.kind == "runaround" then
                local ra = L.ra
                if not M.told.go then
                    M.told.go = true
                    wantRoute(M, cid, ra.L1.from, ra.L1.route)
                    wantRoute(M, cid, ra.L2.from, ra.L2.route)
                    local cn = freeCanal(M.Lr, c)
                    say(cid, Format("Расцепка есть. Следуйте в депо%s, смените кабину, выезжайте по %s на путь #%d (светофор %s, маршрут приготовлю).",
                        cn and (" на путь " .. cn.name) or "", pathName(ra.Pe), ra.Pm.id, ra.L1.from.name or "?"))
                end
                if st.onTrack and st.path == ra.Pm.raw and s == ra.d1 and not M.told.stop then
                    local lo, hi = spanOn(c.wagons, st.path)
                    local rear = lo and (ra.d1 > 0 and lo or hi)
                    if rear and (rear - ra.L2.from.x) * ra.d1 > CLEAR then
                        M.told.stop = true
                        say(cid, Format("Стоп! Состав за светофором %s. Смените кабину: маршрут на %s приготовлю, к неисправному — по !пс, сцепиться.",
                            ra.L2.from.name or "?", pathName(ra.Pd)))
                    end
                end
                if together and st.stopped then
                    legDone(M)
                    M.needLen = M.Lb
                    say(cid, "Сцепка есть. Толкайте неисправный поезд в депо.")
                end
            end
            continue
        end

        if M.phase == "depot" then
            local D = Dispatcher.Depot
            if not D then RS.Finish(M, "Поезд в депо.") continue end
            if not M.canal then
                local need = M.needLen or (M.Lb + M.Lr + 5)
                M.canal = freeCanal(need, c)
                if M.canal then
                    say(cid, Format("Постановка в депо на путь %s (%.0f м, %s %.0f м).", M.canal.name, M.canal.length,
                        M.needLen and "неисправный поезд" or "состав", need))
                else
                    M.canal = false
                    say(cid, "Свободного пути депо нужной длины нет — поставьте на любой свободный, неисправный поезд целиком.")
                end
            end
            local bs = D.State({ wagons = M.broken })
            if bs and bs.full and st.stopped and (not M.canal or bs.track == M.canal) then
                M.phase = "uncouple"
                say(cid, "Неисправный поезд на пути депо. Расцепите его и отведите свой состав.")
            elseif bs and bs.full and st.stopped and M.canal and bs.track ~= M.canal and not M.told.wrongCanal then
                M.told.wrongCanal = true
                violation(M, "неисправный поезд поставлен не на указанный путь депо")
                M.phase = "uncouple"
                say(cid, "Не тот путь депо, но пусть стоит. Расцепите неисправный поезд.")
            end
            continue
        end

        if M.phase == "uncouple" then
            if not coupled(M, c) then
                if not (M.unloadB and M.unloadB.ok) then violation(M, "пассажиры неисправного поезда не высажены на станции") end
                RS.Finish(M, "Вывод неисправного поезда завершён.")
            end
        end
    end
end)

hook.Add("Dispatcher_Rekey", "Dispatcher_Rescue", function(old, new)
    local M = RS.Missions[old]
    if not M then return end
    RS.Missions[old], RS.Missions[new] = nil, M
    M.cid = new
end)
