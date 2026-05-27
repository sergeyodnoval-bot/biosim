# EventBus.jl API Documentation

## Обзор

`EventBus.jl` — типизированная шина событий для межсистемной коммуникации в симуляторе физиологических систем. Поддерживает маршрутизацию по целевым органам/рецепторам, буферизацию в рамках симуляционного шага, TTL и атомарную сериализацию состояния для чекпоинтов.

## Основные компоненты

### Типы сигналов

| Тип | Описание | TTL по умолчанию |
|-----|----------|------------------|
| `AbstractSignal` | Базовый абстрактный тип | — |
| `BaseSignal` | Базовая реализация | 300 дней |
| `NeuralSignal` | Нейросигнал (быстрая передача) | 10 дней |
| `HormoneSignal` | Гормональный сигнал (медленная регуляция) | 300 дней |
| `MetabolicSignal` | Метаболический сигнал | 100 дней |

### Структура сигнала (`AbstractSignal`)

```julia
struct BaseSignal <: AbstractSignal
    id::UUID              # Уникальный идентификатор
    timestamp::Float64    # Время создания (время симуляции)
    source::Symbol        # Система-источник
    target::Symbol        # Целевая система (:ALL для broadcast)
    receptors::Vector{Symbol}  # Рецепторы сигнала
    data::NamedTuple      # Данные (immutable примитивы)
    ttl::Float64          # Время жизни в днях
end
```

## API методы

### Подписка на события

```julia
subscribe!(bus::EventBus, system::Symbol, signal_type::Type, handler::Function;
           receptors::Vector{Symbol}=Symbol[], config::NamedTuple=(;))
```

**Параметры:**
- `bus` — экземпляр шины событий
- `system` — символ системы-подписчика (например, `:liver`)
- `signal_type` — тип сигнала для подписки (например, `HormoneSignal`)
- `handler` — функция-обработчик с сигнатурой `handler(signal::signal_type)`
- `receptors` — список рецепторов для фильтрации (пустой = получать все)
- `config` — дополнительная конфигурация (сохраняется в чекпоинт)

**Пример:**
```julia
subscribe!(bus, :liver, HormoneSignal, handle_insulin; 
           receptors=[:insulin_receptor, :glucagon_receptor])
```

### Публикация событий

```julia
publish!(bus::EventBus, source::Symbol, signal::AbstractSignal)
```

**Параметры:**
- `bus` — экземпляр шины событий
- `source` — система-источник (перезаписывает поле `signal.source`)
- `signal` — экземпляр сигнала

**Важно:** `publish!` не вызывает обработчики немедленно. Сигнал добавляется в буфер и будет доставлен при вызове `flush!`.

**Пример:**
```julia
signal = HormoneSignal(1.0, :pancreas, :liver; 
                       receptors=[:insulin_receptor],
                       data=(;concentration=50.0))
publish!(bus, :pancreas, signal)
```

### Доставка событий (Flush)

```julia
flush!(bus::EventBus, clock_time::Float64) -> Vector{DeliveryReport}
```

**Параметры:**
- `bus` — экземпляр шины событий
- `clock_time` — текущее время симуляции

**Возвращает:** Вектор отчётов о доставке (`DeliveryReport`)

**Процесс:**
1. Сортировка сигналов по `timestamp`
2. Проверка TTL для каждого сигнала
3. Определение целевых систем (по `target` или `:ALL`)
4. Проверка рецепторов для каждой подписки
5. Добавление в inbox и вызов обработчиков

**Пример:**
```julia
reports = flush!(bus, 100.0)
for report in reports
    println("$(report.target): $(report.status)")
end
```

### Очистка состояния

```julia
clear!(bus::EventBus)
```

Очищает буферы, inbox'ы и статистику. Подписки сохраняются.

### Получение содержимого inbox

```julia
inbox(bus::EventBus, system::Symbol) -> Vector{AbstractSignal}
```

Возвращает копию очереди сигналов системы (для отладки и чекпоинтов).

## Маршрутизация

### Правила доставки

1. **Точечная доставка**: Если `signal.target != :ALL`, сигнал доставляется только указанной системе.

2. **Broadcast**: Если `signal.target == :ALL`, сигнал доставляется всем подписчикам данного типа сигнала.

3. **Фильтрация по рецепторам**: Обработчик вызывается только если пересечение рецепторов сигнала и подписки не пусто:
   ```julia
   if !isdisjoint(signal.receptors, subscriber.receptors)
       deliver!(handler, signal)
   end
   ```

### Таблица маршрутизации

| Условие | Результат |
|---------|-----------|
| `signal.target == :ALL` | Все подписчики типа получают сигнал |
| `signal.target == :specific` | Только указанная система |
| `intersect(signal.receptors, sub.receptors) == ∅` | Сигнал отфильтрован |
| `intersect(signal.receptors, sub.receptors) ≠ ∅` | Сигнал доставлен |

## Статусы доставки

```julia
@enum DeliveryStatus begin
    DELIVERED   # Успешно доставлен в inbox
    FILTERED    # Отфильтрован (нет подписчиков или рецепторов)
    EXPIRED     # Просрочен (превышен TTL)
    OVERFLOW    # Inbox переполнен (старые сигналы удалены)
end
```

### Отчёт о доставке

```julia
struct DeliveryReport
    target::Symbol        # Целевая система
    signal_type::String   # Имя типа сигнала
    status::DeliveryStatus
    signal_id::UUID       # ID сигнала
    clock_time::Float64   # Время симуляции
end
```

