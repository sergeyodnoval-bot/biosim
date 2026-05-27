module ISystem

using Logging

export AbstractSystem
export init!, step!, max_derivative, shutdown!, save_state, load_state!

# ============================================================================
# ABSTRACT SYSTEM TYPE
# ============================================================================

"""
    AbstractSystem

Абстрактный базовый тип для всех систем-плагинов.
Все системы должны наследовать от этого типа для типостабильности.
"""
abstract type AbstractSystem end

"""
    ISystem

Интерфейс системы-плагина для SimulationKernel.

## Контракт методов:
- `init!(sys, clock, bus)` — инициализация системы перед запуском
- `step!(sys, dt, t)` — выполнение одного шага симуляции
- `max_derivative(sys, t)` — оценка максимальной производной для адаптивного шага
- `shutdown!(sys)` — завершение работы, освобождение ресурсов
- `save_state(sys)` — сохранение состояния в сериализуемый формат
- `load_state!(sys, data)` — восстановление состояния из данных

## Требования:
- Все структуры должны быть `<: AbstractSystem`
- `save_state` должен возвращать только JLD2-совместимые типы (`NamedTuple`, `Vector`, `Float64`, `Symbol`, `String`)
- Запрещены глобальные мутации и неявные `Any`
"""

# ============================================================================
# INTERFACE METHODS (to be implemented by concrete systems)
# ============================================================================

"""
    init!(sys::AbstractSystem, clock, bus) -> Nothing

Инициализирует систему перед началом симуляции.

Вызывается один раз в начале жизненного цикла, после `add_system!` и до первого `step!`.
Система может зарегистрировать обработчики событий в `bus` или получить доступ к `clock`.

# Аргументы:
- `sys`: экземпляр системы
- `clock`: объект SimulationClock (доступен через интерфейс)
- `bus`: объект EventBus для публикации/подписки на события

# Возвращает:
- `Nothing`

# Пример:
```julia
function init!(sys::MySystem, clock, bus)
    subscribe!(bus, :my_system, NeuralSignal, sys.handler)
    sys.initialized = true
    return nothing
end
```
"""
function init!(sys::AbstractSystem, clock, bus)::Nothing
    error("init! not implemented for $(typeof(sys))")
end

"""
    step!(sys::AbstractSystem, dt::Float64, t::Float64) -> Nothing

Выполняет один шаг симуляции для системы.

Вызывается на каждом шаге ядра после `flush!` шины событий.
Система должна обновить своё внутреннее состояние на основе `dt` и текущего времени `t`.

# Аргументы:
- `sys`: экземпляр системы
- `dt`: длительность шага в днях
- `t`: текущее время симуляции в днях

# Возвращает:
- `Nothing`

# Примечания:
- При обнаружении NaN/Inf в вычислениях система должна позволить ядру обнаружить это через `max_derivative`
- Не должно мутировать внешние структуры, только собственное состояние

# Пример:
```julia
function step!(sys::MySystem, dt::Float64, t::Float64)::Nothing
    sys.state += sys.rate * dt
    if !isfinite(sys.state)
        @warn "Divergence detected in MySystem" t=t state=sys.state
    end
    return nothing
end
```
"""
function step!(sys::AbstractSystem, dt::Float64, t::Float64)::Nothing
    error("step! not implemented for $(typeof(sys))")
end

"""
    max_derivative(sys::AbstractSystem, t::Float64) -> Float64

Оценивает максимальную производную состояния системы в момент времени `t`.

Используется ядром для агрегации и адаптивного выбора `dt`.
Возвращаемое значение влияет на шаг симуляции: большие значения уменьшают `dt`.

# Аргументы:
- `sys`: экземпляр системы
- `t`: текущее время симуляции в днях

# Возвращает:
- `Float64`: оценка максимальной производной (должна быть ≥ 0)

# Примечания:
- Должна возвращать конечное неотрицательное число
- Возврат NaN/Inf приведёт к статусу `:DIVERGENCE` в ядре
- Для статических систем можно вернуть `0.0`

# Пример:
```julia
function max_derivative(sys::MySystem, t::Float64)::Float64
    return abs(sys.rate) + abs(sin(t))
end
```
"""
function max_derivative(sys::AbstractSystem, t::Float64)::Float64
    error("max_derivative not implemented for $(typeof(sys))")
end

"""
    shutdown!(sys::AbstractSystem) -> Nothing

Завершает работу системы, освобождает ресурсы.

Вызывается один раз в конце жизненного цикла, после последнего `step!` или при ошибке.
Система должна закрыть файлы, освободить память, завершить соединения.

# Аргументы:
- `sys`: экземпляр системы

# Возвращает:
- `Nothing`

# Пример:
```julia
function shutdown!(sys::MySystem)::Nothing
    sys.initialized = false
    empty!(sys.buffer)
    return nothing
end
```
"""
function shutdown!(sys::AbstractSystem)::Nothing
    error("shutdown! not implemented for $(typeof(sys))")
