# Чек-лист ручной валидации EventBus.jl

## 1. Проверка типостабильности

### Цель
Убедиться, что в горячем пути (flush!) нет типов `Any` и аллокаций.

### Шаги
```julia
using .EventBus
using .SignalTypes

# Создаём шину и подписку
bus = EventBus()
subscribe!(bus, :target, BaseSignal, s -> nothing)

# Публикуем тестовый сигнал
signal = BaseSignal(1.0, :source, :target; receptors=Symbol[])
publish!(bus, :source, signal)

# Проверяем типостабильность
@code_warntype flush!(bus, 2.0)
```

### Критерии passes
- ✅ В выводе `@code_warntype` нет предупреждений с `::Any`
- ✅ Тип возвращаемого значения: `Vector{DeliveryReport}`
- ✅ Локальные переменные имеют конкретные типы (не `::Any`)

### Дополнительная проверка через BenchmarkTools
```julia
using BenchmarkTools
@btime flush!($bus, 2.0)  # Ожидаем минимум аллокаций
```

---

## 2. Имитация Overflow inbox

### Цель
Проверить корректную обработку переполнения inbox (>10_000 событий).

### Шаги
```julia
using .EventBus, .SignalTypes
using Logging

# Настраиваем логирование для перехвата WARN
logger = SimpleLogger(stdout, Logging.Warn)

with_logger(logger) do
    bus = EventBus()
    
    # Подписываем систему
    subscribe!(bus, :target, BaseSignal, s -> nothing)
    
    # Публикуем 10_050 событий
    for i in 1:10_050
        signal = BaseSignal(float(i), :source, :target; 
                            receptors=Symbol[], data=(;index=i))
        publish!(bus, :source, signal)
    end
    
    # Flush
    reports = flush!(bus, 20_000.0)
    
    # Проверяем результат
    println("Размер inbox: $(length(inbox(bus, :target)))")
    println("Статистика overflow: $(bus.stats[:overflow])")
end
```

### Критерии passes
- ✅ Размер inbox ≤ 10_000
- ✅ `bus.stats[:overflow]` ≥ 50
- ✅ В логе присутствует `INBOX_OVERFLOW` (WARN уровень)
- ✅ Дропнуты самые старые события (проверить по индексам)

---

## 3. Чтение лога доставки

### Цель
Научиться интерпретировать отчёты о доставке и логи событий.

### Шаги
```julia
using .EventBus, .SignalTypes
using Logging

# Включаем DEBUG логирование
logger = SimpleLogger(stdout, Logging.Debug)

with_logger(logger) do
    bus = EventBus()
    
    # Подписки с разными рецепторами
    subscribe!(bus, :sys1, HormoneSignal, s -> nothing; 
               receptors=[:receptor_a])
    subscribe!(bus, :sys2, HormoneSignal, s -> nothing; 
               receptors=[:receptor_b])
    
    # Сигнал с рецептором receptor_a
    signal = HormoneSignal(0.0, :source, :ALL; 
                           receptors=[:receptor_a],
                           data=(;test=true))
    publish!(bus, :source, signal)
    
    # Flush
    reports = flush!(bus, 1.0)
    
    # Анализируем отчёты
    println("\n=== Отчёты о доставке ===")
    for r in reports
        status_str = string(r.status)
        println("$(r.target): $status_str ($(r.signal_type))")
    end
    
    # Статистика
    println("\n=== Статистика ===")
    for (k, v) in bus.stats
        println("$k: $v")
    end
end
```

### Ожидаемый вывод
```
=== Отчёты о доставке ===
sys1: DELIVERED (HormoneSignal)
sys2: FILTERED (HormoneSignal)

=== Статистика ===
published: 1
delivered: 1
filtered: 1
expired: 0
overflow: 0
```

### Критерии passes
- ✅ sys1 получил статус `DELIVERED` (рецепторы совпали)
- ✅ sys2 получил статус `FILTERED` (рецепторы не пересеклись)
- ✅ В DEBUG логе видны события `EVENT_DELIVERED` и `EVENT_FILTERED`
- ✅ Статистика соответствует ожидаемой

