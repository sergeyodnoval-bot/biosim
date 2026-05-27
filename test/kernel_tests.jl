module KernelTests

using Test
using Logging
using Dates
using JLD2

# Подключаем тестируемые модули
include("../src/SimulationKernel.jl")
using .SimulationKernel
using .ISystem
using .EventBus
using .SimulationClock

export run_all_tests

# ============================================================================
# MOCK SYSTEMS FOR TESTING
# ============================================================================

"""
    MockSystem

Простая система для тестирования с линейной динамикой.
"""
mutable struct MockSystem <: AbstractSystem
    state::Float64
    rate::Float64
    step_count::Int
    initialized::Bool
    
    function MockSystem(initial_state::Float64 = 0.0, rate::Float64 = 1.0)
        new(initial_state, rate, 0, false)
    end
end

function init!(sys::MockSystem, clock, bus)::Nothing
    sys.initialized = true
    return nothing
end

function step!(sys::MockSystem, dt::Float64, t::Float64)::Nothing
    sys.state += sys.rate * dt
    sys.step_count += 1
    return nothing
end

function max_derivative(sys::MockSystem, t::Float64)::Float64
    return abs(sys.rate)
end

function shutdown!(sys::MockSystem)::Nothing
    sys.initialized = false
    return nothing
end

function save_state(sys::MockSystem)::NamedTuple
    return (state = sys.state, rate = sys.rate, step_count = sys.step_count)
end

function load_state!(sys::MockSystem, data::NamedTuple)::Nothing
    sys.state = data.state
    sys.rate = data.rate
    sys.step_count = data.step_count
    return nothing
end

"""
    DivergentSystem

Система которая возвращает NaN после заданного времени.
"""
mutable struct DivergentSystem <: AbstractSystem
    state::Float64
    divergence_time::Float64
    initialized::Bool
    
    function DivergentSystem(divergence_time::Float64 = 5.0)
        new(0.0, divergence_time, false)
    end
end

function init!(sys::DivergentSystem, clock, bus)::Nothing
    sys.initialized = true
    return nothing
end

function step!(sys::DivergentSystem, dt::Float64, t::Float64)::Nothing
    if t > sys.divergence_time
        sys.state = NaN
    else
        sys.state += 0.1 * dt
    end
    return nothing
end

function max_derivative(sys::DivergentSystem, t::Float64)::Float64
    if t > sys.divergence_time
        return NaN
    end
    return 0.1
end

function shutdown!(sys::DivergentSystem)::Nothing
    sys.initialized = false
    return nothing
end

function save_state(sys::DivergentSystem)::NamedTuple
    return (state = sys.state, divergence_time = sys.divergence_time)
end

function load_state!(sys::DivergentSystem, data::NamedTuple)::Nothing
    sys.state = data.state
    sys.divergence_time = data.divergence_time
    return nothing
end

"""
    EventPublishingSystem

Система которая публикует события при инициализации.
"""
mutable struct EventPublishingSystem <: AbstractSystem
    state::Float64
    events_published::Int
    initialized::Bool
    
    function EventPublishingSystem()
        new(0.0, 0, false)
    end
end

function init!(sys::EventPublishingSystem, clock, bus)::Nothing
    sys.initialized = true
    # Публикуем тестовое событие
    signal = BaseSignal(timestamp=clock.current_time, source=:event_sys, target=:listener, 
                       receptors=Symbol[], data=(;value=42.0))
    publish!(bus, :event_sys, signal)
    sys.events_published += 1
    return nothing
end

function step!(sys::EventPublishingSystem, dt::Float64, t::Float64)::Nothing
    sys.state += dt
    return nothing
end

function max_derivative(sys::EventPublishingSystem, t::Float64)::Float64
    return 1.0
end

function shutdown!(sys::EventPublishingSystem)::Nothing
    sys.initialized = false
    return nothing
end

function save_state(sys::EventPublishingSystem)::NamedTuple
    return (state = sys.state, events_published = sys.events_published)
end

function load_state!(sys::EventPublishingSystem, data::NamedTuple)::Nothing
    sys.state = data.state
    sys.events_published = data.events_published
    return nothing
end

# ============================================================================
# TEST HELPERS
# ============================================================================

function cleanup_checkpoints()
    if isdir("checkpoints")
        for f in readdir("checkpoints"; join=true)
            rm(f; force=true)
        end
        rm("checkpoints"; force=true)
    end
