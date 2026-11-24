# Metrostroi Dispatcher

Диспетчер-бот (ДЦХ) для Metrostroi: смены, график, приказы, разбор смены. Работает в синглплеере и на сервере, только Lua, только серверная часть.

> Статус: этап 1 в работе. Готов слой `Line` (модель линии); график, смена и разбор — дальше.

## Структура

```
lua/autorun/server/dispatcher_init.lua   точка входа, грузит модули после Initialize
lua/dispatcher/line.lua                  Line: фасад над API Метростроя (станции, составы, позиция)
lua/dispatcher/debug.lua                 отладочные команды
lua/dispatcher/maps/<map>.lua            опциональный конфиг карты (поправки названий и т.п.)
```

Планируется: `schedule.lua` (график), `shift.lua` (смена, state machine), `report.lua` (метрики и разбор), `comms.lua` (сообщения `[ДЦХ]`, команды `!понял`), `orders.lua` (приказы).

## Разработка

Клонировать в `garrysmod/addons/` (или сделать туда junction/symlink). GMod сам перезагружает изменённые Lua-файлы прямо в игре.

Отладка:

| Команда | |
|---|---|
| `dispatcher_stations` | станции и платформы, как их видит `Line` (вывод в консоль) |
| `dispatcher_where` | состояние твоего состава |
| `dispatcher_debug 1` | состояние на экране раз в 0.5 с + прибытие/отправление в чат |
| `lua_run PrintTable(Dispatcher.Line.GetPlayerState(Entity(1)))` | сырой стейт |

## Line API

Модули выше `Line` не трогают Метрострой напрямую — только это API. Расстояния в метрах вдоль пути, скорость в км/ч.

```lua
Line.GetStations()          -- { Station, ... } по порядку линии
Line.GetStation(id)         -- Station
Line.NextPlatform(platform) -- следующая платформа по ходу (тот же индекс пути), nil на конечной
Line.OrderDir(index)        -- +1 / -1: куда по списку станций идёт путь index

Line.GetConsists()          -- { Consist, ... }  (состав = электрически сцепленные вагоны)
Line.GetPlayerConsist(ply)  -- Consist | nil
Line.GetState(consist)      -- State | nil
Line.GetPlayerState(ply)    -- State | nil
```

```lua
Station  = { id = 101, name = "Некрасовка", order = 1, platforms = { [1] = Platform, [2] = Platform } }
Platform = { station, index, xStart, xEnd, length, terminal, ent }   -- xEnd = знак остановки

State = {
    consist, head, driver,   -- головной вагон и машинист (Player | nil)
    wagons     = 5,
    speed      = 54.2,  stopped = false,
    doors      = { left = false, right = true },
    onTrack    = true,       -- false: вне путевой сети
    at         = Platform,   -- платформа, вдоль которой сейчас голова состава
    stop       = Platform,   -- ближайший знак остановки впереди (может быть = at)
    distToStop = 312.5,      -- метры до знака; nil, если неизвестно (другой участок пути)
    last       = Platform,   -- где последний раз останавливался
}
```

События (только для составов с машинистом):

```lua
hook.Add("Dispatcher_Arrive", "my", function(consist, state, platform, stopError) end)
-- stopError: метры до знака остановки при остановке (+ недоезд, - переезд), nil если неизвестно
hook.Add("Dispatcher_Depart", "my", function(consist, state, platform) end)
```

## Карты

Работает на любой карте, где у платформ (`gmod_track_platform`) есть путевая сеть Метростроя. Названия станций берутся из `Metrostroi.StationConfigurations` карты, поправить можно в `lua/dispatcher/maps/<map>.lua`. Проверяется на `gm_metro_nekrasovskaya_line_v6`.
