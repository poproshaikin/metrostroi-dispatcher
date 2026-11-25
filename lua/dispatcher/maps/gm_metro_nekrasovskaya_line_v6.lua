-- Nekrasovskaya line (workshop 2091799900): full markup, exported with !экспорт.
-- 8 stations 101..108, two platforms each. Platform 1 (path I): 101 -> 108, platform 2 (path II): 108 -> 101.
-- Data saved on a server in data/dispatcher/ takes priority over this file.
return {
    names = {
        [101] = "Некрасовка", -- the map's own config has a typo ("Некрасовска")
    },

    -- Stations with a crossover / dead end for turnback orders (more come from sidings below)
    turnbacks = { 102, 106 },

    -- Turnback dead ends (Metrostroi track path + stop mark x, m) and turns on the platform
    sidings = {
        { name = "Лухмановская т3", station = 102, from = 2, path = 5, x = 346.7965861393, dir = false },
        { name = "Лухмановская т4", station = 102, from = 2, path = 6, x = 219.84246885223, dir = true },
        { name = "Некрасовка т3", station = 101, from = 2, path = 3, x = 13.79203096962, dir = false },
        { name = "Некрасовка т4", station = 101, from = 2, path = 4, x = 213.76426209755, dir = true },
        { name = "Нижегородская т3", station = 108, from = 1, path = 1, x = 13630.707987815, dir = true },
        -- crossover before platform I back to path II
        { name = "Оборот с платформы ст. Косино", kind = "platform", station = 104, from = 1 },
        { name = "Оборот с платформы ст. Окская", kind = "platform", station = 106, from = 1 },
    },

    -- Stop boards relative to the platform end, m (negative = before it)
    stopMarks = {
        default = -6.489357966615,
        ["104/1"] = -5.1480965217588,
        ["105/1"] = -2.7424206871037,
        ["105/2"] = -2.3830897132875,
        ["106/1"] = -2.6071700763714,
        ["106/2"] = -2.7851776702878,
        ["107/1"] = -2.854898741627,
        ["107/2"] = -2.0967598068237,
        ["108/1"] = -2.7118181945807,
        ["108/2"] = -2.3819365859985,
    },

    -- Depot Руднево: tracks are world segments start (a, gate side) -> end (b)
    depotExit = "102/1",   -- out of the depot onto Лухмановская, path I
    depotEntry = "102/2",  -- into the depot from Лухмановская, path II
    depotTracks = {
        { name = "1", a = { -5271.05, -3902.42, -13039.14 }, b = { -11260.51, -3902.35, -13039.13 } },
        { name = "2", a = { -5281.39, -3435.38, -13039.28 }, b = { -11231.05, -3434.38, -13038.93 } },
        { name = "3", a = { -5277.45, -3115.33, -13039.13 }, b = { -11225.78, -3114.3, -13039.45 } },
        { name = "4", a = { -5286.68, -2795.39, -13039.14 }, b = { -11228.13, -2795.09, -13038.83 } },
        { name = "5", a = { -5284.28, -2475.35, -13039.17 }, b = { -11232.55, -2475.09, -13039.38 } },
    },
}
