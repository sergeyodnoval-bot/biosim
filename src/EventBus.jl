module EventBus

using UUIDs
using Logging
using JLD2
using StructTypes
using DataStructures

# SignalTypes должен быть загружен первым для AbstractSignal
include("SignalTypes.jl")
using .SignalTypes: AbstractSignal, NeuralSignal, HormoneSignal, MetabolicSignal

export AbstractSignal, BaseSignal, DeliveryReport, DeliveryStatus, NeuralSignal, HormoneSignal, MetabolicSignal
export EventBus, subscribe!, publish!, flush!, clear!, inbox
export EVENT_PUBLISHED, EVENT_DELIVERED, EVENT_FILTERED, INBOX_OVERFLOW, TTL_EXPIRED

# ============================================================================
# CONSTANTS & CONFIG
# ============================================================================

const MAX_INBOX_SIZE::Int = 10_000
const DEFAULT_TTL::Float64 = 300.0  # days of simulation time

@enum DeliveryStatus begin
    DELIVERED
    FILTERED
    EXPIRED
    OVERFLOW
end

# Log event symbols
const EVENT_PUBLISHED = :EVENT_PUBLISHED
const EVENT_DELIVERED = :EVENT_DELIVERED
const EVENT_FILTERED = :EVENT_FILTERED
const INBOX_OVERFLOW = :INBOX_OVERFLOW
const TTL_EXPIRED = :TTL_EXPIRED

# ============================================================================
# SIGNAL TYPES (moved to SignalTypes.jl, kept here for backward compat)
# AbstractSignal is now defined in SignalTypes module
# ============================================================================

"""
    BaseSignal <: AbstractSignal

Базовая реализация сигнала с всеми необходимыми полями для маршрутизации.

# Fields
- `id::UUID`: Уникальный идентификатор сигнала
- `timestamp::Float64`: Время создания сигнала (время симуляции)
- `source::Symbol`: Система-источник сигнала
- `target::Symbol`: Целевая система (`:ALL` для broadcast)
- `receptors::Vector{Symbol}`: Список рецепторов, к которым относится сигнал
- `data::NamedTuple`: Данные сигнала (только immutable примитивы)
- `ttl::Float64`: Время жизни сигнала в днях симуляционного времени
"""
Base.@kwdef struct BaseSignal <: AbstractSignal
    id::UUID = uuid4()
    timestamp::Float64
    source::Symbol
    target::Symbol
    receptors::Vector{Symbol}
    data::NamedTuple
    ttl::Float64 = DEFAULT_TTL
end

# ============================================================================
# DELIVERY REPORT
# ============================================================================

"""
    DeliveryReport

Отчёт о доставке сигнала.

# Fields
- `target::Symbol`: Целевая система
- `signal_type::String`: Тип сигнала (имя типа)
- `status::DeliveryStatus`: Статус доставки
- `signal_id::UUID`: ID сигнала
- `clock_time::Float64`: Время симуляции при доставке
"""
struct DeliveryReport
    target::Symbol
    signal_type::String
    status::DeliveryStatus
    signal_id::UUID
    clock_time::Float64
end

# ============================================================================
# SUBSCRIPTION DESCRIPTOR (для сериализации)
# ============================================================================

"""
    SubscriptionDescriptor

Дескриптор подписки для сериализации в чекпоинты.
Не содержит функций, только данные для восстановления маршрутизации.

# Fields
- `system::Symbol`: Система-подписчик
- `signal_type::String`: Имя типа сигнала (полное имя модуля)
- `receptors::Vector{Symbol}`: Рецепторы подписчика
- `config::NamedTuple`: Дополнительная конфигурация
"""
struct SubscriptionDescriptor
    system::Symbol
    signal_type::String
    receptors::Vector{Symbol}
    config::NamedTuple
end

# ============================================================================
# EVENT BUS STATE
# ============================================================================

