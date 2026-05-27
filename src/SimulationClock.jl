module SimulationClock

using JLD2
using CodecZstd
using DataStructures: SortedDict
using Logging: @info, @warn, @error, LogLevel
using Dates  # Добавляем для timestamp

# ============================================================================
# CONSTANTS
# ============================================================================

const MIN_DT_DEFAULT = 1e-6      # дни
const MAX_DT_DEFAULT = 1.0       # дни
const DT_ADAPTIVE_FACTOR_DOWN = 0.5
const DT_ADAPTIVE_FACTOR_UP = 1.2
const TOLERANCE_SCALE_DOWN = 0.1
const DEFAULT_TOLERANCE = 1e-3   # порог для адаптивного шага
const CHECKPOINT_DIR = "checkpoints"
const CHECKPOINT_PREFIX = "sim_"
const TIME_EPS = 1e-9            # точность достижения t_end

# ============================================================================
# ENUMS
# ============================================================================

@enum StepResult begin
    OK
    EVENT_TRIGGERED
    MIN_DT_REACHED
    ENDED
    DIVERGENCE
end

# ============================================================================
# EVENT DESCRIPTOR (для сериализации)
# ============================================================================

"""
    EventDescriptor

Структура для сериализуемого описания события.
Функции не сохраняются, только метаданные.
"""
struct EventDescriptor
    time::Float64
    callback_id::String
    payload::Dict{String, Any}
end

EventDescriptor(time::Float64) = EventDescriptor(time, "anonymous", Dict{String, Any}())

# ============================================================================
# SIMULATION CLOCK STATE
# ============================================================================

"""
    SimulationClock

Ядро управления симуляционным временем с адаптивным шагом,
планировщиком событий и атомарным чекпоинтингом.
"""
mutable struct SimulationClock
    current_time::Float64
    current_dt::Float64
    min_dt::Float64
    max_dt::Float64
    tolerance::Float64
    start_time::Float64
    end_time::Float64
    step_status::StepResult
    checkpoint_id::String
    event_queue::SortedDict{Float64, Tuple{Function, EventDescriptor}}
    event_counter::Int
    
    function SimulationClock(
        start_time::Float64,
        end_time::Float64,
        initial_dt::Float64;
        min_dt::Float64 = MIN_DT_DEFAULT,
        max_dt::Float64 = MAX_DT_DEFAULT,
        tolerance::Float64 = DEFAULT_TOLERANCE,
        events::Vector{Tuple{Float64, Function}} = Tuple{Float64, Function}[]
    )
        # Валидация входных параметров
        @assert start_time >= 0.0 "start_time должен быть ≥ 0"
        @assert end_time > start_time "end_time должен быть > start_time"
        @assert min_dt <= initial_dt <= max_dt "initial_dt должен быть в [min_dt, max_dt]"
        @assert min_dt >= 1e-6 "min_dt должен быть ≥ 1e-6"
        @assert max_dt <= 10.0 "max_dt должен быть ≤ 10.0"
        @assert isfinite(initial_dt) "initial_dt должен быть конечным числом"
        
        clock = new(
            start_time,
            initial_dt,
            min_dt,
            max_dt,
            tolerance,
            start_time,
            end_time,
            OK,
            "",
            SortedDict{Float64, Tuple{Function, EventDescriptor}}(),
            0
        )
        
        # Добавление событий из вектора
        for (t, callback) in events
            add_event!(clock, t, callback)
        end
        
        return clock
    end
end

# ============================================================================
# CORE API
# ============================================================================

