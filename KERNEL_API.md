# SimulationKernel API Documentation

## Overview

`SimulationKernel.jl` — главное ядро симуляции, управляющее жизненным циклом систем-плагинов, агрегирующее производные для адаптивного шага Clock, вызывающее `flush!` шины событий на каждом шаге и обеспечивающее атомарное сохранение/восстановление полного состояния.

---

## Жизненный цикл ядра

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SIMULATION LIFECYCLE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. CONSTRUCTION                                                             │
│     kernel = SimulationKernel(start_time, end_time, initial_dt; config)      │
│     └─ Создаёт clock, bus, пустой вектор systems                             │
│                                                                              │
│  2. ADD SYSTEMS                                                              │
│     add_system!(kernel, sys1)                                                │
│     add_system!(kernel, sys2)                                                │
│     └─ Системы добавляются в вектор, ещё не инициализированы                 │
│                                                                              │
│  3. RUN / STEP                                                               │
│     run!(kernel, start_time, end_time)  ИЛИ  step!(kernel)                   │
│     │                                                                          │
│     ├─ 3a. INITIALIZATION (первый вызов)                                     │
│     │    for sys in systems: init!(sys, clock, bus)                          │
│     │    └─ Системы регистрируют handlers в bus                              │
│     │                                                                          │
│     ├─ 3b. MAIN LOOP (каждый шаг)                                            │
│     │    1. derivative = _aggregate_derivative(kernel, t)                    │
│     │    2. clock_status = step!(clock, derivative)                          │
│     │    3. flush!(bus, t)                                                   │
│     │    4. for sys in systems: step!(sys, dt, t)                            │
│     │    5. Check divergence                                                 │
│     │    6. Maybe checkpoint                                                 │
│     │                                                                          │
│     └─ 3c. SHUTDOWN (при завершении/ошибке)                                  │
│          for sys in systems: shutdown!(sys)                                  │
│                                                                              │
│  4. CHECKPOINTING (периодически)                                             │
│     save_checkpoint!(kernel, path)                                           │
│     └─ Атомарная запись: temp → rename                                       │
│                                                                              │
│  5. RECOVERY (опционально)                                                   │
│     load_checkpoint!(kernel, path)                                           │
│     └─ Восстановление clock, bus, systems                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Контракты интерфейсов

### ISystem (интерфейс системы-плагина)

Все системы должны наследовать от `AbstractSystem` и реализовать 6 методов:

| Метод | Сигнатура | Назначение |
|-------|-----------|------------|
| `init!` | `init!(sys, clock, bus) -> Nothing` | Инициализация перед первым шагом |
| `step!` | `step!(sys, dt::Float64, t::Float64) -> Nothing` | Выполнение одного шага |
| `max_derivative` | `max_derivative(sys, t::Float64) -> Float64` | Оценка производной для адаптивного dt |
| `shutdown!` | `shutdown!(sys) -> Nothing` | Завершение работы, освобождение ресурсов |
| `save_state` | `save_state(sys) -> NamedTuple` | Сохранение состояния (JLD2-совместимое) |
| `load_state!` | `load_state!(sys, data::NamedTuple) -> Nothing` | Восстановление состояния |

**Требования:**
- `save_state` должен возвращать только JLD2-совместимые типы (`Float64`, `Int`, `String`, `Symbol`, `Vector`, `NamedTuple`)
- Запрещены функции, замыкания, потоки в сохраняемом состоянии
- `max_derivative` должна возвращать конечное неотрицательное число (NaN/Inf → дивергенция)

---

### SimulationKernel (публичный API)

#### Конструктор

```julia
SimulationKernel(
    start_time::Float64,
    end_time::Float64,
    initial_dt::Float64;
    config::KernelConfig = KernelConfig()
)
```

#### KernelConfig