"""
    EventBus

Основной тип шины событий.

# Fields
- `subscriptions`: Dict{(system, signal_type) => Vector{(handler, receptors)}}
- `pending_signals`: Vector{AbstractSignal} - буфер опубликованных сигналов
- `inboxes`: Dict{system => Vector{AbstractSignal}}
- `descriptors`: Vector{SubscriptionDescriptor} - для сериализации
- `stats`: статистика шины
"""
mutable struct EventBus
    subscriptions::Dict{Tuple{Symbol, String}, Vector{Tuple{Function, Vector{Symbol}}}}
    pending_signals::Vector{AbstractSignal}
    inboxes::Dict{Symbol, Vector{AbstractSignal}}
    descriptors::Vector{SubscriptionDescriptor}
    stats::Dict{Symbol, Int}
    
    function EventBus()
        bus = new()
        bus.subscriptions = Dict{Tuple{Symbol, String}, Vector{Tuple{Function, Vector{Symbol}}}}()
        bus.pending_signals = Vector{AbstractSignal}()
        bus.inboxes = Dict{Symbol, Vector{AbstractSignal}}()
        bus.descriptors = Vector{SubscriptionDescriptor}()
        bus.stats = Dict{Symbol, Int}(
            :published => 0,
            :delivered => 0,
            :filtered => 0,
            :expired => 0,
            :overflow => 0
        )
        return bus
    end
end

# ============================================================================
# PUBLIC API
# ============================================================================

"""
    subscribe!(bus::EventBus, system::Symbol, signal_type::Type, handler::Function; 
               receptors::Vector{Symbol}=Symbol[], config::NamedTuple=(;))

Подписать систему на обработку сигналов определённого типа.

# Arguments
- `bus`: Шина событий
- `system`: Символ системы-подписчика
- `signal_type`: Тип сигнала для подписки
- `handler`: Функция-обработчик (сигнатура: handler(signal::signal_type))
- `receptors`: Список рецепторов для фильтрации (по умолчанию пустой - получать все)
- `config`: Дополнительная конфигурация подписки

# Returns
`nothing`

# Example
```julia
subscribe!(bus, :liver, HormoneSignal, handle_insulin; receptors=[:insulin_receptor])
```
"""
function subscribe!(bus::EventBus, system::Symbol, signal_type::Type, handler::Function; 
                    receptors::Vector{Symbol}=Symbol[], config::NamedTuple=(;))
    key = (system, string(signal_type))
    
    if !haskey(bus.subscriptions, key)
        bus.subscriptions[key] = Vector{Tuple{Function, Vector{Symbol}}}()
    end
    
    push!(bus.subscriptions[key], (handler, receptors))
    
    # Сохраняем дескриптор для сериализации
    descriptor = SubscriptionDescriptor(
        system,
        string(signal_type),
        copy(receptors),
        config
    )
    push!(bus.descriptors, descriptor)
    
    @debug "Subscription registered" system=system signal_type=signal_type receptors=receptors
    
    return nothing
end

"""
    publish!(bus::EventBus, source::Symbol, signal::AbstractSignal)

Опубликовать сигнал в шину событий. Сигнал добавляется в буфер и будет
доставлен при вызове `flush!`.

# Arguments
- `bus`: Шина событий
- `source`: Система-источник
- `signal`: Сигнал для публикации

# Returns
`nothing`

# Notes
- Функция не вызывает обработчики немедленно
- Сигнал должен иметь корректное поле `timestamp`
"""
function publish!(bus::EventBus, source::Symbol, signal::AbstractSignal)
    # Обновляем источник сигнала
    setfield!(signal, :source, source)
    
    push!(bus.pending_signals, signal)
    bus.stats[:published] += 1
    
    @info EVENT_PUBLISHED source=source signal_type=typeof(signal) signal_id=signal.id
    
    return nothing
end

