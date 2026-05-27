#!/usr/bin/env julia
# demo_kernel.jl - Демо-скрипт для SimulationKernel
# Запуск: julia --project examples/demo_kernel.jl

using Dates
using Logging

# Подключаем модули
include("../src/SimulationKernel.jl")
using .SimulationKernel
using .ISystem
using .EventBus
using .SignalTypes

# ============================================================================
# MOCK SYSTEMS FOR DEMO
# ============================================================================

"""
    CircadianSystem

Система моделирующая циркадные ритмы с синусоидальной динамикой.
"""
mutable struct CircadianSystem <: AbstractSystem
    phase::Float64
    amplitude::Float64
    period::Float64
    value::Float64
    initialized::Bool
    
    function CircadianSystem(phase::Float64 = 0.0, amplitude::Float64 = 1.0, period::Float64 = 1.0)
        new(phase, amplitude, period, amplitude * sin(2π * phase / period), false)
    end
end

function init!(sys::CircadianSystem, clock, bus)::Nothing
    sys.initialized = true
    @info "CircadianSystem initialized" phase=sys.phase amplitude=sys.amplitude
    return nothing
end

function step!(sys::CircadianSystem, dt::Float64, t::Float64)::Nothing
    # Обновляем значение по синусоиде
    sys.value = sys.amplitude * sin(2π * (t + sys.phase) / sys.period)
    return nothing
end

function max_derivative(sys::CircadianSystem, t::Float64)::Float64
    # Максимальная производная синуса: A * 2π / T
    return abs(sys.amplitude * 2π / sys.period)
end

function shutdown!(sys::CircadianSystem)::Nothing
    sys.initialized = false
    @info "CircadianSystem shutdown"
    return nothing
end

function save_state(sys::CircadianSystem)::NamedTuple
    return (phase = sys.phase, amplitude = sys.amplitude, period = sys.period, value = sys.value)
end

function load_state!(sys::CircadianSystem, data::NamedTuple)::Nothing
    sys.phase = data.phase
    sys.amplitude = data.amplitude
    sys.period = data.period
    sys.value = data.value
    return nothing
end

"""
    MetabolicSystem

Система моделирующая метаболические процессы с накоплением.
"""
mutable struct MetabolicSystem <: AbstractSystem
    energy::Float64
    consumption_rate::Float64
    production_rate::Float64
    initialized::Bool
    
    function MetabolicSystem(initial_energy::Float64 = 100.0, 
                            consumption::Float64 = 0.1, 
                            production::Float64 = 0.15)
        new(initial_energy, consumption, production, initial_energy, false)
    end
end

function init!(sys::MetabolicSystem, clock, bus)::Nothing
    sys.initialized = true
    @info "MetabolicSystem initialized" energy=sys.energy
    return nothing
end

function step!(sys::MetabolicSystem, dt::Float64, t::Float64)::Nothing
    # Баланс энергии: производство - потребление
    delta = (sys.production_rate - sys.consumption_rate) * dt
    sys.energy += delta
    
    # Ограничиваем энергию
    sys.energy = max(0.0, min(1000.0, sys.energy))
    return nothing
end

function max_derivative(sys::MetabolicSystem, t::Float64)::Float64
    return abs(sys.production_rate - sys.consumption_rate)
end

function shutdown!(sys::MetabolicSystem)::Nothing
    sys.initialized = false
    @info "MetabolicSystem shutdown" final_energy=sys.energy
    return nothing
end

function save_state(sys::MetabolicSystem)::NamedTuple
    return (energy = sys.energy, consumption = sys.consumption_rate, production = sys.production_rate)
end

function load_state!(sys::MetabolicSystem, data::NamedTuple)::Nothing
    sys.energy = data.energy
    sys.consumption_rate = data.consumption
    sys.production_rate = data.production
    return nothing
end

"""
    NeuralActivitySystem

Система моделирующая нейронную активность с пороговыми событиями.
"""
mutable struct NeuralActivitySystem <: AbstractSystem
    activity::Float64
    threshold::Float64
    decay_rate::Float64
    spike_count::Int
    initialized::Bool
    
    function NeuralActivitySystem(threshold::Float64 = 0.8, decay::Float64 = 0.1)
        new(0.0, threshold, decay, 0, false)
    end
end

function init!(sys::NeuralActivitySystem, clock, bus)::Nothing
    sys.initialized = true
    @info "NeuralActivitySystem initialized" threshold=sys.threshold
    return nothing
end

function step!(sys::NeuralActivitySystem, dt::Float64, t::Float64)::Nothing
    # Спонтанная активация
    input = 0.01 * rand()
    sys.activity += input * dt
    
    # Затухание
    sys.activity -= sys.decay_rate * sys.activity * dt
    sys.activity = max(0.0, sys.activity)
    
    # Проверка порога
    if sys.activity > sys.threshold
        sys.spike_count += 1
        sys.activity = 0.0  # Сброс после спайка
        
        # Публикуем событие спайка
        signal = NeuralSignal(t, :neural_sys, :ALL; 
                             receptors=[:spike], 
                             data=(;spike_id=sys.spike_count, intensity=sys.threshold))
        publish!(bus, :neural_sys, signal)
    end
    
    return nothing
