--------------------------------------------------------------------------------
-- Metrostroi Dispatcher — client: visible marks (!метки / dispatcher_marks 1)
--   green  = depot track start, red = depot track end,
--   orange = turnback siding, blue = platform stop marks
--------------------------------------------------------------------------------
local cvMarks = CreateClientConVar("dispatcher_marks", "0", true, false, "Show dispatcher marks in the world")

local marks = {}
local COLORS = {
    [1] = Color(60, 220, 90),
    [2] = Color(230, 60, 60),
    [3] = Color(255, 160, 40),
    [4] = Color(80, 150, 255),
}
local MAX_DIST = 4000   -- units: draw only nearby marks

net.Receive("dispatcher_marks", function()
    marks = {}
    for i = 1, net.ReadUInt(12) do
        marks[i] = { pos = net.ReadVector(), text = net.ReadString(), kind = net.ReadUInt(3) }
    end
end)

local function request()
    net.Start("dispatcher_marks") net.SendToServer()
end

concommand.Add("dispatcher_marks_toggle", function()
    RunConsoleCommand("dispatcher_marks", cvMarks:GetBool() and "0" or "1")
end)

cvars.AddChangeCallback("dispatcher_marks", function(_, _, new)
    if tobool(new) then request() end
end, "dispatcher_marks")

timer.Create("dispatcher_marks_refresh", 10, 0, function()
    if cvMarks:GetBool() then request() end
end)
hook.Add("InitPostEntity", "dispatcher_marks", function()
    if cvMarks:GetBool() then timer.Simple(5, request) end
end)

-- Clock check (!часы): the server asks, we answer with what the station clocks show here
net.Receive("dispatcher_clock", function()
    local sync = Metrostroi and Metrostroi.GetSyncTime and Metrostroi.GetSyncTime() or -1
    net.Start("dispatcher_clock")
    net.WriteDouble(sync)
    net.WriteDouble(os.time())
    net.WriteDouble(CurTime())
    net.SendToServer()
end)

hook.Add("PostDrawTranslucentRenderables", "dispatcher_marks", function(depth, sky)
    if sky or not cvMarks:GetBool() or #marks == 0 then return end
    local eye = EyePos()
    for _, m in ipairs(marks) do
        if m.pos:DistToSqr(eye) > MAX_DIST * MAX_DIST then continue end
        local col = COLORS[m.kind] or color_white
        local top = m.pos + Vector(0, 0, 140)
        render.SetColorMaterial()
        render.DrawBox(m.pos + Vector(0, 0, 70), Angle(0, 0, 0), Vector(-2, -2, -70), Vector(2, 2, 70), col)
        render.DrawSphere(top, 6, 8, 8, col)

        -- text billboard facing the viewer
        local ang = Angle(0, (top - eye):Angle().y, 0)
        ang:RotateAroundAxis(ang:Up(), -90)
        ang:RotateAroundAxis(ang:Forward(), 90)
        cam.Start3D2D(top + Vector(0, 0, 16), ang, 0.15)
            draw.SimpleTextOutlined(m.text, "DermaLarge", 0, 0, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 2, color_black)
        cam.End3D2D()
    end
end)