"""
    flush!(bus::EventBus, clock_time::Float64) -> Vector{DeliveryReport}

Обработать все накопленные сигналы: распределить по inbox'ам, проверить TTL,
вызвать обработчики в порядке временных меток.

# Arguments
- `bus`: Шина событий
- `clock_time`: Текущее время симуляции

# Returns
Вектор отчётов о доставке для каждого обработанного сигнала.

# Notes
- Сигналы сортируются по `timestamp` перед обработкой
- Просроченные сигналы (clock_time > timestamp + ttl) маркируются как EXPIRED
- При переполнении inbox старые сигналы удаляются
"""
function flush!(bus::EventBus, clock_time::Float64)::Vector{DeliveryReport}
    reports = Vector{DeliveryReport}()
    
    # Сортируем сигналы по timestamp
    sort!(bus.pending_signals, by = s -> s.timestamp)
    
    for signal in bus.pending_signals
        signal_reports = process_signal!(bus, signal, clock_time)
        append!(reports, signal_reports)
    end
    
    # Очищаем буфер после обработки
    empty!(bus.pending_signals)
    
    return reports
end

"""
    clear!(bus::EventBus)

Очистить все состояния шины: буферы, inbox'ы, статистику.
Подписки сохраняются.

# Returns
`nothing`
"""
function clear!(bus::EventBus)
    empty!(bus.pending_signals)
    for inbox in values(bus.inboxes)
        empty!(inbox)
    end
    # Сбрасываем статистику
    bus.stats[:published] = 0
    bus.stats[:delivered] = 0
    bus.stats[:filtered] = 0
    bus.stats[:expired] = 0
    bus.stats[:overflow] = 0
    
    @debug "EventBus cleared"
    
    return nothing
end

"""
    inbox(bus::EventBus, system::Symbol) -> Vector{AbstractSignal}

Получить содержимое inbox указанной системы (для отладки и чекпоинтов).

# Arguments
- `bus`: Шина событий
- `system`: Символ системы

# Returns
Вектор сигналов в inbox системы (копия).
"""
function inbox(bus::EventBus, system::Symbol)::Vector{AbstractSignal}
    if !haskey(bus.inboxes, system)
        return Vector{AbstractSignal}()
    end
    return copy(bus.inboxes[system])
end

# ============================================================================
# INTERNAL FUNCTIONS
# ============================================================================

function process_signal!(bus::EventBus, signal::AbstractSignal, clock_time::Float64)::Vector{DeliveryReport}
    reports = Vector{DeliveryReport}()
    signal_type_str = string(typeof(signal))
    
    # Проверка TTL
    if clock_time > signal.timestamp + signal.ttl
        bus.stats[:expired] += 1
        report = DeliveryReport(signal.target, signal_type_str, EXPIRED, signal.id, clock_time)
        push!(reports, report)
        @warn TTL_EXPIRED signal_id=signal.id age=(clock_time - signal.timestamp) ttl=signal.ttl
        return reports
    end
    
    # Определяем целевые системы
    targets = determine_targets(bus, signal)
    
    for target in targets
        target_report = deliver_to_target!(bus, signal, target, clock_time)
        push!(reports, target_report)
    end
    
    return reports
end

function determine_targets(bus::EventBus, signal::AbstractSignal)::Vector{Symbol}
    targets = Vector{Symbol}()
    
    if signal.target == :ALL
        # Broadcast всем подписчикам этого типа сигнала
        signal_type_str = string(typeof(signal))
        for (sys, sig_type) in keys(bus.subscriptions)
            if sig_type == signal_type_str
                push!(targets, sys)
            end
        end
    else
        # Точечная доставка
        push!(targets, signal.target)
    end
    
    return unique(targets)
end

