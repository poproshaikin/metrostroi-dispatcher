--------------------------------------------------------------------------------
-- Dispatcher.Invite — invitation signal (пригласительный, ПС) on request.
--
-- !пригласительный at a closed signal: the dispatcher looks at WHY it is closed
-- and opens the invitation only when there is a reason:
--   * a permit given by a scenario / order (I.Permit) — rescue, maneuvers, ...
--   * the block ahead is held by a broken (dead) train — approach it to couple
--   * the block shows occupied but no train is in it — a track circuit fault
-- It refuses when a working train is ahead (wait), the signal was closed on
-- purpose, or the route is simply not set (!маршрут).
--
-- Then it watches the speed until the train has passed the block (next signal):
-- not above dispatcher_invite_speed (20 km/h), ready to stop.
--------------------------------------------------------------------------------
local Line, G, R = Dispatcher.Line, Dispatcher.Graph, Dispatcher.Routes
local I = Dispatcher.Invite or {}
Dispatcher.Invite = I

local cvSpeed = CreateConVar("dispatcher_invite_speed", "20", FCVAR_ARCHIVE, "Speed limit under an invitation signal, km/h")

local NEAR       = 60     -- m: stand this close before the signal to ask
local TOL        = 2      -- km/h over the limit before a warning
local ZONE_MAX   = 2000   -- m: watch at most this far past the signal
local EXPIRE     = 600    -- s: an unused invitation is forgotten

I.Permits = I.Permits or {}   -- [cid] = { reason, signal (name or nil = any), expires }
I.Active = I.Active or {}     -- [cid] = { S, reason, limit, zoneEnd, maxSpeed, warnedAt, violations, since }

-- For scenarios: allow cid an invitation (at `signal`, or any if nil) for ttl seconds
function I.Permit(cid, reason, signal, ttl)
    I.Permits[cid] = { reason = reason, signal = signal, expires = CurTime() + (ttl or 1800) }
end
function I.Revoke(cid) I.Permits[cid] = nil end

local function say(cid, text) Dispatcher.Comms.Say(cid, text) end

local function consistOf(ent)
    if not IsValid(ent) then return end
    for _, c in ipairs(Line.GetConsists()) do
        for _, w in ipairs(c.wagons) do if w == ent then return c end end
    end
end

local function isBroken(c)
    for _, w in ipairs(c and c.wagons or {}) do if w.DispatcherBroken then return true end end
    return false
end

-- The next signal past S in its direction on the same path (end of the block)
local function nextSignalX(S)
    local best
    for _, S2 in ipairs(S.path.signals) do
        local d = (S2.x - S.x) * S.dir
        if S2 ~= S and S2.dir == S.dir and d > 5 and (not best or d < best) then best = d end
    end
    return math.min(best or ZONE_MAX, ZONE_MAX)
end

--------------------------------------------------------------------------------
-- Why is the signal closed, and is that a reason for an invitation?
-- Returns ok, text   (text = the reason if ok, else why not)
--------------------------------------------------------------------------------
function I.Judge(S, consist)
    local e = S.ent
    local p = I.Permits[consist.id]
    if p and p.expires > CurTime() and (not p.signal or p.signal == S.name) then return true, p.reason end

    if e.Close then return false, "светофор закрыт" end
    -- a route signal with no route standing: set the route, not an invitation
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
    if isBroken(c) then return true, "подъезд к неисправному поезду для сцепки" end
    return false, "впереди поезд, перегон занят. Ожидайте открытия светофора"
end

--------------------------------------------------------------------------------
-- !пригласительный
--------------------------------------------------------------------------------
concommand.Add("dispatcher_invite", function(ply)
    if not IsValid(ply) then return end
    local c = Line.GetPlayerConsist(ply)
    local st = c and Line.GetState(c)
    if not st or st.driver ~= ply then Dispatcher.Chat(ply, "[ДЦХ] Сядьте на место машиниста.") return end
    local a = R.SignalsAhead(st, NEAR, true)[1]
    if not a then Dispatcher.Chat(ply, Format("[ДЦХ] Впереди ближе %d м нет светофора. Подъедьте к нему.", NEAR)) return end
    local S = a.S
    local name = S.name or "?"
    if not st.stopped then say(c.id, Format("Остановитесь у светофора %s, потом запрашивайте.", name)) return end
    if (S.ent.GoodInvationSignal or 0) == 0 then
        say(c.id, Format("На светофоре %s нет пригласительного огня.", name)) return
    end
    if S.ent.InvationSignal then say(c.id, Format("Пригласительный на %s уже открыт.", name)) return end

    local ok, why = I.Judge(S, c)
    if not ok then
        say(c.id, Format("Пригласительный на %s не открываю: %s.", name, why))
        return
    end
    S.ent.InvationSignal = true
    local limit = cvSpeed:GetInt()
    I.Active[c.id] = { S = S, reason = why, limit = limit, zoneEnd = nextSignalX(S), maxSpeed = 0,
                       violations = 0, since = CurTime() }
    say(c.id, Format("Открываю пригласительный на светофоре %s (%s). Следуйте со скоростью не более %d км/ч, с готовностью остановиться.",
        name, why, limit))
    hook.Run("Dispatcher_Invite", c.id, S, why)
end)

--------------------------------------------------------------------------------
-- Speed watch under the invitation
--------------------------------------------------------------------------------
local nextTick = 0
hook.Add("Think", "Dispatcher_Invite", function()
    if CurTime() < nextTick then return end
    nextTick = CurTime() + 0.5
    for cid, A in pairs(I.Active) do
        local c = Line.GetConsist(cid)
        local st = c and Line.GetState(c)
        if not st or not st.onTrack then I.Active[cid] = nil continue end
        local S = A.S
        local along = (st.path == S.path.raw) and (st.x - S.x) * S.dir or nil
        if along and along > 0 then A.entered = true end

        if A.entered and (not along or along > A.zoneEnd) then
            -- past the block (or onto another path through the switches)
            say(cid, Format("Участок по пригласительному пройден. Наибольшая скорость %.0f км/ч%s.", A.maxSpeed,
                A.violations > 0 and Format(", превышений: %d", A.violations) or ", без превышений"))
            I.Active[cid] = nil
            continue
        end
        if not A.entered then
            if CurTime() - A.since > EXPIRE then I.Active[cid] = nil end
            continue
        end
        A.maxSpeed = math.max(A.maxSpeed, st.speed)
        if st.speed > A.limit + TOL and (not A.warnedAt or CurTime() - A.warnedAt > 10) then
            A.warnedAt = CurTime()
            A.violations = A.violations + 1
            say(cid, Format("Превышение по пригласительному! Не более %d км/ч, у вас %.0f.", A.limit, st.speed))
        end
    end
    for cid, p in pairs(I.Permits) do if p.expires < CurTime() then I.Permits[cid] = nil end end
end)

hook.Add("Dispatcher_Rekey", "Dispatcher_Invite", function(old, new)
    I.Active[new], I.Active[old] = I.Active[old], nil
    I.Permits[new], I.Permits[old] = I.Permits[old], nil
end)
