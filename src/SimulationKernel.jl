module SimulationKernel

using Logging
using JLD2
using CodecZstd
using UUIDs
using Dates

# Include dependencies
include("SimulationClock.jl")
include("SignalTypes.jl")
include("EventBus.jl")
include("ISystem.jl")

using .SimulationClock
using .EventBus
using .ISystem
using .SignalTypes

export SimulationKernel, KernelConfig, SimulationResult, StepStatus
export add_system!, run!, step!, save_checkpoint!, load_checkpoint!
export get_kernel_state, reset_kernel!

# ============================================================================
# CONSTANTS & CONFIG
# ============================================================================

const DEFAULT_CHECKPOINT_INTERVAL::Float64 = 1.0      # дни сим. времени
const DEFAULT_MAX_STEPS_BETWEEN_CP::Int = 5000
const DEFAULT_DIVERGENCE_THRESHOLD::Float64 = 1e10    # порог для NaN/Inf детекта
const CHECKPOINT_DIR::String = "checkpoints"
const CHECKPOINT_PREFIX::String = "kernel_"
const COMPRESSION_LEVEL::Int = 3

# ============================================================================
# TYPES
# ============================================================================

"""
    KernelConfig

Конфигурация ядра симуляции.

# Поля:
- `checkpoint_interval::Float64`: интервал между чекпоинтами в днях сим. времени
- `max_steps_between_cp::Int`: максимальное число шагов без чекпоинта
- `divergence_threshold::Float64`: порог для обнаружения дивергенции
"""
struct KernelConfig
    checkpoint_interval::Float64
    max_steps_between_cp::Int
    divergence_threshold::Float64
    
    function KernelConfig(
        checkpoint_interval::Float64 = DEFAULT_CHECKPOINT_INTERVAL,
        max_steps_between_cp::Int = DEFAULT_MAX_STEPS_BETWEEN_CP,
        divergence_threshold::Float64 = DEFAULT_DIVERGENCE_THRESHOLD
    )
        @assert checkpoint_interval > 0.0 "checkpoint_interval должен быть > 0"
        @assert max_steps_between_cp > 0 "max_steps_between_cp должен быть > 0"
        @assert divergence_threshold > 0.0 "divergence_threshold должен быть > 0"
        
        new(checkpoint_interval, max_steps_between_cp, divergence_threshold)
    end
end

"""
    StepStatus

Статус выполнения одного шага ядра.
"""
@enum StepStatus begin
    STEP_OK
    STEP_ENDED
    STEP_DIVERGENCE
    STEP_MIN_DT
    STEP_ERROR
end

"""
    SimulationResult

Результат выполнения симуляции.

# Поля:
- `status::StepStatus`: финальный статус
- `total_steps::Int`: общее количество шагов
- `elapsed_wall_time::Float64`: реальное время выполнения в секундах
- `divergence_t::Union{Nothing, Float64}`: время дивергенции если была
"""
struct SimulationResult
    status::StepStatus
    total_steps::Int
    elapsed_wall_time::Float64
    divergence_t::Union{Nothing, Float64}
end

"""
    SimulationKernel

Главное ядро симуляции, управляющее жизненным циклом систем-плагинов.

# Поля:
- `systems::Vector{AbstractSystem}`: вектор подключённых систем
- `clock::SimulationClock`: объект управления временем
- `bus::EventBus`: шина событий
- `config::KernelConfig`: конфигурация
- `step_count::Int`: счётчик шагов с последнего чекпоинта
- `last_checkpoint_time::Float64`: время последнего чекпоинта
- `initialized::Bool`: флаг инициализации
"""
mutable struct SimulationKernel
    systems::Vector{AbstractSystem}
    clock::SimulationClock.SimulationClock
    bus::EventBus.EventBus
    config::KernelConfig
    step_count::Int
    last_checkpoint_time::Float64
    initialized::Bool
    
    function SimulationKernel(
        start_time::Float64,
        end_time::Float64,
        initial_dt::Float64;
        config::KernelConfig = KernelConfig()
    )
        clock = SimulationClock.SimulationClock(start_time, end_time, initial_dt)
        bus = EventBus.EventBus()
        
        new(
            Vector{AbstractSystem}(),
            clock,
            bus,
            config,
            0,
            start_time,
            false
        )
    end
end

# ============================================================================
# CORE API
# ============================================================================