function deliver_to_target!(bus::EventBus, signal::AbstractSignal, target::Symbol, clock_time::Float64)::DeliveryReport
    signal_type_str = string(typeof(signal))
    key = (target, signal_type_str)
    
    # Проверяем наличие подписчиков
    if !haskey(bus.subscriptions, key)
        # Нет подписчиков - фильтруем
        bus.stats[:filtered] += 1
        report = DeliveryReport(target, signal_type_str, FILTERED, signal.id, clock_time)
        @debug EVENT_FILTERED target=target signal_type=signal_type_str reason="no_subscribers"
        return report
    end
    
    subscribers = bus.subscriptions[key]
    delivered = false
    
    # Инициализируем inbox если нужно
    if !haskey(bus.inboxes, target)
        bus.inboxes[target] = Vector{AbstractSignal}()
    end
    
    inbox_vec = bus.inboxes[target]
    
    for (handler, sub_receptors) in subscribers
        # Проверка рецепторов
        if !isdisjoint(signal.receptors, sub_receptors) || isempty(sub_receptors)
            # Добавляем в inbox
            if length(inbox_vec) >= MAX_INBOX_SIZE
                # Overflow - удаляем самый старый
                popfirst!(inbox_vec)
                bus.stats[:overflow] += 1
                @warn INBOX_OVERFLOW system=target max_size=MAX_INBOX_SIZE dropped=true
            end
            
            push!(inbox_vec, signal)
            delivered = true
            
            # Вызываем обработчик
            try
                handler(signal)
            catch e
                @error "Handler error" target=target signal_type=signal_type_str error=e
            end
        end
    end
    
    if delivered
        bus.stats[:delivered] += 1
        report = DeliveryReport(target, signal_type_str, DELIVERED, signal.id, clock_time)
        @debug EVENT_DELIVERED target=target signal_type=signal_type_str signal_id=signal.id
        return report
    else
        bus.stats[:filtered] += 1
        report = DeliveryReport(target, signal_type_str, FILTERED, signal.id, clock_time)
        @debug EVENT_FILTERED target=target signal_type=signal_type_str reason="no_matching_receptors"
        return report
    end
end

# ============================================================================
# SERIALIZATION UTILS
# ============================================================================

"""
    save_checkpoint(bus::EventBus, filename::String)

Сохранить состояние шины в файл JLD2.

# Arguments
- `bus`: Шина событий
- `filename`: Путь к файлу

# Notes
- Сохраняются: pending_signals, inboxes, descriptors, stats
- Handlers НЕ сохраняются (восстанавливаются кодом приложения)
"""
function save_checkpoint(bus::EventBus, filename::String)
    jldopen(filename, "w") do file
        file["pending_signals"] = bus.pending_signals
        file["inboxes"] = bus.inboxes
        file["descriptors"] = bus.descriptors
        file["stats"] = bus.stats
    end
    @info "Checkpoint saved" filename=filename
end

"""
    load_checkpoint(bus::EventBus, filename::String)

Загрузить состояние шины из файла JLD2.

# Arguments
- `bus`: Шина событий
- `filename`: Путь к файлу

# Notes
- Восстанавливаются: pending_signals, inboxes, descriptors, stats
- Handlers должны быть зарегистрированы заново через subscribe!
"""
function load_checkpoint(bus::EventBus, filename::String)
    jldopen(filename, "r") do file
        bus.pending_signals = file["pending_signals"]
        bus.inboxes = file["inboxes"]
        bus.descriptors = file["descriptors"]
        bus.stats = file["stats"]
        
        # Восстанавливаем subscriptions из descriptors (без handlers)
        for desc in bus.descriptors
            key = (desc.system, desc.signal_type)
            if !haskey(bus.subscriptions, key)
                bus.subscriptions[key] = Vector{Tuple{Function, Vector{Symbol}}}()
            end
            # Пустой handler placeholder - должен быть заменён приложением
            push!(bus.subscriptions[key], (s -> nothing, desc.receptors))
        end
    end
    @info "Checkpoint loaded" filename=filename
end

end # module EventBus