end

"""
    save_state(sys::AbstractSystem) -> NamedTuple

Сохраняет состояние системы в сериализуемый формат.

Возвращает `NamedTuple` содержащий все необходимые данные для восстановления состояния.
Должен содержать только JLD2-совместимые типы: `Float64`, `Int`, `String`, `Symbol`, `Vector`, `NamedTuple`.

# Аргументы:
- `sys`: экземпляр системы

# Возвращает:
- `NamedTuple`: сериализуемое состояние системы

# Примечания:
- Не должен содержать функции, замыкания или потоки
- Должен быть детерминированным для одинакового состояния

# Пример:
```julia
function save_state(sys::MySystem)::NamedTuple
    return (state = sys.state, counter = sys.counter, name = string(sys.name))
end
```
"""
function save_state(sys::AbstractSystem)::NamedTuple
    error("save_state not implemented for $(typeof(sys))")
end

"""
    load_state!(sys::AbstractSystem, data::NamedTuple) -> Nothing

Восстанавливает состояние системы из сериализованных данных.

Принимает `NamedTuple` ранее сохранённый через `save_state` и восстанавливает внутреннее состояние.

# Аргументы:
- `sys`: экземпляр системы
- `data`: `NamedTuple` с данными состояния

# Возвращает:
- `Nothing`

# Примечания:
- Должен корректно обрабатывать данные той же структуры что вернул `save_state`
- После вызова система должна быть готова к продолжению симуляции

# Пример:
```julia
function load_state!(sys::MySystem, data::NamedTuple)::Nothing
    sys.state = data.state
    sys.counter = data.counter
    sys.name = Symbol(data.name)
    return nothing
end
```
"""
function load_state!(sys::AbstractSystem, data::NamedTuple)::Nothing
    error("load_state! not implemented for $(typeof(sys))")
end

# ============================================================================
# UTILITY MACROS
# ============================================================================

"""
    @implement_system(MySystem)

Макрос для удобной реализации интерфейса ISystem.

Генерирует заглушки методов с правильными сигнатурами.
Пользователь должен реализовать тело методов самостоятельно.

# Пример:
```julia
mutable struct MySystem <: AbstractSystem
    state::Float64
    rate::Float64
end

@implement_system MySystem

# Затем реализуем методы:
function ISystem.init!(sys::MySystem, clock, bus)
    # ...
end
```
"""
macro implement_system(SystemType)
    sys_name = string(SystemType)
    doc_string = "Реализуйте следующие методы для $sys_name:\n- init!(sys, clock, bus)\n- step!(sys, dt, t)\n- max_derivative(sys, t)\n- shutdown!(sys)\n- save_state(sys)\n- load_state!(sys, data)"
    esc(quote
        # Методы уже определены в модуле ISystem, просто напоминаем о необходимости реализации
        # Этот макрос служит документационной цели
        @doc $$doc_string $($(SystemType))
    end)
end

# ============================================================================
# VALIDATION HELPERS
# ============================================================================

"""
    validate_system(sys::AbstractSystem) -> Bool

Проверяет что система корректно реализует интерфейс ISystem.

Возвращает `true` если все методы реализованы, иначе бросает исключение.
"""
function validate_system(sys::AbstractSystem)::Bool
    t_test = 0.0
    dt_test = 0.1
    
    # Проверяем наличие методов через dispatch
    try
        init!(sys, nothing, nothing)
    catch e
        if occursin("not implemented", string(e))
            error("System $(typeof(sys)) does not implement init!")
        end
    end
    
    try
        step!(sys, dt_test, t_test)
    catch e
        if occursin("not implemented", string(e))
            error("System $(typeof(sys)) does not implement step!")
        end
    end
    
    try
        max_derivative(sys, t_test)
    catch e
        if occursin("not implemented", string(e))
            error("System $(typeof(sys)) does not implement max_derivative!")
        end
    end
    
    try
        shutdown!(sys)
    catch e
        if occursin("not implemented", string(e))
            error("System $(typeof(sys)) does not implement shutdown!")
        end
    end
    
    try
        state = save_state(sys)
        if !(state isa NamedTuple)
            error("save_state for $(typeof(sys)) must return NamedTuple, got $(typeof(state))")
        end
    catch e
        if occursin("not implemented", string(e))
            error("System $(typeof(sys)) does not implement save_state!")
        end
    end
    
    try
        empty_state = save_state(sys)
        load_state!(sys, empty_state)
    catch e
        if occursin("not implemented", string(e))
            error("System $(typeof(sys)) does not implement load_state!")
        end
    end
    
    return true
end

export validate_system

end # module ISystem
