#!/usr/bin/env julia
# ============================================================================
# Demo: SimulationClock
# ============================================================================

using Logging
using Logging: ConsoleLogger, with_logger, @info, @warn, @error, LogLevel
using Dates
using Statistics

# Подключаем модуль
include("../src/SimulationClock.jl")

# Даём модулю короткое имя
const SC = SimulationClock

# ============================================================================
# MOCK DERIVATIVE FUNCTIONS
# ============================================================================

smooth_derivative() = (t::Float64) -> 0.5 + 0.3 * sin(2π * t / 365)

variable_derivative() = (t::Float64) -> begin
    if 50 <= t <= 100
        return 5.0
    elseif 200 <= t <= 250
        return 1e-5
    else
        return 0.1
    end
end

# ============================================================================
# EVENT CALLBACKS
# ============================================================================

function create_checkpoint_callback(clock, interval_days::Int)
    counter = Ref(0)
    return () -> begin
        counter[] += 1
        checkpoint_id = "auto_$(counter[])_$(Dates.format(Dates.now(), "yyyymmdd_HHMMSS"))"
        filepath = SC.save_checkpoint(clock; id = checkpoint_id)
        @info "АВТО-ЧЕКПОИНТ" step = counter[] path = filepath t = clock.current_time
    end
end

function create_status_callback()
    return () -> begin
        @info "=== СТАТУС СИМУЛЯЦИИ ===" 
    end
end

# ============================================================================
# MAIN DEMO
# ============================================================================

function run_demo(; 
    start_day::Float64 = 0.0,
    end_day::Float64 = 365.0,
    initial_dt::Float64 = 1.0,
    checkpoint_interval::Int = 30,
    use_variable_derivative::Bool = true
)
    
    @info "Запуск демо SimulationClock" 
    @info "Параметры:" start_day = start_day end_day = end_day initial_dt = initial_dt
    
    # Создание часов - используем SC.SimulationClock
    clock = SC.SimulationClock(
        start_day,
        end_day,
        initial_dt;
        min_dt = 1e-6,
        max_dt = 10.0,
        tolerance = 0.1
    )
    
    # Выбор функции производной
    derivative_func = use_variable_derivative ? variable_derivative() : smooth_derivative()
    
    # Добавление событий для авто-чекпоинтов
    checkpoint_times = collect(checkpoint_interval:checkpoint_interval:Int(end_day - 1))
    for t in checkpoint_times
        SC.add_event!(clock, Float64(t), create_checkpoint_callback(clock, checkpoint_interval); 
                   callback_id = "checkpoint_$(Int(t))days")
    end
    
    # Добавление статусных событий
    for t in [0.0, 100.0, 200.0, 300.0]
        if t > start_day && t < end_day
            SC.add_event!(clock, t, create_status_callback(); callback_id = "status_$(Int(t))days")
        end
    end
    
    # Начальный чекпоинт
    @info "Сохранение начального состояния"
    SC.save_checkpoint(clock; id = "initial_state")
    
    # Запуск симуляции
    @info "Начало симуляции..."
    start_time = time()
    step_count = 0
    dt_history = Float64[]
    
    # Ручной подсчёт шагов
    while clock.current_time < clock.end_time - SC.TIME_EPS && step_count < 1_000_000
        status = SC.step!(clock, derivative_func)
        step_count += 1
        push!(dt_history, clock.current_dt)
        
        if status == SC.DIVERGENCE
            @warn "Дивергенция на шаге $step_count"
            break
        end
    end
    
    elapsed = time() - start_time
    
    # Статистика
    state = SC.get_state(clock)
    
    @info "="^60
    @info "СИМУЛЯЦИЯ ЗАВЕРШЕНА"
    @info "Статус:" status = state.step_status
    @info "Итоговое время:" t = state.current_time
    @info "Итоговый шаг:" dt = state.current_dt
    @info "Всего шагов:" steps = step_count
    @info "Затраченное время:" seconds = round(elapsed, digits = 3)
    @info "Шагов в секунду:" rate = round(step_count / max(elapsed, 1e-6), digits = 1)
    @info "="^60
    
    # Вывод статистики по dt
    if !isempty(dt_history)
        @info "Статистика dt:" 
        @info "  Минимум:" minimum(dt_history)
        @info "  Максимум:" maximum(dt_history)
        @info "  Среднее:" mean(dt_history)
    end
    
    return clock
end

# ============================================================================
# CLI INTERFACE
# ============================================================================

function parse_args(args::Vector{String})
    kwargs = Dict{Symbol, Any}()
    
    i = 1
    while i <= length(args)
        arg = args[i]
        
        if arg == "--start" && i < length(args)
            kwargs[:start_day] = parse(Float64, args[i+1])
            i += 2
        elseif arg == "--end" && i < length(args)
            kwargs[:end_day] = parse(Float64, args[i+1])
            i += 2
        elseif arg == "--dt" && i < length(args)
            kwargs[:initial_dt] = parse(Float64, args[i+1])
            i += 2
        elseif arg == "--checkpoint-interval" && i < length(args)
            kwargs[:checkpoint_interval] = parse(Int, args[i+1])
            i += 2
        elseif arg == "--smooth"
            kwargs[:use_variable_derivative] = false
            i += 1
        elseif arg == "--help" || arg == "-h"
            println("""
            Использование: julia demo_clock.jl [опции]
            
            Опции:
              --start <days>              Начальное время (по умолчанию: 0.0)
              --end <days>                Конечное время (по умолчанию: 365.0)
              --dt <days>                 Начальный шаг (по умолчанию: 1.0)
              --checkpoint-interval <d>   Интервал чекпоинтов (по умолчанию: 30)
              --smooth                    Использовать плавную производную (вместо переменной)
              --help, -h                  Показать эту справку
            
            Примеры:
              julia demo_clock.jl
              julia demo_clock.jl --start 0 --end 100 --dt 0.5
              julia demo_clock.jl --checkpoint-interval 10 --smooth
            """)
            exit(0)
        else
            @warn "Неизвестный аргумент: $arg"
            i += 1
        end
    end
    
    return kwargs
end

# ============================================================================
# ENTRY POINT
# ============================================================================

if abspath(PROGRAM_FILE) == @__FILE__
    args = parse_args(ARGS)
    run_demo(; args...)
end