--------------------------------------------------------------------------------
-- Dispatcher.Invite — moving past a stop indication with the dispatcher's leave.
--
-- !пригласительный / !пс, standing at a stop:
--   * at a closed signal with an invitation lens (W) close ahead: the dispatcher
--     opens the invitation signal
--   * otherwise (ARS-only lines, Nekrasovka: no wayside signals, the cab shows
--     "0" / ОЧ): a verbal permission to move under the stop indication
-- either only when there is a reason:
--   * a permit given by a scenario / order (I.Permit) — rescue, maneuvers, ...
--   * a broken (dead) train ahead — approach it to couple
--   * the line holds the train but no train is ahead — a track circuit fault
-- It refuses when a working train is ahead (wait), the signal was closed on
-- purpose, or the route is not set (!маршрут).
--
-- Then it watches the speed: not above dispatcher_invite_speed (20 km/h), until
-- the block is passed or the train has coupled to the broken one.
--
-- Nothing is blocked (sandbox): starting off under "0"/ОЧ without permission is
-- only reported and counted as a violation for the shift.
--------------------------------------------------------------------------------
local Line, G, R = Dispatcher.Line, Dispatcher.Graph, Dispatcher.Routes
local I = Dispatcher.Invite or {}
Dispatcher.Invite = I

local cvSpeed = CreateConVar("dispatcher_invite_speed", "20", FCVAR_ARCHIVE, "Speed limit under an invitation / stop-indication permission, km/h")

local NEAR       = 60     -- m: a signal this close ahead is the one asked about
local LOOK       = 2500   -- m: look this far ahead for a train
local TOL        = 2      -- km/h over the limit before a warning
local ZONE_MAX   = 2000   -- m: watch at most this far past the signal / start
local EXPIRE     = 900    -- s: an invitation / permission is forgotten after this
local START_SPEED = 3     -- km/h: "started off" for the violation check
local SIDING_ZONE = 400   -- m around a turnback dead end: ОЧ there is normal

I.Permits = I.Permits or {}   -- [cid] = { reason, signal (name or nil = any), expires }
I.Active = I.Active or {}     -- [cid] = { path, dir, startX, endX, reason, limit, maxSpeed, warnedAt, violations, since, entered, target }

-- For scenarios: allow cid an invitation / permission (at `signal`, or anywhere if nil) for ttl seconds
function I.Permit(cid, reason, signal, ttl)
    I.Permits[cid] = { reason = reason, signal = signal, expires = CurTime() + (ttl or 1800) }
end
function I.Revoke(cid) I.Permits[cid] = nil end

local function say(cid, text) Dispatcher.Comms.Say(cid, text) end

local function isBroken(c)
    for _, w in ipairs(c and c.wagons or {}) do if w.DispatcherBroken then return true end end
    return false
end

local function consistOf(ent)
    if not IsValid(ent) then return end
    for _, c in ipairs(Line.GetConsists()) do
        for _, w in ipairs(c.wagons) do if w == ent then return c end end
    end
end

-- Mechanically coupled to a broken train (couplers, not only the electric WagonList)
local function coupledToBroken(c)
    for _, w in ipairs(c.wagons) do
        for _, cp in ipairs({ w.FrontCouple, w.RearCouple }) do
            local o = IsValid(cp) and cp.CoupledEnt
            local car = IsValid(o) and o:GetNW2Entity("TrainEntity")
            if IsValid(car) and car.DispatcherBroken then return true end
        end
    end
    return false
end

-- What the head cab's ARS receives: "0", "ОЧ" or nil (a code that allows running,
-- or no ARS on this series / switched off)
function I.ArsStop(st)
    local coil = st and IsValid(st.head) and st.head.ALSCoil
    if not coil or (coil.Enabled or 0) <= 0 then return end   -- 1 or 2 when on (2 on the 717)
    if coil.NoFreq == 1 then return "ОЧ" end
    if coil.F5 == 1 and (coil.F1 or 0) + (coil.F2 or 0) + (coil.F3 or 0) + (coil.F4 or 0) == 0 then return "0" end
end

-- Nearest other train ahead on the same path: consist, distance (m), its near end x
local function trainAhead(c, st)
    local s = st.dirPlus and 1 or -1
    local best, bestD, bestX
    for _, c2 in ipairs(Line.GetConsists()) do
        if c2.id == c.id then continue end
        for _, w in ipairs(c2.wagons) do
            for _, ex in ipairs({ w:OBBMins().x, w:OBBMaxs().x }) do
                local p = w:LocalToWorld(Vector(ex, 0, 0))
                for _, cand in ipairs(Metrostroi.GetPositionOnTrack(p, w:GetAngles()) or {}) do
                    if cand.path == st.path then
                        local d = (cand.x - st.x) * s
                        if d > 0 and d < LOOK and (not bestD or d < bestD) then best, bestD, bestX = c2, d, cand.x end
                    end
                end
            end
        end
    end
    return best, bestD, bestX
end

