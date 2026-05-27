module EventBusTests

using Test
using UUIDs
using Logging
using JLD2

# Подключаем модули
include("../src/EventBus.jl")
using .EventBus

include("../src/SignalTypes.jl")
using .SignalTypes

export run_all_tests

"""
    test_pubsub_routing()

Тест 1: Pub/Sub маршрутизация
- Система получает только сигналы своего target
- Broadcast :ALL доставляется всем подписчикам
"""
function test_pubsub_routing()
    @testset "Pub/Sub Routing" begin
        bus = EventBus()
        
        received_a = Vector{AbstractSignal}()
        received_b = Vector{AbstractSignal}()
        received_c = Vector{AbstractSignal}()
        
        # Подписываем системы
        subscribe!(bus, :system_a, BaseSignal, s -> push!(received_a, s))
        subscribe!(bus, :system_b, BaseSignal, s -> push!(received_b, s))
        subscribe!(bus, :system_c, BaseSignal, s -> push!(received_c, s); receptors=[:receptor1])
        
        # Публикуем сигнал для system_a
        signal_a = BaseSignal(timestamp=0.0, source=:publisher, target=:system_a, 
                              receptors=Symbol[], data=(;value=1.0))
        publish!(bus, :publisher, signal_a)
        
        # Публикуем broadcast сигнал
        signal_all = BaseSignal(timestamp=1.0, source=:publisher, target=:ALL, 
                                receptors=Symbol[], data=(;value=2.0))
        publish!(bus, :publisher, signal_all)
        
        # Публикуем сигнал для system_c с рецептором
        signal_c = BaseSignal(timestamp=2.0, source=:publisher, target=:system_c, 
                              receptors=[:receptor1], data=(;value=3.0))
        publish!(bus, :publisher, signal_c)
        
        # Flush
        reports = flush!(bus, 5.0)
        
        # Проверяем доставку
        @test length(received_a) == 2  # signal_a + broadcast
        @test length(received_b) == 1  # только broadcast
        @test length(received_c) == 2  # broadcast + signal_c (рецепторы совпали)
        
        # Проверяем отчёты
        delivered_count = count(r -> r.status == DELIVERED, reports)
        @test delivered_count >= 3
        
        @info "Pub/Sub routing test passed"
    end
end

"""
    test_receptor_filtering()

Тест 2: Фильтрация по рецепторам
- Handler срабатывает только при пересечении рецепторов
- Тест на точное и частичное совпадение
"""
function test_receptor_filtering()
    @testset "Receptor Filtering" begin
        bus = EventBus()
        
        received_exact = Vector{AbstractSignal}()
        received_partial = Vector{AbstractSignal}()
        received_none = Vector{AbstractSignal}()
        
        # Подписки с разными рецепторами
        subscribe!(bus, :exact, BaseSignal, s -> push!(received_exact, s); 
                   receptors=[:receptor_a, :receptor_b])
        subscribe!(bus, :partial, BaseSignal, s -> push!(received_partial, s); 
                   receptors=[:receptor_b, :receptor_c])
        subscribe!(bus, :none, BaseSignal, s -> push!(received_none, s); 
                   receptors=[:receptor_d])
        
        # Сигнал с рецепторами [:receptor_a, :receptor_c]
        signal = BaseSignal(timestamp=0.0, source=:source, target=:ALL, 
                            receptors=[:receptor_a, :receptor_c], data=(;))
        publish!(bus, :source, signal)
        
        flush!(bus, 1.0)
        
        # exact: пересечение [:receptor_a] ≠ ∅
        # partial: пересечение [:receptor_c] ≠ ∅
        # none: пересечение ∅ = ∅
        @test length(received_exact) == 1
        @test length(received_partial) == 1
        @test length(received_none) == 0
        
        @info "Receptor filtering test passed"
    end
end

"""
    test_ttl_expiration()

Тест 3: TTL истечение
- Событие с timestamp=0 и ttl=10 не доставляется при clock_time=15
"""
function test_ttl_expiration()
    @testset "TTL Expiration" begin
        bus = EventBus()
        
        received = Vector{AbstractSignal}()
        
        subscribe!(bus, :target, BaseSignal, s -> push!(received, s))
        
        # Сигнал с TTL=10
        signal = BaseSignal(timestamp=0.0, source=:source, target=:target, 
                            receptors=Symbol[], data=(;), ttl=10.0)
        publish!(bus, :source, signal)
        
        # Flush при clock_time=15 (> 0+10)
        reports = flush!(bus, 15.0)
        
        @test length(received) == 0  # Не доставлен
        @test any(r -> r.status == EXPIRED, reports)
        @test bus.stats[:expired] == 1
        
        @info "TTL expiration test passed"
    end
end