function step!(clock::SimulationClock, derivative_func::Function)::StepResult
    # Проверка завершения симуляции
    if clock.current_time >= clock.end_time - TIME_EPS
        clock.step_status = ENDED
        @info "TIME_TICK" t = clock.current_time status = :ENDED
        return ENDED
    end
    
    # Целевое время шага
    t_target = min(clock.current_time + clock.current_dt, clock.end_time)
    
    # Проверка на события в интервале
    if !isempty(clock.event_queue)
        next_event_time = first(keys(clock.event_queue))
        
        if next_event_time < t_target - TIME_EPS
            # Есть событие внутри шага — разбиваем шаг
            return _step_to_event!(clock, derivative_func, next_event_time)
        elseif abs(next_event_time - t_target) <= TIME_EPS
            # Событие почти в конце шага — корректируем t_target
            t_target = next_event_time
        end
    end
    
    # Фактический шаг по времени
    actual_dt = t_target - clock.current_time
    if actual_dt < MIN_DT_DEFAULT
        actual_dt = MIN_DT_DEFAULT
        t_target = clock.current_time + actual_dt
    end
    
    # Вычисление производной в начале шага
    deriv = zero(Float64)
    try
        deriv = derivative_func(clock.current_time)
    catch e
        @error "DIVERGENCE_WARNING" error = e msg = "derivative_func бросил исключение"
        clock.step_status = DIVERGENCE
        save_checkpoint(clock; emergency = true)
        return DIVERGENCE
    end
    
    # Проверка на дивергенцию
    if !isfinite(deriv)
        @warn "DIVERGENCE_WARNING" t = clock.current_time deriv = deriv
        clock.step_status = DIVERGENCE
        save_checkpoint(clock; emergency = true)
        return DIVERGENCE
    end
    
    # Адаптация dt
    old_dt = clock.current_dt
    _adapt_dt!(clock, deriv)
    
    # Проверка min_dt
    if clock.current_dt <= clock.min_dt + TIME_EPS
        if clock.current_dt > clock.min_dt
            clock.current_dt = clock.min_dt
        end
        if old_dt > clock.min_dt * 2
            @warn "MIN_DT_WARNING" t = clock.current_time dt = clock.current_dt
        end
        clock.step_status = MIN_DT_REACHED
    else
        clock.step_status = OK
    end
    
    # Обновление времени
    clock.current_time = t_target
    
    # Обработка события, если достигли его времени
    if !isempty(clock.event_queue)
        next_event_time = first(keys(clock.event_queue))
        if abs(clock.current_time - next_event_time) <= TIME_EPS
            _trigger_next_event!(clock)
            clock.step_status = EVENT_TRIGGERED
        end
    end
    
    @info "TIME_TICK" t = clock.current_time dt = clock.current_dt status = clock.step_status
    @info "STEP_COMPLETED" t = clock.current_time
    
    return clock.step_status
end

function run!(clock::SimulationClock, derivative_func::Function; 
              max_steps::Int = 1000000)::StepResult
    steps = 0
    while steps < max_steps
        status = step!(clock, derivative_func)
        steps += 1
        
        if status == ENDED || status == DIVERGENCE
            break
        end
    end
    
    if steps >= max_steps
        @warn "Достигнут лимит шагов" steps = steps
    end
    
    return clock.step_status
end

# ============================================================================
# CHECKPOINTING
# ============================================================================

function save_checkpoint(clock::SimulationClock; 
                         id::Union{Nothing, String} = nothing,
                         emergency::Bool = false)::String
    if isnothing(id)
        timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS_fff")
        checkpoint_id = "$(emergency ? "emergency_" : "")$(timestamp)"
    else
        checkpoint_id = id
    end
    
    clock.checkpoint_id = checkpoint_id
    mkpath(CHECKPOINT_DIR)
    filename = "$(CHECKPOINT_PREFIX)$(checkpoint_id).jld2"
    filepath = joinpath(CHECKPOINT_DIR, filename)
    
    serializable_events = EventDescriptor[]
    for (t, (_, desc)) in clock.event_queue
        push!(serializable_events, desc)
    end
    
    jldopen(filepath, "w") do file
        file["current_time"] = clock.current_time
        file["current_dt"] = clock.current_dt
        file["min_dt"] = clock.min_dt
        file["max_dt"] = clock.max_dt
        file["tolerance"] = clock.tolerance
        file["start_time"] = clock.start_time
        file["end_time"] = clock.end_time
        file["step_status"] = Int(clock.step_status)
        file["checkpoint_id"] = clock.checkpoint_id
        file["event_counter"] = clock.event_counter
        file["events"] = serializable_events
    end
    
    return filepath
end