-- The next signal past x in direction s on graph path P: its x (or nil)
local function nextSignalX(P, x, s)
    local best
    for _, S2 in ipairs(P and P.signals or {}) do
        local d = (S2.x - x) * s
        if S2.dir == s and d > 5 and (not best or d < best) then best = d end
    end
    return best and (x + best * s)
end

--------------------------------------------------------------------------------
-- Is there a reason? Returns ok, text (the reason, or why not), target consist
--------------------------------------------------------------------------------
local function permitFor(cid, sigName)
    local p = I.Permits[cid]
    if p and p.expires > CurTime() and (not p.signal or p.signal == sigName) then return p.reason end
end

-- At a light signal with an invitation lens
function I.JudgeSignal(S, consist)
    local e = S.ent
    local pr = permitFor(consist.id, S.name)
    if pr then return true, pr end
    if e.Close then return false, "светофор закрыт" end
    if R and #S.routes > 0 then
        local anySet = false
        for _, r in ipairs(S.routes) do if R.IsSet(S, r) then anySet = true break end end
        if not anySet then return false, "маршрут не приготовлен — !маршрут" end
    end
    local tp = e.TrackPosition
    if not (e.Node and tp) then return false, "светофор вне схемы путей" end
    local occ, _, first = Metrostroi.IsTrackOccupied(e.Node, tp.x, tp.forward, e.ARSOnly and "ars" or "light")
    if not occ then
        if e.Occupied then return true, "ложная занятость (неисправность рельсовой цепи)" end
        return false, "светофор не запрещающий — следуйте по его показанию"
    end
    local c = consistOf(first)
    if c and c.id == consist.id then return false, "ваш поезд заехал за светофор — встаньте перед ним" end
    if not c then return true, "занятость без поезда (неисправность рельсовой цепи)" end
    if isBroken(c) then return true, "подъезд к неисправному поезду для сцепки", c end
    return false, "впереди поезд, перегон занят. Ожидайте открытия светофора"
end

-- Under "0" / ОЧ in the cab (no light signal to open)
function I.JudgeTrack(consist, st, ars)
    local pr = permitFor(consist.id, nil)
    local c2, d = trainAhead(consist, st)
    if pr then return true, pr, c2 and isBroken(c2) and c2 or nil end
    if isBroken(consist) and ars then return true, "вывод неисправного поезда" end
    if c2 and isBroken(c2) then return true, Format("подъезд к неисправному поезду (%.0f м) для сцепки", d), c2 end
    if c2 then return false, Format("впереди поезд в %.0f м. Ожидайте разрешающего показания АРС", d) end
    if ars then return true, "впереди поездов нет — неисправность рельсовой цепи" end
    return false, "АРС не запрещает движение — следуйте по её показаниям"
end

--------------------------------------------------------------------------------
-- !пригласительный / !пс
--------------------------------------------------------------------------------
local function grant(c, st, A)
    A.limit, A.maxSpeed, A.violations, A.since = cvSpeed:GetInt(), 0, 0, CurTime()
    I.Active[c.id] = A
    Line.GetMemory(c).arsHeld = nil   -- moving off now is allowed
end

concommand.Add("dispatcher_invite", function(ply)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    local st = c and Line.GetState(c)
    if not st or st.driver ~= ply then Dispatcher.Chat(ply, "[ДЦХ] Сядьте на место машиниста.") return end
    if not st.onTrack then Dispatcher.Chat(ply, "[ДЦХ] Поезд не на путях.") return end
    if not st.stopped then say(c.id, "Остановитесь, потом запрашивайте.") return end
    local g = G.Get()
    local s = st.dirPlus and 1 or -1
    local limit = cvSpeed:GetInt()

    -- 1) a light signal with an invitation lens right ahead
    local a = R.SignalsAhead(st, NEAR, true)[1]
    if a and (a.S.ent.GoodInvationSignal or 0) ~= 0 then
        local S = a.S
        local name = S.name or "?"
        if S.ent.InvationSignal then say(c.id, Format("Пригласительный на %s уже открыт.", name)) return end
        local ok, why, target = I.JudgeSignal(S, c)
        if not ok then say(c.id, Format("Пригласительный на %s не открываю: %s.", name, why)) return end
        S.ent.InvationSignal = true
        local endX = nextSignalX(S.path, S.x, S.dir) or (S.x + ZONE_MAX * S.dir)
        grant(c, st, { path = S.path.raw, dir = S.dir, startX = S.x, endX = endX, reason = why, target = target })
        say(c.id, Format("Открываю пригласительный на светофоре %s (%s). Следуйте со скоростью не более %d км/ч, с готовностью остановиться.",
            name, why, limit))
        hook.Run("Dispatcher_Invite", c.id, S, why)
        return
    end

    -- 2) verbal permission under the cab's stop indication
    local ars = I.ArsStop(st)
    local ok, why, target = I.JudgeTrack(c, st, ars)
    if not ok then say(c.id, Format("Разрешения не даю: %s.", why)) return end
    local P = g and g.paths[st.path.id]
    local endX
    if target then
        endX = st.x + LOOK * s   -- until coupled
    else
        -- through the held block: past the next signal / joint, and the one after it
        local x1 = nextSignalX(P, st.x, s)
        endX = (x1 and nextSignalX(P, x1, s)) or x1 or (st.x + ZONE_MAX * s)
    end
    grant(c, st, { path = st.path, dir = s, startX = st.x, endX = endX, reason = why, target = target, entered = true })
    say(c.id, Format("Разрешаю движение при запрещающем показании АРС%s (%s). Скорость не более %d км/ч, с готовностью остановиться.",
        ars and (" («" .. ars .. "»)") or "", why, limit))
    hook.Run("Dispatcher_Invite", c.id, nil, why)