"""
    add_system!(kernel::SimulationKernel, sys::AbstractSystem) -> Nothing

Добавляет систему-плагин в ядро симуляции.

Вызывается до `run!` или первого `step!`. Система будет инициализирована
при первом вызове `step!` или `run!`.

# Аргументы:
- `kernel`: ядро симуляции
- `sys`: система для добавления

# Возвращает:
- `Nothing`
"""
function add_system!(kernel::SimulationKernel, sys::AbstractSystem)::Nothing
    if kernel.initialized
        error("Cannot add system after kernel initialization")
    end
    push!(kernel.systems, sys)
    @info "Система добавлена" system_type=typeof(sys)
    return nothing
end

"""
    run!(kernel::SimulationKernel, start_time::Float64, end_time::Float64) -> SimulationResult

Запускает симуляцию от start_time до end_time.

Инициализирует все системы, выполняет главный цикл, обрабатывает ошибки,
вызывает graceful shutdown при завершении.

# Аргументы:
- `kernel`: ядро симуляции
- `start_time`: время начала (должно совпадать с current_time clock)
- `end_time`: время окончания

# Возвращает:
- `SimulationResult`: результат симуляции
"""
function run!(kernel::SimulationKernel, start_time::Float64, end_time::Float64)::SimulationResult
    wall_start = time()
    total_steps = 0
    divergence_t = nothing
    status = STEP_OK
    
    try
        # Инициализация если ещё не выполнена
        if !kernel.initialized
            _initialize_kernel!(kernel)
        end
        
        # Обновляем end_time в clock если нужно
        if end_time != kernel.clock.end_time
            kernel.clock.end_time = end_time
        end
        
        # Главный цикл
        while true
            step_status = step!(kernel)
            total_steps += 1
            
            if step_status == STEP_ENDED
                status = STEP_ENDED
                break
            elseif step_status == STEP_DIVERGENCE
                status = STEP_DIVERGENCE
                divergence_t = kernel.clock.current_time
                @error "DIVERGENCE detected" t=divergence_t
                # Аварийный чекпоинт
                _emergency_checkpoint!(kernel)
                break
            elseif step_status == STEP_ERROR
                status = STEP_ERROR
                break
            end
            
            # Проверка на превышение лимита шагов (защита от зависания)
            if total_steps >= 10_000_000
                @warn "Step limit reached" steps=total_steps
                status = STEP_ERROR
                break
            end
        end
        
    catch e
        @error "Kernel error" error=e exception=catch_backtrace()
        status = STEP_ERROR
        _emergency_checkpoint!(kernel)
    finally
        # Graceful shutdown
        _shutdown_systems!(kernel)
    end
    
    wall_elapsed = time() - wall_start
    
    return SimulationResult(status, total_steps, wall_elapsed, divergence_t)
end

"""
    step!(kernel::SimulationKernel) -> StepStatus

Выполняет один шаг симуляции.

Порядок выполнения:
1. Вычисление агрегированной производной
2. Шаг clock с адаптивным dt
3. Flush! шины событий
4. Вызов step! для всех систем
5. Проверка на дивергенцию
6. Периодический чекпоинт

# Аргументы:
- `kernel`: ядро симуляции

# Возвращает:
- `StepStatus`: статус выполнения шага
"""
function step!(kernel::SimulationKernel)::StepStatus
    # Инициализация если ещё не выполнена
    if !kernel.initialized
        _initialize_kernel!(kernel)
    end
    
    # 1. Агрегация производных
    derivative_func = (t::Float64) -> _aggregate_derivative(kernel, t)
    
    # 2. Шаг clock
    clock_status = SimulationClock.step!(kernel.clock, derivative_func)
    
    # Обработка статуса clock
    if clock_status == SimulationClock.ENDED
        return STEP_ENDED
    elseif clock_status == SimulationClock.DIVERGENCE
        return STEP_DIVERGENCE
    elseif clock_status == SimulationClock.MIN_DT_REACHED
        @warn "MIN_DT reached" t=kernel.clock.current_time dt=kernel.clock.current_dt
        # Продолжаем выполнение, но с минимальным dt
    end
    
    dt = kernel.clock.current_dt
    t = kernel.clock.current_time
    
    # 3. Flush! шины событий
    try
        EventBus.flush!(kernel.bus, t)
    catch e
        @error "Bus flush error" error=e
        return STEP_ERROR
    end
    
    # 4. Вызов step! для всех систем
    for sys in kernel.systems
        try
            ISystem.step!(sys, dt, t)
        catch e
            @error "System step! error" system=typeof(sys) error=e
            return STEP_ERROR
        end
    end
    
    # 5. Проверка на дивергенцию в системах
    for sys in kernel.systems
        deriv = ISystem.max_derivative(sys, t)
        if !isfinite(deriv) || abs(deriv) > kernel.config.divergence_threshold
            @warn "System divergence detected" system=typeof(sys) deriv=deriv t=t
            return STEP_DIVERGENCE
        end
    end
    
    # 6. Периодический чекпоинт
    kernel.step_count += 1
    _maybe_checkpoint!(kernel)
    
    return STEP_OK
