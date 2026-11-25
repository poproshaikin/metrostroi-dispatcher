--------------------------------------------------------------------------------
-- Dispatcher.Graph — the track network as a graph, from Metrostroi's own data.
--
-- Metrostroi keeps tracks as separate paths (arrays of nodes, x in metres). The
-- end of one path joins a point on another one: that is a crossover, a dead end
-- siding or a branch, and a switch stands there. Metrostroi records these joins
-- in node.branches when the map loads; we turn them into:
--
--   Path     { id, length, kind, junctions = { Junction... sorted by hostX }, ends = { start = J|nil, ["end"] = J|nil },
--              platforms = { Platform... }, signals = { Signal... sorted by x } }
--     kind:  "main"      has platforms
--            "crossover" both ends join other paths
--            "siding"    one end joins, the other is a dead end
--            "isolated"  nothing joins
--   Junction { host, hostX, branch, branchEnd ("start"|"end"), branchX, facing, switch, switchName }
--     A train on `host` moving towards +x (facing = 1) or -x (facing = -1) can
--     diverge into `branch` here, when the switch is set to the branch.
--   Signal   { ent, name, path, x, dir (+1/-1: the direction it governs), routes = { {name, next, switches = {[name]="alt"|"main"}, manual} } }
--
-- Phase 1: build + inspect (dispatcher_graph, marks). Route search comes next.
--------------------------------------------------------------------------------
local Line = Dispatcher.Line
local G = Dispatcher.Graph or {}
Dispatcher.Graph = G
G.VERSION = 7 -- bump when the graph's structure changes (rebuilds a cached one after a reload)

local U2M = 0.01905
local SWITCH_RADIUS = 50   -- m: a switch this close to a junction belongs to it
local DEPOT_LINK_RADIUS = 300   -- m: a path end this close to a depot track leads into the depot

local function dirAt(path, i)
    local n = path[i]
    if n and n.dir and n.dir:LengthSqr() > 0 then return n.dir end
    local p = path[i - 1]
    return p and p.dir or Vector(1, 0, 0)
end

local function horiz(v) return Vector(v.x, v.y, 0):GetNormalized() end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------
local function findSwitch(hostPath, hostX, worldPos)
    local best, bestD
    for _, sw in ipairs(ents.FindByClass("gmod_track_switch")) do
        local tp = sw.TrackPosition
        local d
        if tp and tp.path == hostPath then
            d = math.abs(tp.x - hostX)
        else
            d = sw:GetPos():Distance(worldPos) * U2M
        end
        if d <= SWITCH_RADIUS and (not bestD or d < bestD) then best, bestD = sw, d end
    end
    return best
end

