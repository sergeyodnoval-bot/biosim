#!/usr/bin/env julia
# ============================================================================
# Demo: EventBus.jl
# Демонстрация работы шины событий с 3 системами
# ============================================================================

using Dates

# Подключаем модули
include("../src/EventBus.jl")
include("../src/SignalTypes.jl")

using .EventBus
using .SignalTypes

function main()
    println("="^70)
    println("DEMO: EventBus.jl - Типизированная шина событий")
    println("="^70)
    println()
    
    # Создаём шину
    bus = EventBus()
    
    # ========================================================================
    # 1. Регистрация систем и подписок
    # ========================================================================
    println("📋 Шаг 1: Регистрация систем и подписок")
    println("-"^70)
    
    # Счётчики полученных сигналов
    liver_count = Ref(0)
    muscle_count = Ref(0)
    brain_count = Ref(0)
    
    # Подписка печени на гормональные сигналы (инсулин, глюкагон)
    subscribe!(bus, :liver, HormoneSignal, 
               s -> begin
                   liver_count[] += 1
                   @info "Liver received hormone" signal_id=s.id data=s.data
               end;
               receptors=[:insulin_receptor, :glucagon_receptor])
    
    # Подписка мышц на гормональные сигналы (инсулин) и нейросигналы
    subscribe!(bus, :muscle, HormoneSignal,
               s -> begin
                   muscle_count[] += 1
                   @info "Muscle received hormone" signal_id=s.id data=s.data
               end;
               receptors=[:insulin_receptor])
    
    subscribe!(bus, :muscle, NeuralSignal,
               s -> begin
                   muscle_count[] += 1
                   @info "Muscle received neural signal" signal_id=s.id data=s.data
               end;
               receptors=[:motor_neuron])
    
    # Подписка мозга на все сигналы типа :ALL (broadcast)
    subscribe!(bus, :brain, NeuralSignal,
               s -> begin
                   brain_count[] += 1
                   @info "Brain received neural signal" signal_id=s.id data=s.data
               end;
               receptors=Symbol[])  # Получает все нейросигналы
    
    subscribe!(bus, :brain, MetabolicSignal,
               s -> begin
                   brain_count[] += 1
                   @info "Brain received metabolic signal" signal_id=s.id data=s.data
               end;
               receptors=[:glucose_sensor])
    
    println("✅ Зарегистрированы системы: :liver, :muscle, :brain")
    println("   - Liver: HormoneSignal (insulin_receptor, glucagon_receptor)")
    println("   - Muscle: HormoneSignal (insulin_receptor), NeuralSignal (motor_neuron)")
    println("   - Brain: NeuralSignal (all), MetabolicSignal (glucose_sensor)")
    println()
    
    # ========================================================================
    # 2. Публикация событий
    # ========================================================================
    println("📤 Шаг 2: Публикация 1000 событий")
    println("-"^70)
    
    n_hormone = 400
    n_neural = 400
    n_metabolic = 200
    
    # Публикуем гормональные сигналы
    for i in 1:n_hormone
        receptor = i % 2 == 0 ? :insulin_receptor : :glucagon_receptor
        target = i % 3 == 0 ? :ALL : (i % 2 == 0 ? :liver : :muscle)
        
        signal = HormoneSignal(
            float(i * 0.1),  # timestamp
            :pancreas,       # source
            target;
            receptors=[receptor],
            data=(;concentration=rand()*100.0, type=i%2==0?"insulin":"glucagon")
        )
        publish!(bus, :pancreas, signal)
    end
    
    # Публикуем нейросигналы
    for i in 1:n_neural
        target = i % 5 == 0 ? :ALL : :muscle
        signal = NeuralSignal(
            float(i * 0.05),
            :cns,
            target;
            receptors=[i % 3 == 0 ? :sensory_neuron : :motor_neuron],
            data=(;frequency=rand()*100.0, amplitude=rand())
        )
        publish!(bus, :cns, signal)
    end
    
    # Публикуем метаболические сигналы
    for i in 1:n_metabolic
        signal = MetabolicSignal(
            float(i * 0.2),
            :adipose,
            :brain;
            receptors=[i % 2 == 0 ? :glucose_sensor : :leptin_receptor],
            data=(;glucose_level=rand()*200.0, energy_balance=rand()*1000.0)
        )
        publish!(bus, :adipose, signal)
    end
    
    println("✅ Опубликовано:")
    println("   - Гормональных сигналов: $n_hormone")
    println("   - Нейросигналов: $n_neural")
    println("   - Метаболических сигналов: $n_metabolic")
    println("   - Всего: $(n_hormone + n_neural + n_metabolic)")
    println()
    
    # ========================================================================
    # 3. Flush - доставка событий
    # ========================================================================
    println("🔄 Шаг 3: Flush - доставка событий (clock_time=100.0)")
    println("-"^70)
    
    reports = flush!(bus, 100.0)
    
    # Статистика доставки
    delivered = count(r -> r.status == DELIVERED, reports)
    filtered = count(r -> r.status == FILTERED, reports)
    expired = count(r -> r.status == EXPIRED, reports)
    
    println("✅ Доставка завершена:")
    println("   - Доставлено: $delivered")
    println("   - Отфильтровано: $filtered")
    println("   - Просрочено: $expired")
    println()
    
    # Статистика по системам
    println("📊 Статистика по системам:")
    println("   - Liver получил сигналов: $(liver_count[])")
    println("   - Muscle получил сигналов: $(muscle_count[])")
    println("   - Brain получил сигналов: $(brain_count[])")
    println()
    
    # Общая статистика шины
    println("📈 Общая статистика шины:")
    println("   - Опубликовано: $(bus.stats[:published])")
    println("   - Доставлено: $(bus.stats[:delivered])")
    println("   - Отфильтровано: $(bus.stats[:filtered])")
    println("   - Просрочено: $(bus.stats[:expired])")
    println("   - Переполнений: $(bus.stats[:overflow])")
    println()
    
    # ========================================================================
    # 4. Сериализация и чекпоинт
    # ========================================================================
    println("💾 Шаг 4: Сериализация состояния (чекпоинт)")
    println("-"^70)
    
    checkpoint_file = "eventbus_checkpoint.jld2"
    
    # Сохраняем состояние
    save_checkpoint(bus, checkpoint_file)
    println("✅ Чекпоинт сохранён в: $checkpoint_file")
    
    # Запоминаем состояние до очистки
    original_inbox_sizes = Dict(k => length(v) for (k, v) in bus.inboxes)
    original_stats = copy(bus.stats)
    
    # Очищаем шину
    clear!(bus)
    println("✅ Шина очищена")
    
    # Загружаем обратно
    load_checkpoint(bus, checkpoint_file)
    println("✅ Чекпоинт загружен")
    
    # Проверяем восстановление
    restored_inbox_sizes = Dict(k => length(v) for (k, v) in bus.inboxes)
    
    println()
    println("🔍 Проверка восстановления:")
    println("   - Inbox размеры до очистки: $original_inbox_sizes")
    println("   - Inbox размеры после загрузки: $restored_inbox_sizes")
    println("   - Статистика восстановлена: $(bus.stats[:published] == original_stats[:published])")
    println()
    
    # ========================================================================
    # 5. Пример TTL истечения
    # ========================================================================
    println("⏰ Шаг 5: Демонстрация TTL истечения")
    println("-"^70)
    
    clear!(bus)
    
    # Сигнал с коротким TTL
    short_ttl_signal = HormoneSignal(
        0.0,           # timestamp
        :pancreas,
        :liver;
        receptors=[:insulin_receptor],
        data=(;test="short_ttl"),
        ttl=5.0        # TTL = 5 дней
    )
    publish!(bus, :pancreas, short_ttl_signal)
    
    # Flush при clock_time=10 (> 0+5)
    reports_expired = flush!(bus, 10.0)
    expired_count = count(r -> r.status == EXPIRED, reports_expired)
    
    println("✅ Сигнал с TTL=5 не доставлен при clock_time=10")
    println("   - Статус: $(expired_count > 0 ? "EXPIRED" : "DELIVERED")")
    println("   - Просрочено событий: $(bus.stats[:expired])")
    println()
    
    # ========================================================================
    # Финал
    # ========================================================================
    println("="^70)
    println("DEMO завершено успешно!")
    println("="^70)
    
    # Очистка файла чекпоинта
    if isfile(checkpoint_file)
        rm(checkpoint_file)
    end
    
    return nothing
end

# Запуск демо
main()
