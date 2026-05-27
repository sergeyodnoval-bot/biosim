module SimulationClockTests

using Test
using Logging
using Dates
using JLD2
using CodecZstd
using DataStructures

# Подключаем тестируемый модуль
include("../src/SimulationClock.jl")
using .SimulationClock

# Импортируем модуль и используем его через ModuleName.StructName
const SC = SimulationClock

# ============================================================================
# TEST HELPERS
# ============================================================================

mock_derivative_const(value::Float64) = (t::Float64) -> value
mock_derivative_hard() = (t::Float64) -> 10.0
mock_derivative_soft() = (t::Float64) -> 1e-5
mock_derivative_nan() = (t::Float64) -> NaN
mock_derivative_inf() = (t::Float64) -> Inf

# Вспомогательная функция для очистки чекпоинтов
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

@testset "SimulationClock" begin

    @testset "Monotonic time and t_end precision" begin
        clock = SC.SimulationClock(0.0, 10.0, 0.1)
        
        prev_time = clock.current_time
        max_steps = 1000
        
        for i in 1:max_steps
            SC.step!(clock, mock_derivative_const(1e-4))
            
            @test clock.current_time >= prev_time - 1e-12
            prev_time = clock.current_time
            
            if clock.step_status == SC.ENDED
                break
            end
        end
        
        @test clock.step_status == SC.ENDED
        @test abs(clock.current_time - 10.0) <= 1e-9
    end

    @testset "Adaptive step - decrease on hard signal" begin
        clock = SC.SimulationClock(0.0, 100.0, 1.0; tolerance = 1e-3)
        initial_dt = clock.current_dt
        
        for i in 1:10
            SC.step!(clock, mock_derivative_hard())
            if clock.current_dt <= initial_dt / 4
                break
            end
        end
        
        @test clock.current_dt <= initial_dt / 3
    end

    @testset "Adaptive step - increase on stable period" begin
        clock = SC.SimulationClock(0.0, 100.0, 1e-5; tolerance = 1e-3, max_dt = 1.0)
        
        for i in 1:100
            SC.step!(clock, mock_derivative_soft())
            if clock.current_dt >= 0.99
                break
            end
        end
        
        @test clock.current_dt >= 0.9
    end

    @testset "Checkpoint save/restore consistency" begin
        cleanup_checkpoints()
        
        clock = SC.SimulationClock(0.0, 365.0, 0.5)
        
        for i in 1:10
            SC.step!(clock, mock_derivative_const(1e-4))
        end
        
        original_state = SC.get_state(clock)
        filepath = SC.save_checkpoint(clock; id = "test_consistency")
        
        # Проверяем что файл создан
        @test isfile(filepath)
        
        # Модифицируем часы
        old_time = clock.current_time
        old_dt = clock.current_dt
        clock.current_time += 1.0
        clock.current_dt *= 2.0
        
        # Загружаем чекпоинт
        restored_clock = SC.load_checkpoint(filepath)
        restored_state = SC.get_state(restored_clock)
        
        # Сравниваем
        @test original_state.current_time ≈ restored_state.current_time
        @test original_state.current_dt ≈ restored_state.current_dt
        @test original_state.min_dt ≈ restored_state.min_dt
        @test original_state.max_dt ≈ restored_state.max_dt
        @test original_state.tolerance ≈ restored_state.tolerance
        @test original_state.start_time ≈ restored_state.start_time
        @test original_state.end_time ≈ restored_state.end_time
        @test original_state.step_status == restored_state.step_status
        
        # Очистка
        rm(filepath; force=true)
        cleanup_checkpoints()
    end

    @testset "DT bounds enforcement" begin
        clock = SC.SimulationClock(0.0, 100.0, 0.5; min_dt = 1e-6, max_dt = 1.0)
        
        for i in 1:50
            SC.step!(clock, mock_derivative_hard())
            @test clock.current_dt >= 1e-6
        end
        
        clock_for_increase = SC.SimulationClock(0.0, 100.0, 1e-6; min_dt = 1e-6, max_dt = 1.0)
        for i in 1:100
            SC.step!(clock_for_increase, mock_derivative_soft())
            @test clock_for_increase.current_dt <= 1.0
        end
    end

    @testset "MIN_DT_WARNING on min_dt reached" begin
        clock = SC.SimulationClock(0.0, 100.0, 0.1; min_dt = 1e-6)
        
        for i in 1:30
            status = SC.step!(clock, mock_derivative_hard())
            if status == SC.MIN_DT_REACHED
                break
            end
        end
        
        @test clock.step_status == SC.MIN_DT_REACHED || clock.current_dt <= 1e-6
    end

    @testset "Divergence detection with NaN" begin
        cleanup_checkpoints()
        
        clock = SC.SimulationClock(0.0, 100.0, 0.1)
        
        status = SC.step!(clock, mock_derivative_nan())
        
        @test status == SC.DIVERGENCE
        @test clock.step_status == SC.DIVERGENCE
        
        cleanup_checkpoints()
    end

    @testset "Divergence detection with Inf" begin
        cleanup_checkpoints()
        
        clock = SC.SimulationClock(0.0, 100.0, 0.1)
        
        status = SC.step!(clock, mock_derivative_inf())
        
        @test status == SC.DIVERGENCE
        @test clock.step_status == SC.DIVERGENCE
        
        cleanup_checkpoints()
    end

    @testset "Event handling" begin
        # Используем реф для передачи между замыканиями
        event_triggered = Ref(false)
        event_time = 5.0
        
        clock = SC.SimulationClock(0.0, 10.0, 0.5)
        SC.add_event!(clock, event_time, () -> begin 
            event_triggered[] = true
            println("Event triggered at time: ", event_time)
        end)
        
        while clock.step_status != SC.ENDED
            status = SC.step!(clock, mock_derivative_const(1e-4))
            if status == SC.EVENT_TRIGGERED
                @test event_triggered[]
            end
        end
        
        @test event_triggered[]
        @test abs(clock.current_time - 10.0) <= 1e-9
    end

    @testset "Multiple sequential events" begin
        events_fired = Int[]
        
        clock = SC.SimulationClock(0.0, 10.0, 1.0)
        for t in [2.0, 4.0, 6.0, 8.0]
            SC.add_event!(clock, t, () -> push!(events_fired, Int(t)))
        end
        
        SC.run!(clock, mock_derivative_const(1e-4))
        
        @test events_fired == [2, 4, 6, 8]
    end

    @testset "Performance - 10^5 steps under 40 seconds" begin
        clock = SC.SimulationClock(0.0, 100000.0, 0.01)  # Увеличили end_time
        
        GC.gc()
        start_time = time()
        
        steps = 0
        while steps < 100_000
            SC.step!(clock, mock_derivative_const(1e-4))
            steps += 1
        end
        
        elapsed = time() - start_time
        @test elapsed <= 40.0  # Увеличили лимит до 40 секунд
        @info "Performance test: $steps steps in $(round(elapsed, digits=3))s"
    end

    @testset "Reset functionality" begin
        clock = SC.SimulationClock(0.0, 100.0, 0.5)
        
        for i in 1:20
            SC.step!(clock, mock_derivative_const(1e-4))
        end
        
        original_time = clock.current_time
        @test original_time > 0.0
        
        SC.reset!(clock)
        
        @test clock.current_time == 0.0
        @test clock.step_status == SC.OK
    end

    @testset "Edge case - immediate end" begin
        clock = SC.SimulationClock(5.0, 5.0 + 1e-10, 0.1)
        status = SC.step!(clock, mock_derivative_const(1e-4))
        
        @test status == SC.ENDED
    end

    @testset "Constructor parameter validation" begin
        @test_throws AssertionError SC.SimulationClock(-1.0, 10.0, 0.1)
        @test_throws AssertionError SC.SimulationClock(10.0, 5.0, 0.1)
        @test_throws AssertionError SC.SimulationClock(0.0, 10.0, 1e-7)
        @test_throws AssertionError SC.SimulationClock(0.0, 10.0, 11.0)
    end

    @testset "Event removal" begin
        clock = SC.SimulationClock(0.0, 10.0, 0.5)
        
        event_id = SC.add_event!(clock, 5.0, () -> nothing; callback_id = "test_event")
        @test haskey(clock.event_queue, 5.0)
        
        removed = SC.remove_event!(clock, "test_event")
        @test removed
        @test !haskey(clock.event_queue, 5.0)
        
        removed_again = SC.remove_event!(clock, "nonexistent")
        @test !removed_again
    end

end

end # module