---

## 4. Проверка TTL истечения

### Цель
Убедиться, что просроченные события маркируются как `EXPIRED`.

### Шаги
```julia
using .EventBus, .SignalTypes

bus = EventBus()
subscribe!(bus, :target, BaseSignal, s -> println("Получен сигнал!"))

# Сигнал с TTL=10 дней
signal = BaseSignal(0.0, :source, :target; 
                    receptors=Symbol[], ttl=10.0)
publish!(bus, :source, signal)

# Flush при clock_time=5 (в пределах TTL)
println("Flush при clock_time=5:")
reports1 = flush!(bus, 5.0)
println("Статус: $(reports1[1].status)")

# Очищаем и тестируем снова
clear!(bus)
signal2 = BaseSignal(0.0, :source, :target; 
                     receptors=Symbol[], ttl=10.0)
publish!(bus, :source, signal2)

# Flush при clock_time=15 (TTL истёк)
println("\nFlush при clock_time=15:")
reports2 = flush!(bus, 15.0)
println("Статус: $(reports2[1].status)")
println("Обработчик вызван: $(bus.stats[:delivered] == 0)")
```

### Критерии passes
- ✅ При clock_time=5 статус `DELIVERED`
- ✅ При clock_time=15 статус `EXPIRED`
- ✅ Обработчик не вызван для просроченного сигнала
- ✅ В логе присутствует `TTL_EXPIRED` (WARN)

---

## 5. Проверка сериализации JLD2 Roundtrip

### Цель
Убедиться, что состояние шины сохраняется и восстанавливается корректно.

### Шаги
```julia
using .EventBus, .SignalTypes
import JLD2

bus = EventBus()

# Регистрируем подписки с config
subscribe!(bus, :sys1, HormoneSignal, s -> nothing;
           receptors=[:r1], config=(;name="test1", priority=1))
subscribe!(bus, :sys2, NeuralSignal, s -> nothing;
           receptors=[:r2], config=(;name="test2", priority=2))

# Публикуем и доставляем сигналы
signal1 = HormoneSignal(1.0, :src, :sys1; receptors=[:r1])
signal2 = NeuralSignal(2.0, :src, :sys2; receptors=[:r2])
publish!(bus, :src, signal1)
publish!(bus, :src, signal2)
flush!(bus, 5.0)

# Сохраняем оригинальное состояние
original_stats = copy(bus.stats)
original_descriptors = copy(bus.descriptors)
original_inbox_sizes = Dict(k => length(v) for (k,v) in bus.inboxes)

# Сохраняем в файл
checkpoint_file = "test_checkpoint.jld2"
save_checkpoint(bus, checkpoint_file)

# Очищаем шину
clear!(bus)
println("После clear!: stats = $(bus.stats)")

# Загружаем обратно
load_checkpoint(bus, checkpoint_file)

# Проверяем восстановление
println("\nПосле load_checkpoint:")
println("stats[:published] = $(bus.stats[:published]) (ожидалось $(original_stats[:published]))")
println("Количество дескрипторов = $(length(bus.descriptors)) (ожидалось $(length(original_descriptors)))")
println("Размеры inbox = $(Dict(k => length(v) for (k,v) in bus.inboxes))")
println("Ожидалось = $original_inbox_sizes")

# Проверка дескрипторов
for (i, desc) in enumerate(bus.descriptors)
    orig_desc = original_descriptors[i]
    println("\nДескриптор $i:")
    println("  system: $(desc.system) == $(orig_desc.system) ? $(desc.system == orig_desc.system)")
    println("  signal_type: $(desc.signal_type) == $(orig_desc.signal_type) ? $(desc.signal_type == orig_desc.signal_type)")
    println("  receptors: $(desc.receptors) == $(orig_desc.receptors) ? $(desc.receptors == orig_desc.receptors)")
end

# Cleanup
rm(checkpoint_file)
```