end

# ============================================================================
# CHECKPOINTING
# ============================================================================

"""
    save_checkpoint!(kernel::SimulationKernel, path::String) -> String

Сохраняет полное состояние ядра в файл.

Атомарная запись: сначала в temp файл, затем rename.
Содержит: clock_state, bus_state, system_states.

# Аргументы:
- `kernel`: ядро симуляции
- `path`: путь к файлу (без расширения)

# Возвращает:
- `String`: полный путь к сохранённому файлу
"""
function save_checkpoint!(kernel::SimulationKernel, path::String)::String
    mkpath(CHECKPOINT_DIR)
    
    # Генерируем имя файла
    if !endswith(path, ".jld2.zst")
        filepath = joinpath(CHECKPOINT_DIR, "$(path).jld2.zst")
    else
        filepath = joinpath(CHECKPOINT_DIR, path)
    end
    
    temp_filepath = filepath * ".tmp"
    
    try
        # Собираем состояния
        clock_state = _save_clock_state(kernel.clock)
        bus_state = _save_bus_state(kernel.bus)
        system_states = _save_systems_state(kernel.systems)
        
        # Сериализуем во временный файл
        jldopen(temp_filepath, "w") do file
            file["clock_state"] = clock_state
            file["bus_state"] = bus_state
            file["system_states"] = system_states
            file["step_count"] = kernel.step_count
            file["last_checkpoint_time"] = kernel.last_checkpoint_time
        end
        
        # Атомарный rename
        mv(temp_filepath, filepath; force=true)
        
        @info "Checkpoint saved" path=filepath
        return filepath
        
    catch e
        @error "Checkpoint save error" error=e
        if isfile(temp_filepath)
            rm(temp_filepath; force=true)
        end
        rethrow(e)
    end
end

"""
    load_checkpoint!(kernel::SimulationKernel, path::String) -> Nothing

Загружает состояние ядра из файла.

Восстанавливает clock, bus и все системы в их сохранённое состояние.

# Аргументы:
- `kernel`: ядро симуляции
- `path`: путь к файлу чекпоинта

# Возвращает:
- `Nothing`
"""
function load_checkpoint!(kernel::SimulationKernel, path::String)::Nothing
    if !isfile(path)
        error("Checkpoint file not found: $path")
    end
    
    try
        data = jldopen(path, "r") do file
            Dict(
                :clock_state => read(file, "clock_state"),
                :bus_state => read(file, "bus_state"),
                :system_states => read(file, "system_states"),
                :step_count => read(file, "step_count"),
                :last_checkpoint_time => read(file, "last_checkpoint_time")
            )
        end
        
        # Восстанавливаем clock
        _load_clock_state!(kernel.clock, data[:clock_state])
        
        # Восстанавливаем bus
        _load_bus_state!(kernel.bus, data[:bus_state])
        
        # Восстанавливаем системы
        _load_systems_state!(kernel.systems, data[:system_states])
        
        # Восстанавливаем метаданные
        kernel.step_count = data[:step_count]
        kernel.last_checkpoint_time = data[:last_checkpoint_time]
        kernel.initialized = true
        
        @info "Checkpoint loaded" path=path
        return nothing
        
    catch e
        @error "Checkpoint load error" error=e
        rethrow(e)
    end
end

"""
    get_kernel_state(kernel::SimulationKernel) -> NamedTuple

Возвращает текущее состояние ядра в виде NamedTuple.
"""
function get_kernel_state(kernel::SimulationKernel)::NamedTuple
    return (
        current_time = kernel.clock.current_time,
        current_dt = kernel.clock.current_dt,
        step_count = kernel.step_count,
        last_checkpoint_time = kernel.last_checkpoint_time,
        n_systems = length(kernel.systems),
        initialized = kernel.initialized
    )
end

