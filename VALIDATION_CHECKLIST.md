# Чек-лист ручной валидации SimulationClock

## Предварительные требования

- Julia 1.10+
- Установленные зависимости: `JLD2`, `CodecZstd`, `DataStructures`
- Пустая директория `checkpoints/` или готовность к очистке

---

## 1. Базовый запуск демо

**Команда:**
```bash
cd /workspace
julia --project examples/demo_clock.jl --end 100
```

**Ожидаемые метрики:**
- [ ] Симуляция завершается со статусом `ENDED`
- [ ] Время монотонно возрастает (проверить по логам `TIME_TICK`)
- [ ] Финальное время ≈ 100.0 (±1e-9)
- [ ] Созданы чекпоинты в `checkpoints/` каждые ~30 дней

**Что смотреть в логах:**
- Сообщения `TIME_TICK` с увеличивающимся `t`
- Сообщения `CHECKPOINT_SAVED` с путями к файлам
- Отсутствие `ERROR` и неожиданных `WARN`

---

## 2. Проверка адаптивного шага (уменьшение)

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

clock = SimulationClock(0.0, 50.0, 1.0; tolerance = 1e-3)
initial_dt = clock.current_dt

for i in 1:20
    status = step!(clock, t -> 10.0)  # Жёсткий сигнал
    println("Step $i: dt = $(clock.current_dt), status = $status")
    if clock.current_dt <= initial_dt / 4
        break
    end
end

println("Initial dt: $initial_dt, Final dt: $(clock.current_dt)")
println("Decrease factor: $(initial_dt / clock.current_dt)")
'
```

**Ожидаемые метрики:**
- [ ] `dt` уменьшается минимум в 3 раза
- [ ] Статусы включают `OK` или `MIN_DT_REACHED`
- [ ] Нет `DIVERGENCE`

---

## 3. Проверка адаптивного шага (увеличение)

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

clock = SimulationClock(0.0, 100.0, 1e-5; tolerance = 1e-3, max_dt = 1.0)

for i in 1:50
    status = step!(clock, t -> 1e-5)  # Мягкий сигнал
    if clock.current_dt >= 0.9
        println("Reached max_dt at step $i, dt = $(clock.current_dt)")
        break
    end
end

println("Final dt: $(clock.current_dt)")
@assert clock.current_dt >= 0.9 "dt не достиг max_dt"
'
```

**Ожидаемые метрики:**
- [ ] `dt` растёт до `max_dt` (≥ 0.9)
- [ ] Не превышает `max_dt`

---

## 4. Проверка границ dt

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

# Тест min_dt
clock_min = SimulationClock(0.0, 100.0, 0.1; min_dt = 1e-6)
for i in 1:50
    step!(clock_min, t -> 100.0)
end
@assert clock_min.current_dt >= 1e-6 "dt ниже min_dt!"
println("min_dt test passed: dt = $(clock_min.current_dt)")

# Тест max_dt
clock_max = SimulationClock(0.0, 100.0, 1e-6; max_dt = 1.0)
for i in 1:100
    step!(clock_max, t -> 1e-6)
end
@assert clock_max.current_dt <= 1.0 "dt выше max_dt!"
println("max_dt test passed: dt = $(clock_max.current_dt)")
'
```

**Ожидаемые метрики:**
- [ ] `dt` никогда не выходит за `[1e-6, 1.0]`
- [ ] При достижении `min_dt` генерируется `MIN_DT_WARNING`

---

## 5. Имитация дивергенции (NaN)

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

clock = SimulationClock(0.0, 100.0, 0.1)

println("Testing NaN divergence...")
status = step!(clock, t -> NaN)

println("Status: $status")
@assert status == DIVERGENCE "Ожидался статус DIVERGENCE"
@assert clock.step_status == DIVERGENCE

# Проверка аварийного чекпоинта
emergency_checkpoints = filter(f -> occursin("emergency", f), readdir("checkpoints"))
println("Emergency checkpoints created: $(length(emergency_checkpoints))")
@assert length(emergency_checkpoints) >= 1 "Аварийный чекпоинт не создан"

# Очистка
for f in emergency_checkpoints
    rm(joinpath("checkpoints", f))
end
println("NaN divergence test PASSED")
'
```

**Ожидаемые метрики:**
- [ ] Статус `DIVERGENCE`
- [ ] Создан аварийный чекпоинт с префиксом `emergency_`
- [ ] Лог `DIVERGENCE_WARNING` с `deriv = NaN`

---

## 6. Имитация дивергенции (Inf)

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

clock = SimulationClock(0.0, 100.0, 0.1)

println("Testing Inf divergence...")
status = step!(clock, t -> Inf)