end

# ============================================================================
# TEST SUITE
# ============================================================================

function run_all_tests()
    @testset "SimulationKernel" begin
        
        @testset "Lifecycle - strict order" begin
            cleanup_checkpoints()
            
            sys = MockSystem(0.0, 1.0)
            kernel = SimulationKernel(0.0, 10.0, 0.5)
            add_system!(kernel, sys)
            
            # Проверяем что система ещё не инициализирована
            @test !sys.initialized
            
            # Первый шаг должен инициализировать
            status = step!(kernel)
            @test status == STEP_OK || status == STEP_ENDED
            @test sys.initialized
            
            # Несколько шагов
            prev_state = sys.state
            for i in 1:5
                step!(kernel)
                @test sys.state >= prev_state  # состояние растёт
                prev_state = sys.state
            end
            
            # Сохраняем состояние
            state_before = save_state(sys)
            
            # Модифицируем
            sys.state += 100.0
            
            # Загружаем
            load_state!(sys, state_before)
            @test sys.state ≈ state_before.state
            
            # Ещё шаг
            step!(kernel)
            
            # Shutdown вызывается автоматически в run! или reset!
            reset_kernel!(kernel)
            @test !sys.initialized
            
            cleanup_checkpoints()
        end
        
        @testset "Aggregation - max_derivative from all systems" begin
            cleanup_checkpoints()
            
            sys1 = MockSystem(0.0, 1.0)   # deriv = 1.0
            sys2 = MockSystem(0.0, 5.0)   # deriv = 5.0
            sys3 = MockSystem(0.0, 2.0)   # deriv = 2.0
            
            kernel = SimulationKernel(0.0, 10.0, 0.5)
            add_system!(kernel, sys1)
            add_system!(kernel, sys2)
            add_system!(kernel, sys3)
            
            # Агрегированная производная должна быть максимумом
            deriv = _aggregate_derivative(kernel, 0.0)
            @test deriv == 5.0
            
            # Пустой kernel
            empty_kernel = SimulationKernel(0.0, 10.0, 0.5)
            deriv_empty = _aggregate_derivative(empty_kernel, 0.0)
            @test deriv_empty == 0.0
            
            cleanup_checkpoints()
        end
        
        @testset "Integration with Clock/Bus - event delivery" begin
            cleanup_checkpoints()
            
            received_value = Ref(0.0)
            
            # Система отправитель
            pub_sys = EventPublishingSystem()
            
            # Система получатель
            mutable struct ListenerSystem <: AbstractSystem
                received_value::Ref{Float64}
                initialized::Bool
            end
            
            function init!(sys::ListenerSystem, clock, bus)::Nothing
                sys.initialized = true
                subscribe!(bus, :listener, BaseSignal, s -> begin
                    sys.received_value[] = s.data.value
                end)
                return nothing
            end
            
            function step!(sys::ListenerSystem, dt::Float64, t::Float64)::Nothing
                return nothing
            end
            
            function max_derivative(sys::ListenerSystem, t::Float64)::Float64
                return 0.0
            end
            
            function shutdown!(sys::ListenerSystem)::Nothing
                sys.initialized = false
            end
            
            function save_state(sys::ListenerSystem)::NamedTuple
                return (received_value = sys.received_value[])
            end
            
            function load_state!(sys::ListenerSystem, data::NamedTuple)::Nothing
                sys.received_value[] = data.received_value
            end
            
            listener = ListenerSystem(received_value, false)
            
            kernel = SimulationKernel(0.0, 5.0, 0.5)
            add_system!(kernel, pub_sys)
            add_system!(kernel, listener)
            
            # Один шаг должен доставить событие
            step!(kernel)
            
            # Проверяем что событие доставлено
            @test received_value[] == 42.0
            
            cleanup_checkpoints()
        end
        
        @testset "Checkpoint roundtrip" begin
            cleanup_checkpoints()
            
            sys = MockSystem(10.0, 2.0)
            kernel = SimulationKernel(0.0, 30.0, 0.5)
            add_system!(kernel, sys)
            
            # Несколько шагов
            for i in 1:10
                step!(kernel)
            end
            
            # Сохраняем состояние до модификации
            pre_modify_time = kernel.clock.current_time
            pre_modify_state = sys.state
            
            # Сохраняем чекпоинт
            checkpoint_path = save_checkpoint!(kernel, "test_roundtrip")
            @test isfile(checkpoint_path)
            
            # Модифицируем систему
            sys.state += 1000.0
            @test sys.state != pre_modify_state
            
            # Создаём новый kernel и загружаем чекпоинт
            kernel2 = SimulationKernel(0.0, 30.0, 0.5)
            sys2 = MockSystem(10.0, 2.0)
            add_system!(kernel2, sys2)
            load_checkpoint!(kernel2, checkpoint_path)
            
            # Проверяем восстановление
            @test kernel2.clock.current_time ≈ pre_modify_time
            @test sys2.state ≈ pre_modify_state
            
            # Шаг после загрузки
            step!(kernel2)
            
            cleanup_checkpoints()
        end
        
        @testset "Divergence detection - NaN in system" begin
            cleanup_checkpoints()
            
            div_sys = DivergentSystem(5.0)
            normal_sys = MockSystem(0.0, 0.1)
            
            kernel = SimulationKernel(0.0, 30.0, 0.5)
            add_system!(kernel, div_sys)
            add_system!(kernel, normal_sys)
            
            result = run!(kernel, 0.0, 30.0)
            
            # Проверяем статус
            @test result.status == STEP_DIVERGENCE
            @test result.divergence_t !== nothing
            @test result.divergence_t > 5.0
            
            # Проверяем что аварийный чекпоинт создан
            checkpoint_files = filter(f -> occursin("emergency", f), readdir("checkpoints"; join=false))
            @test length(checkpoint_files) >= 1
            
            cleanup_checkpoints()
        end
        
        @testset "Performance - 10^4 steps with 3 mock systems" begin
            cleanup_checkpoints()
            
            sys1 = MockSystem(0.0, 1.0)
            sys2 = MockSystem(0.0, 2.0)
            sys3 = MockSystem(0.0, 3.0)
            
            # Отключаем чекпоинты для теста производительности
            config = KernelConfig(checkpoint_interval=1000.0, max_steps_between_cp=100000)
            kernel = SimulationKernel(0.0, 10000.0, 0.1; config=config)
            add_system!(kernel, sys1)
            add_system!(kernel, sys2)
            add_system!(kernel, sys3)
            
            GC.gc()
            start_time = time()
            
            steps = 0
            while steps < 10_000
                status = step!(kernel)
                steps += 1
                if status == STEP_ENDED || status == STEP_DIVERGENCE
                    break
                end
            end
            
            elapsed = time() - start_time
            
            @test elapsed <= 3.0
            @info "Performance: $steps steps in $(round(elapsed, digits=3))s"
            
            cleanup_checkpoints()
        end
        
        @testset "Multiple checkpoints and restore" begin
            cleanup_checkpoints()
            
            sys = MockSystem(0.0, 1.0)
            config = KernelConfig(checkpoint_interval=1.0, max_steps_between_cp=100)
            kernel = SimulationKernel(0.0, 10.0, 0.5; config=config)
            add_system!(kernel, sys)
            
            # Запускаем симуляцию с автоматическими чекпоинтами
            result = run!(kernel, 0.0, 10.0)
            
            @test result.status == STEP_ENDED
            
            # Проверяем что чекпоинты созданы
            checkpoint_files = filter(f -> occursin("auto", f), readdir("checkpoints"; join=false))
            @test length(checkpoint_files) >= 5  # минимум 5 чекпоинтов за 10 дней
            
            cleanup_checkpoints()
        end
        
        @testset "Empty kernel - no systems" begin
            cleanup_checkpoints()
            
            kernel = SimulationKernel(0.0, 5.0, 0.5)
            
            # run! с пустым kernel должен работать
            result = run!(kernel, 0.0, 5.0)
            
            @test result.status == STEP_ENDED
            @test result.total_steps > 0
            
            cleanup_checkpoints()
        end
        
        @testset "Cannot add system after initialization" begin
            cleanup_checkpoints()
            
            kernel = SimulationKernel(0.0, 5.0, 0.5)
            sys = MockSystem()
            
            add_system!(kernel, sys)
            
            # Инициализируем через step!
            step!(kernel)
            
            # Попытка добавить систему должна вызвать ошибку
            sys2 = MockSystem()
            @test_throws ErrorException add_system!(kernel, sys2)
            
            cleanup_checkpoints()
        end
        
    end
    
    println("\n" * "="^60)
    println("✅ Все тесты SimulationKernel пройдены!")
    println("="^60)
end

end # module KernelTests