"""
    reset_kernel!(kernel::SimulationKernel) -> Nothing

Сбрасывает ядро в начальное состояние.
"""
function reset_kernel!(kernel::SimulationKernel)::Nothing
    kernel.step_count = 0
    kernel.last_checkpoint_time = kernel.clock.start_time
    kernel.initialized = false
    
    # Сброс систем
    for sys in kernel.systems
        ISystem.shutdown!(sys)
    end
    
    # Очистка bus
    EventBus.clear!(kernel.bus)
    
    # Сброс clock
    SimulationClock.reset!(kernel.clock)
    
    @info "Kernel reset"
    return nothing
end

# ============================================================================
# INTERNAL FUNCTIONS
# ============================================================================

function _initialize_kernel!(kernel::SimulationKernel)::Nothing
    @info "Initializing kernel" n_systems=length(kernel.systems)
    
    # Инициализация всех систем
    for sys in kernel.systems
        try
            ISystem.init!(sys, kernel.clock, kernel.bus)
        catch e
            @error "System init! error" system=typeof(sys) error=e
            rethrow(e)
        end
    end
    
    kernel.initialized = true
    kernel.step_count = 0
    kernel.last_checkpoint_time = kernel.clock.current_time
    
    return nothing
end

function _shutdown_systems!(kernel::SimulationKernel)::Nothing
    for sys in kernel.systems
        try
            ISystem.shutdown!(sys)
        catch e
            @warn "System shutdown! error" system=typeof(sys) error=e
        end
    end
    return nothing
end

function _aggregate_derivative(kernel::SimulationKernel, t::Float64)::Float64
    if isempty(kernel.systems)
        return 0.0
    end
    
    max_deriv = 0.0
    for sys in kernel.systems
        deriv = ISystem.max_derivative(sys, t)
        if !isfinite(deriv)
            return NaN  # Пропускаем NaN вверх
        end
        max_deriv = max(max_deriv, deriv)
    end
    
    return max_deriv
end

function _maybe_checkpoint!(kernel::SimulationKernel)::Nothing
    current_time = kernel.clock.current_time
    
    # Проверка по времени
    time_since_cp = current_time - kernel.last_checkpoint_time
    if time_since_cp >= kernel.config.checkpoint_interval
        save_checkpoint!(kernel, "auto_$(round(Int, current_time))")
        kernel.last_checkpoint_time = current_time
        kernel.step_count = 0
        return
    end
    
    # Проверка по числу шагов
    if kernel.step_count >= kernel.config.max_steps_between_cp
        @warn "Max steps without checkpoint reached" steps=kernel.step_count
        save_checkpoint!(kernel, "forced_$(round(Int, current_time))")
        kernel.last_checkpoint_time = current_time
        kernel.step_count = 0
    end
    
    return nothing
end

function _emergency_checkpoint!(kernel::SimulationKernel)::Nothing
    timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    path = "emergency_$(timestamp)"
    try
        save_checkpoint!(kernel, path)
        @info "Emergency checkpoint saved" path=path
    catch e
        @error "Emergency checkpoint failed" error=e
    end
    return nothing
end

# ============================================================================
# STATE SERIALIZATION HELPERS
# ============================================================================

function _save_clock_state(clock::SimulationClock.SimulationClock)::NamedTuple
    # Сохраняем только сериализуемые поля
    events_list = Tuple{Float64, String, Dict{String, Any}}[]
    for (t, (_, desc)) in clock.event_queue
        push!(events_list, (t, desc.callback_id, desc.payload))
    end
    
    return (
        current_time = clock.current_time,
        current_dt = clock.current_dt,
        min_dt = clock.min_dt,
        max_dt = clock.max_dt,
        tolerance = clock.tolerance,
        start_time = clock.start_time,
        end_time = clock.end_time,
        step_status = Int(clock.step_status),
        checkpoint_id = clock.checkpoint_id,
        event_counter = clock.event_counter,
        events = events_list
    )
end

function _load_clock_state!(clock::SimulationClock.SimulationClock, state::NamedTuple)::Nothing
    SimulationClock.reset!(clock; keep_events=false)
    
    clock.current_time = state.current_time
    clock.current_dt = state.current_dt
    clock.min_dt = state.min_dt
    clock.max_dt = state.max_dt
    clock.tolerance = state.tolerance
    clock.start_time = state.start_time
    clock.end_time = state.end_time
    clock.step_status = SimulationClock.StepResult(state.step_status)
    clock.checkpoint_id = state.checkpoint_id
    clock.event_counter = state.event_counter
    
    # Восстанавливаем события (без callback функций)
    for (t, callback_id, payload) in state.events
        desc = SimulationClock.EventDescriptor(t, callback_id, payload)
        clock.event_queue[t] = (()->nothing, desc)
    end
    
    return nothing