function G.Build()
    local paths = Metrostroi.Paths
    if not paths then return false end
    local g = { paths = {}, junctions = {}, signals = {}, src = paths, version = G.VERSION }

    for id, path in pairs(paths) do
        if #path < 2 then continue end
        g.paths[id] = { id = id, raw = path, length = path.length or path[#path].x,
                        junctions = {}, ends = {}, platforms = {}, signals = {} }
    end

    -- Joins: every path end that lies on another path
    for id, P in pairs(g.paths) do
        local path = P.raw
        for _, endName in ipairs({ "start", "end" }) do
            local node = endName == "start" and path[1] or path[#path]
            for _, b in ipairs(node.branches or {}) do
                local hostNode = b[2]
                local H = hostNode and hostNode.path and g.paths[hostNode.path.id]
                if not H or H == P then continue end
                -- exact x on the host: the host node's branch entry that points back at us
                local hostX = hostNode.x
                for _, hb in ipairs(hostNode.branches or {}) do
                    if hb[2] == node then hostX = hb[1] end
                end
                -- direction the branch path leaves the junction vs the host's +x direction
                local leave = endName == "start" and dirAt(path, 1) or -dirAt(path, #path - 1)
                local hdir = dirAt(H.raw, hostNode.id or 1)
                local facing = horiz(leave):Dot(horiz(hdir)) >= 0 and 1 or -1
                local sw = findSwitch(H.raw, hostX, node.pos)
                local J = {
                    host = H, hostX = hostX, branch = P, branchEnd = endName,
                    branchX = endName == "start" and 0 or P.length, facing = facing,
                    switch = sw, switchName = IsValid(sw) and sw.Name ~= "" and sw.Name or nil,
                    pos = node.pos,
                }
                table.insert(H.junctions, J)
                P.ends[endName] = J
                g.junctions[#g.junctions + 1] = J
            end
        end
    end
    for _, P in pairs(g.paths) do
        table.sort(P.junctions, function(a, b) return a.hostX < b.hostX end)
    end

    -- Platforms and sidings on paths
    for _, st in ipairs(Line.GetStations()) do
        for _, pl in pairs(st.platforms) do
            local P = pl.path and g.paths[pl.path.id]
            if P then table.insert(P.platforms, pl) end
        end
    end

    -- Signals with their routes
    for _, sig in ipairs(ents.FindByClass("gmod_track_signal")) do
        local tp = sig.TrackPosition
        local P = tp and tp.path and g.paths[tp.path.id]
        if not P then continue end
        -- dir: the travel direction it governs. Metrostroi's own TrackDir (true = for
        -- trains running +x: the train-ahead trace in sv_util picks signals by it).
        -- TrackPosition.forward only reflects the model's angle and can be either way.
        local dir
        if sig.TrackDir ~= nil then dir = sig.TrackDir and 1 or -1 else dir = tp.forward and 1 or -1 end
        local S = { ent = sig, name = sig.Name, path = P, x = tp.x, dir = dir, routes = {} }
        for k, r in ipairs(sig.Routes or {}) do
            local sws, order = {}, {}
            for _, s in ipairs(string.Explode(",", r.Switches or "")) do
                if s ~= "" then
                    sws[s:sub(1, -2)] = (s:sub(-1) == "-") and "alt" or "main"
                    order[#order + 1] = s:sub(1, -2)
                end
            end
            local depotList = sig.Name and ((Dispatcher.MapConfig or {}).depotRoutes or {})[sig.Name]
            S.routes[k] = { index = k, name = r.RouteName, next = r.NextSignal, switches = sws, order = order, manual = r.Manual == true,
                            depot = depotList ~= nil and table.HasValue(depotList, k) }   -- into the depot (no signalling there)
        end
        table.insert(P.signals, S)
        g.signals[#g.signals + 1] = S
    end
    for _, P in pairs(g.paths) do
        table.sort(P.signals, function(a, b) return a.x < b.x end)
    end

    -- Links from signal routes. The joins above only know where the END of a path
    -- meets another path; ladders inside a throat (Некрасовка: from path II via
    -- NS2 to dead end 4, then NS4/NS3 over to dead end 3) are not separate paths
    -- in the track data. Signal routes do describe them: "from NS14 to NST3 with
    -- NS2-, NS4+, NS5-". Every route to a named next signal = a way from the
    -- signal's path to the next signal's path, with the switch positions to set.
    local byName = {}
    for _, S in ipairs(g.signals) do if S.name then byName[S.name] = S end end
    g.links = {}
    for _, S in ipairs(g.signals) do
        for _, r in ipairs(S.routes) do
            local T = r.next and byName[r.next]
            if T and T ~= S then
                local L = { from = S, to = T, route = r }
                r.target = T
                g.links[#g.links + 1] = L
                S.path.links = S.path.links or {}
                table.insert(S.path.links, L)
            elseif r.next == "X" and #r.order > 0 then
                -- a route with no signal after it: where it leads is unknown (the
                -- ladders are not in the track data). Only a hint: its last switch's path.
                local sw = Metrostroi.GetSwitchByName(r.order[#r.order])
                local tp = IsValid(sw) and sw.TrackPosition
                local V = tp and tp.path and g.paths[tp.path.id]
                if V and V ~= S.path then r.via = V end
            end
        end
    end

    -- Which paths can be reached from which (directly: a join or a signal route)
    for _, P in pairs(g.paths) do P.reach = {} end
    for _, J in ipairs(g.junctions) do
        J.host.reach[J.branch.id] = true
        J.branch.reach[J.host.id] = true
    end
    for _, L in ipairs(g.links) do
        if L.from.path ~= L.to.path then L.from.path.reach[L.to.path.id] = true end
    end

    -- Path ends that stop short of the depot: depot tracks are usually not in the
    -- track data (Nekrasovka), so the line's track just ends there. Such an end is
    -- the way into / out of the depot, and the path can still serve as a turnback
    -- dead end (Лухмановская т3/т4).
    local D = Dispatcher.Depot
    local depotPts = {}
    if D then
        for _, t in ipairs(D.Tracks()) do
            if t.a then depotPts[#depotPts + 1] = t.a end
            if t.b then depotPts[#depotPts + 1] = t.b end
        end
    end
    for _, P in pairs(g.paths) do
        P.depotEnds = {}
        for _, e in ipairs({ "start", "end" }) do
            if P.ends[e] or #depotPts == 0 then continue end
            local pos = (e == "start" and P.raw[1] or P.raw[#P.raw]).pos
            for _, dp in ipairs(depotPts) do
                -- same level (maps are multi-storey: Нижегородская's dead end is ~200 m
                -- from the depot too, but 70 m higher), horizontally close
                local flat = Vector(pos.x - dp.x, pos.y - dp.y, 0):Length() * U2M
                if math.abs(pos.z - dp.z) * U2M < 3 and flat < DEPOT_LINK_RADIUS then
                    P.depotEnds[e] = true
                    break
                end
            end
        end
    end

    -- Kinds
    for _, P in pairs(g.paths) do
        local s, e = P.ends.start, P.ends["end"]
        local toDepot = next(P.depotEnds) ~= nil
        if #P.platforms > 0 then P.kind = "main"
        elseif s and e then P.kind = "crossover"
        elseif (s or e) and toDepot then P.kind = "depotlink"
        elseif s or e then P.kind = "siding"
        else P.kind = "isolated" end
    end

    G.g = g
    return true
end

function G.Get()
    if not G.g or G.g.src ~= Metrostroi.Paths or G.g.version ~= G.VERSION then
        if not G.Build() then return end
    end
    return G.g
end

--------------------------------------------------------------------------------
-- Describe (debug)
--------------------------------------------------------------------------------
local KIND = { main = "главный", crossover = "съезд", siding = "тупик/ветка", depotlink = "тупик + выход в депо", isolated = "отдельный" }

local function stationsOn(P)
    local names = {}
    for _, pl in ipairs(P.platforms) do names[#names + 1] = pl.station.name .. " " .. (pl.index == 1 and "I" or "II") end
    return table.concat(names, ", ")
end

local function jText(J, fromBranch)
    local sw = J.switchName or (IsValid(J.switch) and ("#" .. J.switch:EntIndex())) or "нет стрелки"
    if fromBranch then
        return Format("→ путь #%d в x=%.0f м (стрелка %s, съезд при движении %s)", J.host.id, J.hostX, sw,
            J.facing > 0 and "+x" or "-x")
    end
    return Format("x=%.0f м: ответвление на путь #%d (стрелка %s, при движении %s)", J.hostX, J.branch.id, sw,
        J.facing > 0 and "+x" or "-x")
end

function G.Describe()
    local g = G.Get()
    if not g then return { "граф не построен (нет путевой схемы)" } end
    local lines, ids = {}, {}
    for id in pairs(g.paths) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local P = g.paths[id]
        lines[#lines + 1] = Format("Путь #%d: %s, %.0f м%s, светофоров %d", id, KIND[P.kind] or P.kind, P.length,
            #P.platforms > 0 and (" — " .. stationsOn(P)) or "", #P.signals)
        for _, e in ipairs({ "start", "end" }) do
            local J = P.ends[e]
            lines[#lines + 1] = "    " .. (e == "start" and "начало: " or "конец:  ") ..
                (J and jText(J, true) or (P.depotEnds[e] and "→ депо (путей депо нет в схеме)") or "упор / конец схемы")
        end
        for _, J in ipairs(P.junctions) do lines[#lines + 1] = "    " .. jText(J, false) end
        for _, L in ipairs(P.links or {}) do
            if L.to.path ~= P then
                local sws = {}
                for name, pos in SortedPairs(L.route.switches) do sws[#sws + 1] = name .. (pos == "alt" and "-" or "+") end
                lines[#lines + 1] = Format("    маршрут со светофора %s (x=%.0f м): на %s (путь #%d, x=%.0f м) [%s]",
                    L.from.name or "?", L.from.x, L.to.name or "?", L.to.path.id, L.to.x, table.concat(sws, ","))
            end
        end
        local reach = {}
        for rid in SortedPairs(P.reach) do reach[#reach + 1] = "#" .. rid end
        if #reach > 0 then lines[#lines + 1] = "    отсюда можно попасть на: " .. table.concat(reach, ", ") end
        for _, sd in ipairs(Line.GetSidings()) do
            if sd.path and sd.path.id == id then
                lines[#lines + 1] = Format("    оборот: %s, стоп-метка x=%.0f м (после %s, путь %d)", sd.name, sd.xEnd, sd.station.name, sd.from)
            end
        end
    end
    return lines
end

-- Where each position of a named switch leads, from all signal routes through it:
-- { ["main"] = { [pathId] = { signalNames... } }, ["alt"] = {...} }
function G.SwitchOptions(name)
    local g = G.Get()
    local opts = { main = {}, alt = {} }
    if not g then return opts end
    for _, L in ipairs(g.links) do
        local pos = L.route.switches[name]
        if pos then
            local t = opts[pos][L.to.path.id] or {}
            opts[pos][L.to.path.id] = t
            if L.to.name and not table.HasValue(t, L.to.name) then t[#t + 1] = L.to.name end
        end
    end
    return opts
end

local function optText(set)
    local parts = {}
    for pid, names in SortedPairs(set) do
        parts[#parts + 1] = "#" .. pid .. (#names > 0 and (" (" .. table.concat(names, "/") .. ")") or "")
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- Marks for the client (purple): every switch with where each position leads,
-- and joins that have no switch of their own
function G.Marks()
    local g = G.Get()
    local marks = {}
    if not g then return marks end
    local covered = {}
    for _, sw in ipairs(ents.FindByClass("gmod_track_switch")) do
        local name = sw.Name
        if not name or name == "" then continue end
        local o = G.SwitchOptions(name)
        local plus, minus = optText(o.main), optText(o.alt)
        local text = "Стрелка " .. name
        if plus or minus then
            text = text .. ": + → " .. (plus or "прямо") .. ";  − → " .. (minus or "?")
        else
            -- not in any route: fall back to the track join it belongs to
            for _, J in ipairs(g.junctions) do
                if J.switch == sw then text = Format("%s: путь #%d → #%d", text, J.host.id, J.branch.id) break end
            end
        end
        marks[#marks + 1] = { sw:GetPos() + Vector(0, 0, 40), text, 5 }
        covered[sw] = true
    end
    for _, J in ipairs(g.junctions) do
        if not (IsValid(J.switch) and covered[J.switch]) then
            local pos = Metrostroi.GetTrackPosition(J.host.raw, J.hostX) or J.pos
            marks[#marks + 1] = { pos, Format("Соединение путей #%d → #%d (стрелка не найдена)", J.host.id, J.branch.id), 5 }
        end
    end
    return marks
end

concommand.Add("dispatcher_graph", function(ply)
    if IsValid(ply) and not (game.SinglePlayer() or ply:IsSuperAdmin()) then return end
    G.g = nil   -- rebuild: the network may have changed
    for _, l in ipairs(G.Describe()) do Dispatcher.Chat(ply, l, HUD_PRINTCONSOLE) end
    if IsValid(ply) then Dispatcher.Chat(ply, "[Dispatcher] Граф путей — в консоли (~). Стрелки на метках: !метки") end
end)
