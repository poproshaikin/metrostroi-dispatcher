-- Nekrasovskaya line (workshop 2091799900)
-- 8 stations 101..108, two platforms each. Platform 1: 101 -> 108, platform 2: 108 -> 101.
return {
    names = {
        [101] = "Некрасовка", -- map config has a typo ("Некрасовска")
    },

    -- Intermediate stations with a crossover where a train can turn back
    -- (from switch names in the BSP: ln1..6 = Лухмановская, ok1..2 = Окская).
    turnbacks = { 102, 106 },
}