function load_checkpoint(filepath::String)::SimulationClock
    data = jldopen(filepath, "r") do file
        Dict(
            :current_time => read(file, "current_time"),
            :current_dt => read(file, "current_dt"),
            :min_dt => read(file, "min_dt"),
            :max_dt => read(file, "max_dt"),
            :tolerance => read(file, "tolerance"),
            :start_time => read(file, "start_time"),
            :end_time => read(file, "end_time"),
            :step_status => StepResult(read(file, "step_status")),
            :checkpoint_id => read(file, "checkpoint_id"),
            :event_counter => read(file, "event_counter"),
            :events => read(file, "events")
        )
    end
    
    clock = SimulationClock(
        data[:start_time],
        data[:end_time],
        data[:current_dt];
        min_dt = data[:min_dt],
        max_dt = data[:max_dt],
        tolerance = data[:tolerance]
    )
    
    clock.current_time = data[:current_time]
    clock.step_status = data[:step_status]
    clock.checkpoint_id = data[:checkpoint_id]
    clock.event_counter = data[:event_counter]
    
    for event in data[:events]
        desc = EventDescriptor(event.time, event.callback_id, event.payload)
        clock.event_queue[event.time] = (()->nothing, desc)
    end
    
    return clock
end

# ============================================================================
# EVENT MANAGEMENT
# ============================================================================

function add_event!(clock::SimulationClock, time::Float64, 
                    callback::Function; 
                    callback_id::Union{Nothing, String} = nothing,
                    payload::Dict{String, Any} = Dict{String, Any}())::String
    @assert time >= clock.current_time "Время события должно быть ≥ текущего времени"
    @assert isfinite(time) "Время события должно быть конечным"
    
    if isnothing(callback_id)
        clock.event_counter += 1
        callback_id = "event_$(clock.event_counter)"
    end
    
    desc = EventDescriptor(time, callback_id, payload)
    
    # Обработка коллизий времени (FIFO через микросдвиг)
    if haskey(clock.event_queue, time)
        time = time + eps(time) * 10
    end
    
    clock.event_queue[time] = (callback, desc)
    
    @info "Событие добавлено" time = time id = callback_id
    return callback_id
end

function remove_event!(clock::SimulationClock, callback_id::String)::Bool
    for (t, (_, desc)) in clock.event_queue
        if desc.callback_id == callback_id
            delete!(clock.event_queue, t)
            @info "Событие удалено" id = callback_id
            return true
        end
    end
    return false
end

function get_next_event_time(clock::SimulationClock)::Union{Float64, Nothing}
    isempty(clock.event_queue) ? nothing : first(keys(clock.event_queue))
end

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

function _adapt_dt!(clock::SimulationClock, deriv::Float64)
    abs_deriv = abs(deriv)
    
    if abs_deriv > clock.tolerance
        # Шаг слишком большой — уменьшаем
        new_dt = clock.current_dt * DT_ADAPTIVE_FACTOR_DOWN
        clock.current_dt = max(new_dt, clock.min_dt)
    elseif abs_deriv < clock.tolerance * TOLERANCE_SCALE_DOWN
        # Шаг можно увеличить
        new_dt = clock.current_dt * DT_ADAPTIVE_FACTOR_UP
        clock.current_dt = min(new_dt, clock.max_dt)
    end
    # Иначе оставляем dt без изменений
end

function _step_to_event!(clock::SimulationClock, derivative_func::Function, 
                         event_time::Float64)::StepResult
    # Шаг до момента события
    remaining_dt = event_time - clock.current_time
    
    if remaining_dt < MIN_DT_DEFAULT
        # Слишком близко к событию — сразу триггерим
        clock.current_time = event_time
        _trigger_next_event!(clock)
        clock.step_status = EVENT_TRIGGERED
        return EVENT_TRIGGERED
    end
    
    # Сохраняем оригинальный dt
    saved_dt = clock.current_dt
    clock.current_dt = remaining_dt
    
    # Рекурсивный вызов step! (теперь без событий в интервале)
    status = step!(clock, derivative_func)
    
    # Восстанавливаем dt для следующего шага
    clock.current_dt = saved_dt
    
    return status
end