end

function _save_bus_state(bus::EventBus.EventBus)::NamedTuple
    # Сохраняем pending signals как сериализуемые данные
    pending_data = []
    for signal in bus.pending_signals
        push!(pending_data, (
            type = string(typeof(signal)),
            timestamp = signal.timestamp,
            source = signal.source,
            target = signal.target,
            receptors = copy(signal.receptors),
            data = signal.data,
            ttl = signal.ttl
        ))
    end
    
    # Сохраняем inboxes
    inbox_data = Dict{Symbol, Vector{NamedTuple}}()
    for (sys, signals) in bus.inboxes
        sys_signals = []
        for signal in signals
            push!(sys_signals, (
                type = string(typeof(signal)),
                timestamp = signal.timestamp,
                source = signal.source,
                target = signal.target,
                receptors = copy(signal.receptors),
                data = signal.data,
                ttl = signal.ttl
            ))
        end
        inbox_data[sys] = sys_signals
    end
    
    return (
        subscriptions = copy(bus.descriptors),
        pending = pending_data,
        inboxes = inbox_data,
        stats = copy(bus.stats)
    )
end

function _load_bus_state!(bus::EventBus.EventBus, state::NamedTuple)::Nothing
    EventBus.clear!(bus)
    
    # Восстанавливаем descriptors (подписки нужно перерегистрировать с handlers)
    # Но handlers нельзя восстановить, поэтому только сохраняем метаданные
    empty!(bus.descriptors)
    for desc in state.subscriptions
        push!(bus.descriptors, desc)
    end
    
    # Восстанавливаем pending signals
    empty!(bus.pending_signals)
    for item in state.pending
        signal = _reconstruct_signal(item)
        if signal !== nothing
            push!(bus.pending_signals, signal)
        end
    end
    
    # Восстанавливаем inboxes
    empty!(bus.inboxes)
    for (sys, signals_data) in state.inboxes
        bus.inboxes[sys] = []
        for item in signals_data
            signal = _reconstruct_signal(item)
            if signal !== nothing
                push!(bus.inboxes[sys], signal)
            end
        end
    end
    
    # Восстанавливаем статистику
    for (key, value) in state.stats
        bus.stats[key] = value
    end
    
    return nothing
end

function _reconstruct_signal(data::NamedTuple)::Union{Nothing, AbstractSignal}
    type_str = data.type
    
    if occursin("NeuralSignal", type_str)
        return NeuralSignal(data.timestamp, data.source, data.target;
                           receptors=data.receptors, data=data.data, ttl=data.ttl)
    elseif occursin("HormoneSignal", type_str)
        return HormoneSignal(data.timestamp, data.source, data.target;
                            receptors=data.receptors, data=data.data, ttl=data.ttl)
    elseif occursin("MetabolicSignal", type_str)
        return MetabolicSignal(data.timestamp, data.source, data.target;
                              receptors=data.receptors, data=data.data, ttl=data.ttl)
    elseif occursin("BaseSignal", type_str)
        return BaseSignal(
            timestamp=data.timestamp,
            source=data.source,
            target=data.target,
            receptors=data.receptors,
            data=data.data,
            ttl=data.ttl
        )
    else
        @warn "Unknown signal type" type=type_str
        return nothing
    end
end

function _save_systems_state(systems::Vector{AbstractSystem})::Vector{NamedTuple}
    states = Vector{NamedTuple}()
    for sys in systems
        state = ISystem.save_state(sys)
        push!(states, (type = string(typeof(sys)), data = state))
    end
    return states
end

function _load_systems_state!(systems::Vector{AbstractSystem}, states::Vector{NamedTuple})::Nothing
    if length(systems) != length(states)
        error("System count mismatch: expected $(length(systems)), got $(length(states))")
    end
    
    for (i, sys) in enumerate(systems)
        expected_type = states[i].type
        actual_type = string(typeof(sys))
        
        if expected_type != actual_type
            @warn "System type mismatch" expected=expected_type actual=actual_type
        end
        
        ISystem.load_state!(sys, states[i].data)
    end
    
    return nothing
end

end # module SimulationKernel