```julia
struct KernelConfig
    checkpoint_interval::Float64      # дни сим. времени (по умолчанию 1.0)
    max_steps_between_cp::Int         # макс. шагов без чекпоинта (по умолчанию 5000)
    divergence_threshold::Float64     # порог дивергенции (по умолчанию 1e10)
end
```

#### Методы ядра

| Метод | Сигнатура | Описание |
|-------|-----------|----------|
| `add_system!` | `add_system!(kernel, sys::AbstractSystem) -> Nothing` | Добавить систему (до инициализации) |
| `run!` | `run!(kernel, start_time, end_time) -> SimulationResult` | Запустить симуляцию |
| `step!` | `step!(kernel) -> StepStatus` | Один шаг симуляции |
| `save_checkpoint!` | `save_checkpoint!(kernel, path::String) -> String` | Сохранить состояние |
| `load_checkpoint!` | `load_checkpoint!(kernel, path::String) -> Nothing` | Загрузить состояние |
| `get_kernel_state` | `get_kernel_state(kernel) -> NamedTuple` | Текущее состояние |
| `reset_kernel!` | `reset_kernel!(kernel) -> Nothing` | Сброс ядра |

---

## Порядок вызовов (строгий)

### Нормальный запуск

```julia
kernel = SimulationKernel(0.0, 30.0, 0.1)
add_system!(kernel, sys1)
add_system!(kernel, sys2)

# При первом step! или run!:
#   1. init!(sys1, clock, bus)
#   2. init!(sys2, clock, bus)
#   3. kernel.initialized = true

result = run!(kernel, 0.0, 30.0)

# В конце run! автоматически:
#   1. shutdown!(sys1)
#   2. shutdown!(sys2)
```

### Чекпоинт roundtrip

```julia
# Шаг 1: Запуск и сохранение
kernel = SimulationKernel(0.0, 30.0, 0.1)
add_system!(kernel, sys)
run!(kernel, 0.0, 10.0)  # Достижение t=10.0
path = save_checkpoint!(kernel, "my_checkpoint")

# Шаг 2: Модификация (для демонстрации)
original_state = sys.state
sys.state += 1000.0  # Искажаем состояние

# Шаг 3: Восстановление
kernel2 = SimulationKernel(0.0, 30.0, 0.1)
sys2 = MySystem(...)  # Та же структура
add_system!(kernel2, sys2)
load_checkpoint!(kernel2, path)

# Проверка:
@assert kernel2.clock.current_time ≈ 10.0
@assert sys2.state ≈ original_state

# Продолжение симуляции:
run!(kernel2, 10.0, 30.0)
```

---

## Формат чекпоинта

Чекпоинт сохраняется в файл `.jld2.zst` со следующей структурой:

```julia
Dict(
    "clock_state" => NamedTuple(
        current_time::Float64,
        current_dt::Float64,
        min_dt::Float64,
        max_dt::Float64,
        tolerance::Float64,
        start_time::Float64,
        end_time::Float64,
        step_status::Int,
        checkpoint_id::String,
        event_counter::Int,
        events::Vector{Tuple{Float64, String, Dict{String, Any}}}
    ),
    
    "bus_state" => NamedTuple(
        subscriptions::Vector{SubscriptionDescriptor},
        pending::Vector{NamedTuple},  # сериализованные сигналы
        inboxes::Dict{Symbol, Vector{NamedTuple}},
        stats::Dict{Symbol, Int}
    ),
    
    "system_states" => Vector{NamedTuple}(
        (type = "MySystem", data = NamedTuple(...)),
        ...
    ),
    
    "step_count" => Int,
    "last_checkpoint_time" => Float64
)
```

**Атомарность записи:**
1. Сериализация во временный файл `path.jld2.zst.tmp`
2. `mv(temp, path; force=true)` — атомарный rename
3. При ошибке временный файл удаляется

---

## Обработка ошибок

### Divergence (NaN/Inf)

Если `max_derivative` любой системы возвращает NaN/Inf:

1. Ядро обнаруживает дивергенцию в `_aggregate_derivative` или после `step!` систем
2. Статус шага устанавливается в `STEP_DIVERGENCE`
3. Вызывается `_emergency_checkpoint!` с меткой времени
4. Вызывается `shutdown!` для всех систем
5. `run!` возвращает `SimulationResult` со статусом `STEP_DIVERGENCE`

```julia
mutable struct DivergentSystem <: AbstractSystem
    divergence_time::Float64
end

function max_derivative(sys::DivergentSystem, t::Float64)::Float64
    if t > sys.divergence_time
        return NaN  # Это вызовет STEP_DIVERGENCE
    end
    return 1.0
end
```

### Ошибка в step! системы

Если `step!(sys, dt, t)` бросает исключение:

1. Исключение ловится в цикле `for sys in kernel.systems`
2. Логируется ошибка с указанием системы
3. Возвращается статус `STEP_ERROR`
4. Вызывается аварийный чекпоинт
5. Graceful shutdown всех систем

---

## Производительность

### Требования

- 10⁴ шагов с 3 mock-системами ≤ 3 сек
- Аллокации ≤ 40 MB
- `@code_warntype step!` без предупреждений `Any`

### Рекомендации по оптимизации

1. **Типостабильность**: Все системы `<: AbstractSystem`, методы с конкретными типами
2. **Избегание аллокаций в hot path**: 
   - Не создавать новые объекты в `step!`
   - Использовать `Ref` для мутаций в замыканиях
3. **Агрегация производных**: 
   ```julia
   _aggregate_derivative(kernel, t) = maximum(s -> max_derivative(s, t), kernel.systems; init=0.0)
   ```

---

## Пример использования

```julia
using .SimulationKernel
using .ISystem

# 1. Определяем систему
mutable struct MySystem <: AbstractSystem
    state::Float64
    rate::Float64
end

function init!(sys::MySystem, clock, bus)
    @info "MySystem initialized"
end

function step!(sys::MySystem, dt, t)
    sys.state += sys.rate * dt
end

function max_derivative(sys::MySystem, t)
    return abs(sys.rate)
end

function shutdown!(sys::MySystem)
    @info "MySystem shutdown"
end

function save_state(sys::MySystem)
    return (state = sys.state, rate = sys.rate)
end

function load_state!(sys::MySystem, data)
    sys.state = data.state
    sys.rate = data.rate
end

# 2. Создаём ядро и запускаем
sys = MySystem(0.0, 1.0)
config = KernelConfig(checkpoint_interval=5.0)
kernel = SimulationKernel(0.0, 30.0, 0.1; config=config)
add_system!(kernel, sys)

result = run!(kernel, 0.0, 30.0)

println("Status: $(result.status)")
println("Steps: $(result.total_steps)")
println("Time: $(result.elapsed_wall_time)s")
```

---

## Интеграция с реальными системами

### Чек-лист подключения

1. [ ] Система наследует от `AbstractSystem`
2. [ ] Реализованы все 6 методов интерфейса
3. [ ] `save_state` возвращает только JLD2-совместимые типы
4. [ ] `max_derivative` всегда возвращает конечное число ≥ 0
5. [ ] Нет глобальных мутаций в `step!`
6. [ ] Протестирован roundtrip: `save_state → load_state! → step!`

### Проверки перед Фазой 1

- [ ] Lifecycle тест пройден: `init → step! (N) → save → load → step! → shutdown`
- [ ] Агрегация производных корректна для N систем
- [ ] Чекпоинт roundtrip восстанавливает состояние с точностью ±1e-12
- [ ] Divergence детектируется при NaN/Inf в любой системе
- [ ] Производительность: 10⁴ шагов ≤ 3 сек
- [ ] `@code_warntype` на `step!` не показывает `Any`

---

## Экспорт symbols

```julia
export SimulationKernel, KernelConfig, SimulationResult, StepStatus
export add_system!, run!, step!, save_checkpoint!, load_checkpoint!
export get_kernel_state, reset_kernel!
```