end

function max_derivative(sys::NeuralActivitySystem, t::Float64)::Float64
    return sys.decay_rate + 0.01
end

function shutdown!(sys::NeuralActivitySystem)::Nothing
    sys.initialized = false
    @info "NeuralActivitySystem shutdown" spikes=sys.spike_count
    return nothing
end

function save_state(sys::NeuralActivitySystem)::NamedTuple
    return (activity = sys.activity, spike_count = sys.spike_count)
end

function load_state!(sys::NeuralActivitySystem, data::NamedTuple)::Nothing
    sys.activity = data.activity
    sys.spike_count = data.spike_count
    return nothing
end

# ============================================================================
# LISTENER SYSTEM
# ============================================================================

"""
    EventListenerSystem

Система-слушатель для демонстрации шины событий.
"""
mutable struct EventListenerSystem <: AbstractSystem
    received_spikes::Int
    received_hormones::Int
    initialized::Bool
    
    function EventListenerSystem()
        new(0, 0, false)
    end
end

function init!(sys::EventListenerSystem, clock, bus)::Nothing
    sys.initialized = true
    
    # Подписка на нейронные спайки
    subscribe!(bus, :listener, NeuralSignal, s -> begin
        if :spike in s.receptors
            sys.received_spikes += 1
            @debug "Spike received" id=s.data.spike_id time=clock.current_time
        end
    end; receptors=[:spike])
    
    @info "EventListenerSystem initialized"
    return nothing
end

function step!(sys::EventListenerSystem, dt::Float64, t::Float64)::Nothing
    return nothing
end

function max_derivative(sys::EventListenerSystem, t::Float64)::Float64
    return 0.0
end

function shutdown!(sys::EventListenerSystem)::Nothing
    sys.initialized = false
    @info "EventListenerSystem shutdown" spikes=sys.received_spikes
    return nothing
end

function save_state(sys::EventListenerSystem)::NamedTuple
    return (received_spikes = sys.received_spikes, received_hormones = sys.received_hormones)
end

function load_state!(sys::EventListenerSystem, data::NamedTuple)::Nothing
    sys.received_spikes = data.received_spikes
    sys.received_hormones = data.received_hormones
    return nothing
end

# ============================================================================
# MAIN DEMO
# ============================================================================

function main()
    println("="^70)
    println("SimulationKernel Demo - 3 Mock Systems, 30 Days Simulation")
    println("="^70)
    
    # Настройка логирования
    console_logger = ConsoleLogger(stdout, Logging.Info)
    global_logger(console_logger)
    
    # Создаём системы
    circadian = CircadianSystem(0.0, 1.0, 1.0)           # Период 1 день
    metabolic = MetabolicSystem(100.0, 0.1, 0.15)
    neural = NeuralActivitySystem(0.5, 0.05)
    listener = EventListenerSystem()
    
    # Конфигурация ядра
    config = KernelConfig(
        checkpoint_interval = 5.0,    # Чекпоинт каждые 5 дней
        max_steps_between_cp = 1000,
        divergence_threshold = 1e10
    )
    
    # Создаём ядро
    kernel = SimulationKernel(0.0, 30.0, 0.1; config=config)
    
    # Добавляем системы
    add_system!(kernel, circadian)
    add_system!(kernel, metabolic)
    add_system!(kernel, neural)
    add_system!(kernel, listener)
    
    println("\n🚀 Starting simulation...")
    println("   Start time: 0.0 days")
    println("   End time: 30.0 days")
    println("   Initial dt: 0.1 days")
    println("   Checkpoint interval: $(config.checkpoint_interval) days")
    println()
    
    # Запускаем симуляцию
    start_wall = time()
    result = run!(kernel, 0.0, 30.0)
    elapsed = time() - start_wall
    
    # Вывод результатов
    println("\n" * "="^70)
    println("SIMULATION COMPLETE")
    println("="^70)
    println("Status: ", result.status)
    println("Total steps: ", result.total_steps)
    println("Wall time: $(round(elapsed, digits=3)) seconds")
    println("Divergence time: ", result.divergence_t)
    println()
    
    # Финальные состояния систем
    println("Final system states:")
    println("  Circadian value: $(round(circadian.value, digits=4))")
    println("  Metabolic energy: $(round(metabolic.energy, digits=4))")
    println("  Neural spikes: $(neural.spike_count)")
    println("  Listener received spikes: $(listener.received_spikes)")
    println()
    
    # Проверяем чекпоинты
    if isdir("checkpoints")
        checkpoints = readdir("checkpoints"; join=false)
        println("Checkpoints created: $(length(checkpoints))")
        for cp in checkpoints[1:min(5, length(checkpoints))]
            println("  - $cp")
        end
        if length(checkpoints) > 5
            println("  ... and $(length(checkpoints) - 5) more")
        end
    end
    
    println("\n" * "="^70)
    println("Demo completed successfully!")
    println("="^70)
    
    return result
end

# Запуск демо
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