## Логирование

### События шины

| Событие | Уровень | Описание |
|---------|---------|----------|
| `EVENT_PUBLISHED` | INFO | Сигнал опубликован |
| `EVENT_DELIVERED` | DEBUG | Сигнал доставлен |
| `EVENT_FILTERED` | DEBUG | Сигнал отфильтрован |
| `INBOX_OVERFLOW` | WARN | Переполнение inbox |
| `TTL_EXPIRED` | WARN | Истечение TTL |

**Пример настройки логирования:**
```julia
using Logging
SimpleLogger(stdout, Logging.Debug) do logger
    with_logger(logger) do
        # работа с шиной
    end
end
```

## Сериализация (Чекпоинты)

### Сохранение

```julia
save_checkpoint(bus::EventBus, filename::String)
```

Сохраняет в JLD2:
- `pending_signals` — буфер опубликованных сигналов
- `inboxes` — очереди сигналов систем
- `descriptors` — дескрипторы подписок (без handlers)
- `stats` — статистика

### Загрузка

```julia
load_checkpoint(bus::EventBus, filename::String)
```

**Важно:** Handlers не сохраняются! После загрузки необходимо заново зарегистрировать обработчики кодом приложения.

### Паттерн использования

```julia
# Инициализация
bus = EventBus()
register_handlers!(bus)  # Ваша функция регистрации

# Сохранение
save_checkpoint(bus, "checkpoint.jld2")

# Восстановление
clear!(bus)
load_checkpoint(bus, "checkpoint.jld2")
register_handlers!(bus)  # Повторная регистрация handlers
```

## Ограничения

### Константы

| Константа | Значение | Описание |
|-----------|----------|----------|
| `MAX_INBOX_SIZE` | 10 000 | Макс. размер inbox на систему |
| `DEFAULT_TTL` | 300.0 | TTL по умолчанию (дни) |

### Требования к данным

- `data::NamedTuple` должен содержать только immutable примитивы:
  - ✅ `Float64`, `Int`, `Bool`, `String`, `Symbol`
  - ❌ Функции, замыкания, mutable структуры, Dict

### Производительность

- RAM ≤ 50 MB на инстанс
- CPU ≤ 1 core
- 50k publish + flush ≤ 500 ms (целевое значение)

## Интеграция с Clock

```julia
# Псевдокод интеграции
function simulation_step!(clock, bus, systems)
    # 1. Системы публикуют сигналы
    for system in systems
        generate_signals!(system, bus)
    end
    
    # 2. Flush шины по времени симуляции
    current_time = get_time(clock)
    reports = flush!(bus, current_time)
    
    # 3. Обработка отчётов (опционально)
    process_delivery_reports!(reports)
    
    # 4. Чекпоинт по условию
    if should_checkpoint(clock)
        save_checkpoint(bus, "checkpoint_$(current_time).jld2")
    end
end
```

## Примеры использования

### Базовый пример

```julia
using .EventBus, .SignalTypes

bus = EventBus()

# Подписка
subscribe!(bus, :liver, HormoneSignal, s -> @info "Liver got: \$s";
           receptors=[:insulin_receptor])

# Публикация
signal = HormoneSignal(0.0, :pancreas, :liver;
                       receptors=[:insulin_receptor],
                       data=(;concentration=100.0))
publish!(bus, :pancreas, signal)

# Доставка
reports = flush!(bus, 1.0)
```

### Broadcast всем системам

```julia
subscribe!(bus, :sys1, BaseSignal, handler1)
subscribe!(bus, :sys2, BaseSignal, handler2)

signal = BaseSignal(0.0, :source, :ALL; receptors=Symbol[])
publish!(bus, :source, signal)
flush!(bus, 1.0)  # Оба обработчика будут вызваны
```

### Фильтрация по рецепторам

```julia
# Подписка с рецепторами
subscribe!(bus, :target, BaseSignal, handler;
           receptors=[:receptor_a, :receptor_b])

# Сигнал с частичным совпадением
signal = BaseSignal(0.0, :source, :target;
                    receptors=[:receptor_b, :receptor_c])
# Будет доставлен (пересечение: [:receptor_b])

# Сигнал без совпадения
signal2 = BaseSignal(0.0, :source, :target;
                     receptors=[:receptor_d])
# Будет отфильтрован (пересечение: ∅)
```

## Отладка

### Проверка типостабильности

```julia
using .EventBus
bus = EventBus()
subscribe!(bus, :target, BaseSignal, s -> nothing)
signal = BaseSignal(1.0, :source, :target; receptors=Symbol[])
publish!(bus, :source, signal)

# Проверка типов
@code_warntype flush!(bus, 2.0)
```

### Мониторинг статистики

```julia
println("Статистика шины:")
for (key, value) in bus.stats
    println("  $key: $value")
end
```

### Проверка inbox

```julia
signals = inbox(bus, :system_name)
println("В inbox системы: $(length(signals)) сигналов")
for sig in signals
    println("  - $(typeof(sig)): $(sig.id)")
end
```

## Changelog

### Версия 0.5 (Фаза 1)
- ✅ Базовая маршрутизация по target
- ✅ Фильтрация по рецепторам
- ✅ TTL поддержка
- ✅ Буферизация и flush
- ✅ Сериализация в JLD2
- ✅ Статистика доставки
- ✅ Логирование событий