end)

--------------------------------------------------------------------------------
-- Violations (counted for the shift)
--------------------------------------------------------------------------------
function I.Violation(cid, text)
    local c = Line.GetConsist(cid)
    local a = c and Dispatcher.Schedule.GetAssignment(c)
    if a then
        a.violations = a.violations or {}
        a.violations[#a.violations + 1] = os.date("%H:%M ", Line.Now()) .. text
    end
    hook.Run("Dispatcher_Violation", cid, text)
end

-- Places where running under ОЧ is normal: turnback dead ends, depot
local function exempt(c, st)
    for _, sd in ipairs(Line.GetSidings()) do
        if sd.path == st.path and sd.xEnd and math.abs(sd.xEnd - st.x) < SIDING_ZONE then return true end
    end
    local g = G.Get()
    local P = g and g.paths[st.path.id]
    if P and P.kind ~= "main" and P.kind ~= "crossover" then return true end
    if Dispatcher.Depot and Dispatcher.Depot.State(c) then return true end
    return false
end

--------------------------------------------------------------------------------
-- Watch: speed under permission; starting off under "0"/ОЧ without one
--------------------------------------------------------------------------------
local nextTick = 0
hook.Add("Think", "Dispatcher_Invite", function()
    if CurTime() < nextTick then return end
    nextTick = CurTime() + 0.5

    for cid, A in pairs(I.Active) do
        local c = Line.GetConsist(cid)
        local st = c and Line.GetState(c)
        if not st or not st.onTrack or CurTime() - A.since > EXPIRE then I.Active[cid] = nil continue end
        local along = (st.path == A.path) and (st.x - A.startX) * A.dir or nil
        if along and along > 0 then A.entered = true end

        local summary = Format("Наибольшая скорость %.0f км/ч%s.", A.maxSpeed,
            A.violations > 0 and Format(", превышений: %d", A.violations) or ", без превышений")
        if A.target and coupledToBroken(c) then
            say(cid, "Сцепление с неисправным поездом выполнено. " .. summary)
            I.Active[cid] = nil
            hook.Run("Dispatcher_RescueCoupled", cid)
            continue
        end
        if A.entered and (not along or (st.x - A.endX) * A.dir > 0) then
            say(cid, "Участок пройден, разрешение снято. " .. summary)
            I.Active[cid] = nil
            continue
        end
        if not A.entered then continue end
        A.maxSpeed = math.max(A.maxSpeed, st.speed)
        if st.speed > A.limit + TOL and (not A.warnedAt or CurTime() - A.warnedAt > 10) then
            A.warnedAt = CurTime()
            A.violations = A.violations + 1
            say(cid, Format("Превышение! Не более %d км/ч, у вас %.0f.", A.limit, st.speed))
            if A.violations == 1 then I.Violation(cid, Format("превышение скорости при движении по разрешению (%.0f км/ч)", st.speed)) end
        end
    end
    for cid, p in pairs(I.Permits) do if p.expires < CurTime() then I.Permits[cid] = nil end end

    -- Starting off under a stop indication without leave. Moving with "0" while
    -- braking is normal; only a train that stood still under it and then moves is.
    for _, c in ipairs(Line.GetConsists()) do
        local st = Line.GetState(c)
        if not st or not IsValid(st.driver) or not st.onTrack then continue end
        local mem = Line.GetMemory(c)
        local ars = I.ArsStop(st)
        local onMission = Dispatcher.Rescue and Dispatcher.Rescue.CoversOCh and Dispatcher.Rescue.CoversOCh(c.id)
        if not ars or I.Active[c.id] or onMission or exempt(c, st) then
            mem.arsHeld = nil
            continue
        end
        if st.stopped then
            if mem.arsHeld ~= st.head then mem.arsHeld = st.head end   -- per cab: changing ends is a new start
        elseif mem.arsHeld == st.head and st.speed > START_SPEED then
            mem.arsHeld = nil
            say(c.id, Format("Нарушение: движение при запрещающем показании АРС («%s») без разрешения ДЦХ. Остановитесь и запросите !пс.", ars))
            I.Violation(c.id, Format("движение при «%s» без разрешения", ars))
        end
    end
end)

hook.Add("Dispatcher_Rekey", "Dispatcher_Invite", function(old, new)
    I.Active[new], I.Active[old] = I.Active[old], nil
    I.Permits[new], I.Permits[old] = I.Permits[old], nil
end)
