# SimulationClock API Documentation

## Обзор

`SimulationClock` — ядро управления симуляционным временем с адаптивным шагом, планировщиком событий и атомарным чекпоинтингом.

## Типы и константы

### StepResult (Enum)

| Статус | Описание |
|--------|----------|
| `OK` | Шаг успешно выполнен |
| `EVENT_TRIGGERED` | Шаг прерван выполнением события |
| `MIN_DT_REACHED` | Достигнут минимальный шаг, принудительное продолжение |
| `ENDED` | Симуляция завершена (достигнуто end_time) |
| `DIVERGENCE` | Обнаружена дивергенция (NaN/Inf в производной) |

### Константы

```julia
const MIN_DT_DEFAULT = 1e-6      # дни
const MAX_DT_DEFAULT = 1.0       # дни
const DT_ADAPTIVE_FACTOR_DOWN = 0.5
const DT_ADAPTIVE_FACTOR_UP = 1.2
const TOLERANCE_SCALE_DOWN = 0.1
const DEFAULT_TOLERANCE = 1e-3
const TIME_EPS = 1e-9            # точность достижения t_end
```

## Структура SimulationClock

```julia
mutable struct SimulationClock
    current_time::Float64      # текущее время симуляции
    current_dt::Float64        # текущий шаг интегрирования
    min_dt::Float64            # минимальный шаг
    max_dt::Float64            # максимальный шаг
    tolerance::Float64         # порог адаптации
    start_time::Float64        # время начала
    end_time::Float64          # время окончания
    step_status::StepResult    # статус последнего шага
    checkpoint_id::String      # ID последнего чекпоинта
    event_queue::PriorityQueue # очередь событий
    event_counter::Int         # счётчик событий
end
```

## Конструктор

```julia
SimulationClock(
    start_time::Float64,           # ≥ 0
    end_time::Float64,             # > start_time
    initial_dt::Float64;           # ∈ [min_dt, max_dt]
    min_dt::Float64 = 1e-6,
    max_dt::Float64 = 1.0,
    tolerance::Float64 = 1e-3,
    events::Vector{Tuple{Float64, Function}} = []
)
```

**Валидация:**
- `start_time >= 0`
- `end_time > start_time`
- `min_dt <= initial_dt <= max_dt`
- `min_dt >= 1e-6`
- `max_dt <= 10.0`

## Основные методы

### step!

```julia
step!(clock::SimulationClock, derivative_func::Function)::StepResult
```

Выполняет один шаг симуляции.

**Параметры:**
- `derivative_func::Function` — `(t::Float64) -> Float64`, возвращает max(|dx/dt|)

**Логика адаптации dt:**
1. Если `|deriv| > tolerance` → `dt *= 0.5`
2. Если `|deriv| < tolerance * 0.1` → `dt *= 1.2` (clamp к max_dt)
3. Если `dt < min_dt` → статус `MIN_DT_REACHED`, шаг = `min_dt`

**Дивергенция:**
- При `NaN` или `Inf` в производной → статус `DIVERGENCE`
- Автоматическое сохранение аварийного чекпоинта

### run!

```julia
run!(clock::SimulationClock, derivative_func::Function; 
     max_steps::Int = 1_000_000)::StepResult
```

Запускает симуляцию до `end_time` или лимита шагов.

### add_event!

```julia
add_event!(
    clock::SimulationClock,
    time::Float64,
    callback::Function;
    callback_id::Union{Nothing, String} = nothing,
    payload::Dict{String, Any} = Dict()
)::String
```

Добавляет событие в очередь. Возвращает `callback_id`.

**Обработка событий:**
- Если событие попадает внутрь шага → шаг разбивается
- События выполняются в порядке возрастания времени
- При совпадении времени → FIFO

### remove_event!

```julia
remove_event!(clock::SimulationClock, callback_id::String)::Bool
```

Удаляет событие по идентификатору.

### get_next_event_time

```julia
get_next_event_time(clock::SimulationClock)::Union{Float64, Nothing}
```

Возвращает время ближайшего события.

## Чекпоинтинг

### save_checkpoint

```julia
save_checkpoint(
    clock::SimulationClock;
    id::Union{Nothing, String} = nothing,
    emergency::Bool = false
)::String
```

**Атомарность:** запись через `temp_file → write → rename`

**Формат:** JLD2 + Zstd сжатие

**Пути:** `checkpoints/sim_{id}_{timestamp}.jld2`

**Сохраняемые поля:**
- Все числовые параметры часов
- Сериализуемые метаданные событий (`EventDescriptor`)
- **НЕ сохраняются:** функции callback

### load_checkpoint

```julia
load_checkpoint(filepath::String)::SimulationClock
```

Загружает состояние. Callbacks нужно восстановить отдельно.

## Утилиты

### reset!

```julia
reset!(clock::SimulationClock; keep_events::Bool = true)
```

Сбрасывает часы к начальному состоянию.

### get_state

```julia
get_state(clock::SimulationClock)::NamedTuple
```

Возвращает копию состояния:
```julia
(current_time, current_dt, min_dt, max_dt, tolerance,
 start_time, end_time, step_status, checkpoint_id, next_event_time)
```

### is_finished

```julia
is_finished(clock::SimulationClock)::Bool
```

Проверяет завершение симуляции.

## EventDescriptor

```julia
struct EventDescriptor
    time::Float64
    callback_id::String
    payload::Dict{String, Any}
end
```

Используется для сериализации метаданных событий.

## Логирование

| Событие | Уровень | Описание |
|---------|---------|----------|
| `TIME_TICK` | Info | Каждый шаг симуляции |
| `STEP_COMPLETED` | Info | Завершение шага |
| `CHECKPOINT_SAVED` | Info | Сохранение чекпоинта |
| `DIVERGENCE_WARNING` | Warn | Обнаружена дивергенция |
| `MIN_DT_WARNING` | Warn | Достигнут минимальный шаг |

## Пример интеграции с ISystem

```julia
# Определение системы
abstract type ISystem end

mutable struct MySystem <: ISystem
    state::Vector{Float64}
    # ...
end

# Функция производной для системы
function max_derivative(system::MySystem)
    return (t::Float64) -> begin
        # Вычисление dx/dt для всех компонент
        derivs = compute_derivatives(system, t)
        return maximum(abs, derivs)
    end
end

# Интеграция
clock = SimulationClock(0.0, 365.0, 1.0)
system = MySystem(...)

# Добавление событий системы
for event_time in system.event_times
    add_event!(clock, event_time, () -> handle_event!(system))
end

# Запуск
status = run!(clock, max_derivative(system))

if status == DIVERGENCE
    @error "Симуляция прервана из-за дивергенции"
    # Восстановление из последнего чекпоинта
end
```

## Ограничения

- **RAM:** ≤ 100 MB на инстанс
- **CPU:** 1 core (thread-safe не требуется в Phase 0)
- **Нет print():** только `@info/@warn/@error`
- **Чекпоинты:** функции не сериализуются

## Численная безопасность

1. Проверка `isfinite()` перед каждым обновлением dt
2. Clamp dt к `[min_dt, max_dt]`
3. Защита от обрыва записи (атомарный rename)
4. Аварийные чекпоинты при дивергенции

## Приоритеты дизайна

1. **Численная безопасность** > скорость > удобство
2. Строгая типизация всех параметров
3. Изолированное состояние (step! не мутирует внешние структуры)