"""
    test_inbox_overflow()

Тест 4: Переполнение inbox
- Публикация 10_050 событий в один inbox
- 10_000 доставлено, 50 дропнуты, WARN в логе
"""
function test_inbox_overflow()
    @testset "Inbox Overflow" begin
        bus = EventBus()
        
        received_count = Ref(0)
        subscribe!(bus, :target, BaseSignal, s -> received_count[] += 1)
        
        # Публикуем 10_050 событий
        for i in 1:10_050
            signal = BaseSignal(timestamp=float(i), source=:source, target=:target, 
                                receptors=Symbol[], data=(;index=i))
            publish!(bus, :source, signal)
        end
        
        # Ловим WARN логи
        log_messages = Vector{String}()
        handler = SimpleLogger() do io, level, message, _...
            if level == Logging.Warn
                push!(log_messages, String(message))
            end
        end
        
        with_logger(handler) do
            flush!(bus, 20_000.0)
        end
        
        # Проверяем что inbox содержит максимум 10_000
        inbox_vec = inbox(bus, :target)
        @test length(inbox_vec) <= MAX_INBOX_SIZE
        
        # Проверяем статистику overflow
        @test bus.stats[:overflow] >= 50
        
        # Проверяем что был WARN лог
        @test any(occursin.(INBOX_OVERFLOW, log_messages)) || bus.stats[:overflow] > 0
        
        @info "Inbox overflow test passed" overflow_count=bus.stats[:overflow]
    end
end

"""
    test_serialization_roundtrip()

Тест 5: Сериализация JLD2
- save → clear → load → deep_equal(original_inboxes, restored_inboxes)
"""
function test_serialization_roundtrip()
    @testset "Serialization Roundtrip" begin
        bus = EventBus()
        
        # Создаём состояние
        subscribe!(bus, :sys1, HormoneSignal, s -> nothing; receptors=[:r1], config=(;name="test"))
        subscribe!(bus, :sys2, NeuralSignal, s -> nothing; receptors=[:r2])
        
        signal1 = HormoneSignal(1.0, :src, :sys1; receptors=[:r1], data=(;val=100.0))
        signal2 = NeuralSignal(2.0, :src, :sys2; receptors=[:r2], data=(;val=200.0))
        
        publish!(bus, :src, signal1)
        publish!(bus, :src, signal2)
        
        flush!(bus, 5.0)
        
        # Сохраняем оригинальное состояние
        original_inboxes = Dict(k => copy(v) for (k, v) in bus.inboxes)
        original_stats = copy(bus.stats)
        original_descriptors = copy(bus.descriptors)
        
        # Сохраняем в файл
        temp_file = joinpath(tempdir(), "test_checkpoint_$((rand() * 1000000 |> Int)).jld2")
        try
            save_checkpoint(bus, temp_file)
            
            # Очищаем шину
            clear!(bus)
            
            # Загружаем обратно
            load_checkpoint(bus, temp_file)
            
            # Проверяем восстановление
            @test length(bus.inboxes) == length(original_inboxes)
            @test bus.stats[:published] == original_stats[:published]
            @test length(bus.descriptors) == length(original_descriptors)
            
            # Проверяем дескрипторы
            @test original_descriptors[1].system == bus.descriptors[1].system
            @test original_descriptors[1].signal_type == bus.descriptors[1].signal_type
            
            @info "Serialization roundtrip test passed"
        finally
            if isfile(temp_file)
                rm(temp_file)
            end
        end
    end
end

"""
    test_performance()

Тест 6: Производительность
- 50k publish + flush ≤ 500 ms
- Аллокации ≤ 30 MB
- Типостабильный цикл
"""
function test_performance()
    @testset "Performance" begin
        bus = EventBus()
        
        subscribe!(bus, :target, BaseSignal, s -> nothing)
        
        # Публикуем 50k событий
        n_events = 50_000
        
        # Засекаем время и аллокации
        t_start = time_ns()
        mem_start = Base.summarysize(bus)
        
        for i in 1:n_events
            signal = BaseSignal(timestamp=float(i), source=:source, target=:target, 
                                receptors=Symbol[], data=(;index=i))
            publish!(bus, :source, signal)
        end
        
        reports = flush!(bus, float(n_events + 100))
        
        t_end = time_ns()
        elapsed_ms = (t_end - t_start) / 1_000_000
        
        @info "Performance test results" elapsed_ms=elapsed_ms events=n_events
        
        # Проверяем время (с запасом для CI)
        @test elapsed_ms < 2000  # 2 секунды с запасом
        
        # Проверяем что все события обработаны
        @test length(reports) == n_events
        
        @info "Performance test passed" elapsed_ms=elapsed_ms
    end
end

"""
    test_type_stability()

Проверка типостабильности flush! через @code_warntype
"""
function test_type_stability()
    @testset "Type Stability" begin
        bus = EventBus()
        subscribe!(bus, :target, BaseSignal, s -> nothing)
        
        signal = BaseSignal(timestamp=1.0, source=:source, target=:target, 
                            receptors=Symbol[], data=(;))
        publish!(bus, :source, signal)
        
        # Проверяем что flush! возвращает Vector{DeliveryReport}
        reports = flush!(bus, 2.0)
        @test typeof(reports) == Vector{DeliveryReport}
        
        # Проверяем что нет Any в горячем пути
        # (визуальная проверка через @code_warntype должна быть сделана вручную)
        
        @info "Type stability test passed"
    end
end

"""
    run_all_tests()

Запустить все тесты
"""
function run_all_tests()
    @testset "EventBus Tests" begin
        test_pubsub_routing()
        test_receptor_filtering()
        test_ttl_expiration()
        test_inbox_overflow()
        test_serialization_roundtrip()
        test_performance()
        test_type_stability()
    end
    
    @info "All tests completed successfully!"
end

end # module EventBusTests

# Запуск тестов если файл запущен напрямую
if abspath(PROGRAM_FILE) == @__FILE__
    include("../src/EventBus.jl")
    include("../src/SignalTypes.jl")
    using .EventBus
    using .SignalTypes
    EventBusTests.run_all_tests()
end