function _trigger_next_event!(clock::SimulationClock)
    if isempty(clock.event_queue)
        return
    end
    
    # Для SortedDict используем first
    event_time = first(keys(clock.event_queue))
    if abs(clock.current_time - event_time) > TIME_EPS
        return
    end
    
    callback, desc = clock.event_queue[event_time]
    delete!(clock.event_queue, event_time)
    
    @info "Событие выполнено" time = event_time id = desc.callback_id
    
    try
        callback()
    catch e
        @error "Ошибка выполнения callback" id = desc.callback_id error = e
        rethrow(e)
    end
end

# ============================================================================
# UTILITIES
# ============================================================================

function reset!(clock::SimulationClock; keep_events::Bool = true)
    clock.current_time = clock.start_time
    clock.current_dt = clock.min_dt
    clock.step_status = OK
    clock.checkpoint_id = ""
    
    if !keep_events
        empty!(clock.event_queue)
    end
    
    @info "Часы сброшены" t = clock.current_time
end

function get_state(clock::SimulationClock)::NamedTuple
    return (
        current_time = clock.current_time,
        current_dt = clock.current_dt,
        min_dt = clock.min_dt,
        max_dt = clock.max_dt,
        tolerance = clock.tolerance,
        start_time = clock.start_time,
        end_time = clock.end_time,
        step_status = clock.step_status,
        checkpoint_id = clock.checkpoint_id,
        next_event_time = get_next_event_time(clock)
    )
end

function is_finished(clock::SimulationClock)::Bool
    return clock.current_time >= clock.end_time - TIME_EPS || 
           clock.step_status == ENDED
end

# ============================================================================
# SERIALIZATION (for checkpointing)
# ============================================================================

"""
    save_state(clock::SimulationClock) -> NamedTuple

Сохраняет состояние часов в JLD2-совместимом формате.
Функции callback не сохраняются — только метаданные событий.
"""
function save_state(clock::SimulationClock)::NamedTuple
    # Преобразуем event_queue в сериализуемый формат
    events_data = Vector{NamedTuple}()
    for (t, (callback, desc)) in clock.event_queue
        # Сохраняем только метаданные события, не функцию
        push!(events_data, (
            time = t,
            callback_id = desc.callback_id,
            payload = desc.payload
        ))
    end
    
    return (
        current_time = clock.current_time,
        current_dt = clock.current_dt,
        min_dt = clock.min_dt,
        max_dt = clock.max_dt,
        tolerance = clock.tolerance,
        start_time = clock.start_time,
        end_time = clock.end_time,
        step_status = Int(clock.step_status),  # Сериализуем enum как Int
        checkpoint_id = clock.checkpoint_id,
        events = events_data
    )
end

"""
    load_state!(clock::SimulationClock, data::NamedTuple) -> Nothing

Восстанавливает состояние часов из сохранённых данных.
События восстанавливаются без callback-функций (требуется повторная регистрация).
"""
function load_state!(clock::SimulationClock, data::NamedTuple)::Nothing
    clock.current_time = data.current_time
    clock.current_dt = data.current_dt
    clock.min_dt = data.min_dt
    clock.max_dt = data.max_dt
    clock.tolerance = data.tolerance
    clock.start_time = data.start_time
    clock.end_time = data.end_time
    clock.step_status = StepResult(data.step_status)
    clock.checkpoint_id = data.checkpoint_id
    
    # Очищаем очередь событий (callback-функции не восстанавливаются)
    empty!(clock.event_queue)
    
    # Восстанавливаем метаданные событий (без функций)
    for event_data in data.events
        desc = EventDescriptor(
            event_data.time,
            event_data.callback_id,
            event_data.payload
        )
        # Пустой placeholder для callback — система должна перерегистрировать события
        clock.event_queue[event_data.time] = (()->nothing, desc)
    end
    
    @info "Состояние часов загружено" t = clock.current_time events = length(data.events)
    return nothing
end

# Экспортируем всё
export SimulationClock, StepResult, EventDescriptor
export step!, run!, add_event!, remove_event!, get_next_event_time
export save_checkpoint, load_checkpoint
export reset!, get_state, is_finished
export save_state, load_state!
export OK, EVENT_TRIGGERED, MIN_DT_REACHED, ENDED, DIVERGENCE

end # module