### Критерии passes
- ✅ `bus.stats[:published]` восстановлено корректно
- ✅ Количество дескрипторов совпадает
- ✅ Поля дескрипторов (system, signal_type, receptors) совпадают
- ✅ Размеры inbox совпадают
- ✅ Файл чекпоинта успешно создан и прочитан

---

## 6. Проверка Broadcast (:ALL)

### Цель
Убедиться, что сигналы с target=:ALL доставляются всем подписчикам типа.

### Шаги
```julia
using .EventBus, .SignalTypes

bus = EventBus()

received = Dict(:a => 0, :b => 0, :c => 0)

subscribe!(bus, :sys_a, BaseSignal, s -> received[:a] += 1)
subscribe!(bus, :sys_b, BaseSignal, s -> received[:b] += 1)
subscribe!(bus, :sys_c, BaseSignal, s -> received[:c] += 1)

# Публикуем broadcast сигнал
signal = BaseSignal(0.0, :source, :ALL; receptors=Symbol[])
publish!(bus, :source, signal)

flush!(bus, 1.0)

println("Результаты доставки:")
for (sys, count) in received
    println("  $sys: $count сигналов")
end
```

### Критерии passes
- ✅ Все три системы получили по 1 сигналу
- ✅ `bus.stats[:delivered]` == 3

---

## 7. Проверка производительности

### Цель
Убедиться, что обработка 50k событий укладывается в лимиты.

### Шаги
```julia
using .EventBus, .SignalTypes
using BenchmarkTools

bus = EventBus()
subscribe!(bus, :target, BaseSignal, s -> nothing)

n_events = 50_000

# Засекаем время
@time begin
    for i in 1:n_events
        signal = BaseSignal(float(i), :source, :target; 
                            receptors=Symbol[], data=(;index=i))
        publish!(bus, :source, signal)
    end
    reports = flush!(bus, float(n_events + 100))
end

println("\nСтатистика:")
println("  Обработано событий: $(length(reports))")
println("  Доставлено: $(bus.stats[:delivered])")

# Проверка аллокаций
allocs = @allocated begin
    bus2 = EventBus()
    subscribe!(bus2, :target, BaseSignal, s -> nothing)
    for i in 1:10_000
        signal = BaseSignal(float(i), :source, :target; 
                            receptors=Symbol[], data=(;index=i))
        publish!(bus2, :source, signal)
    end
    flush!(bus2, 10_100.0)
end
println("\nАллокации на 10k событий: $(allocs / 1_048_576) MB")
```

### Критерии passes
- ✅ Время обработки 50k событий < 2000 ms (с запасом для CI)
- ✅ Аллокации на 10k событий < 10 MB
- ✅ Все события обработаны (`length(reports) == n_events`)

---

## Сводная таблица проверок

| № | Проверка | Статус | Примечание |
|---|----------|--------|------------|
| 1 | Типостабильность flush! | ☐ | Нет `::Any` в @code_warntype |
| 2 | Overflow inbox | ☐ | 10_050 событий → 10_000 в inbox |
| 3 | Чтение логов | ☐ | EVENT_DELIVERED, EVENT_FILTERED видны |
| 4 | TTL expiration | ☐ | EXPIRED при clock_time > timestamp+ttl |
| 5 | JLD2 roundtrip | ☐ | Stats, descriptors, inboxes восстановлены |
| 6 | Broadcast :ALL | ☐ | Все подписчики получили сигнал |
| 7 | Производительность | ☐ | 50k < 2000ms, аллокации в норме |

---

## Команды для быстрой валидации

```bash
# Запустить все тесты
julia --project test/runtests.jl

# Запустить демо
julia --project examples/demo_bus.jl

# Проверка типостабильности (REPL)
julia --project -e '
    include("src/EventBus.jl");
    include("src/SignalTypes.jl");
    using .EventBus, .SignalTypes;
    bus = EventBus();
    subscribe!(bus, :t, BaseSignal, s->nothing);
    publish!(bus, :s, BaseSignal(1.0,:s,:t;receptors=Symbol[]));
    @code_warntype flush!(bus, 2.0)
'
```