println("Status: $status")
@assert status == DIVERGENCE
println("Inf divergence test PASSED")
'
```

**Ожидаемые метрики:**
- [ ] Статус `DIVERGENCE`
- [ ] Аварийный чекпоинт создан

---

## 7. Проверка чекпоинтов (save → modify → load → compare)

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

clock = SimulationClock(0.0, 365.0, 0.5)

# Продвигаем время
for i in 1:20
    step!(clock, t -> 1e-4)
end

original_state = get_state(clock)
println("Original state: t=$(original_state.current_time), dt=$(original_state.current_dt)")

# Сохраняем
filepath = save_checkpoint(clock; id = "validation_test")
println("Checkpoint saved: $filepath")

# Модифицируем
clock.current_time += 10.0
clock.current_dt *= 5.0
println("Modified: t=$(clock.current_time), dt=$(clock.current_dt)")

# Загружаем
restored = load_checkpoint(filepath)
restored_state = get_state(restored)
println("Restored: t=$(restored_state.current_time), dt=$(restored_state.current_dt)")

# Сравниваем
@assert abs(original_state.current_time - restored_state.current_time) < 1e-9
@assert abs(original_state.current_dt - restored_state.current_dt) < 1e-9
@assert original_state.min_dt == restored_state.min_dt
@assert original_state.max_dt == restored_state.max_dt

println("Checkpoint consistency test PASSED")

# Очистка
rm(filepath)
'
```

**Ожидаемые метрики:**
- [ ] `deep_equal(original_state, restored_state) == true` для всех числовых полей
- [ ] Файл чекпоинта существует после записи
- [ ] Файл удалён после теста

---

## 8. Производительность (10⁵ шагов)

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock
using Dates

clock = SimulationClock(0.0, 10000.0, 0.1)

GC.gc()
start = time()

steps = 0
while steps < 100_000 && clock.step_status != ENDED
    step!(clock, t -> 1e-4)
    steps += 1
end

elapsed = time() - start
println("Steps: $steps")
println("Time: $(round(elapsed, digits=3))s")
println("Steps/sec: $(round(steps/max(elapsed, 1e-6), digits=1))")

@assert elapsed <= 5.0 "Превышен лимит времени (5 сек)"
println("Performance test PASSED")
'
```

**Ожидаемые метрики:**
- [ ] 10⁵ шагов ≤ 5 секунд (放宽 для CI)
- [ ] Аллокации ≤ 50 MB (можно проверить через `@time` или `@allocated`)

---

## 9. Обработка событий

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

events_fired = Int[]

clock = SimulationClock(0.0, 20.0, 1.0)
for t in [5.0, 10.0, 15.0]
    local t_copy = t
    add_event!(clock, t_copy, () -> push!(events_fired, Int(t_copy)))
end

run!(clock, t -> 1e-4)

println("Events fired: $events_fired")
@assert events_fired == [5, 10, 15] "События не сработали в порядке"
println("Event handling test PASSED")
'
```

**Ожидаемые метрики:**
- [ ] Все события выполнены в порядке возрастания времени
- [ ] Статус `EVENT_TRIGGERED` при выполнении callback

---

## 10. Валидация конструктора

**Команда:**
```bash
julia --project -e '
include("src/SimulationClock.jl")
using .SimulationClock

tests = [
    (() -> SimulationClock(-1.0, 10.0, 0.1), "start_time < 0"),
    (() -> SimulationClock(10.0, 5.0, 0.1), "end_time <= start_time"),
    (() -> SimulationClock(0.0, 10.0, 1e-7), "initial_dt < min_dt"),
    (() -> SimulationClock(0.0, 10.0, 11.0), "initial_dt > max_dt"),
]

for (test_fn, desc) in tests
    try
        test_fn()
        println("FAILED: $desc - исключение не брошено")
    catch e
        if e isa AssertionError
            println("PASSED: $desc")
        else
            println("FAILED: $desc - неверный тип исключения: $e")
        end
    end
end
'
```

**Ожидаемые метрики:**
- [ ] Все 4 теста бросают `AssertionError`

---

## Сводный чек-лист

| № | Тест | Статус | Примечание |
|---|------|--------|------------|
| 1 | Базовый запуск демо | ☐ | |
| 2 | Адаптивное уменьшение dt | ☐ | ≥3 раз |
| 3 | Адаптивное увеличение dt | ☐ | до max_dt |
| 4 | Границы dt | ☐ | [min_dt, max_dt] |
| 5 | Дивергенция NaN | ☐ | + аварийный чекпоинт |
| 6 | Дивергенция Inf | ☐ | + аварийный чекпоинт |
| 7 | Чекпоинт consistency | ☐ | save/modify/load/compare |
| 8 | Производительность | ☐ | 10⁵ шагов ≤ 5 сек |
| 9 | Обработка событий | ☐ | FIFO порядок |
| 10 | Валидация конструктора | ☐ | 4 assertion теста |

---

## Troubleshooting

### Ошибка: `UndefVarError: Dates not defined`
**Решение:** Убедитесь, что `using Dates` есть в `SimulationClock.jl`

### Ошибка: `LoadError: ArgumentError: Package JLD2 not found`
**Решение:** 
```bash
julia --project -e 'using Pkg; Pkg.add(["JLD2", "CodecZstd", "DataStructures"])'
```

### Чекпоинты не создаются
**Проверьте:**
- Права на запись в директорию `checkpoints/`
- Наличие места на диске
- Корректность путей (абсолютные vs относительные)

### Логи не выводятся
**Решение:** Установите уровень логирования:
```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Info))
```
