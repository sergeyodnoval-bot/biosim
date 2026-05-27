module EventBus

using UUIDs
using Logging
using JLD2
using StructTypes
using DataStructures

include("SignalTypes.jl")
using .SignalTypes: AbstractSignal, NeuralSignal, HormoneSignal, MetabolicSignal

export AbstractSignal, BaseSignal, DeliveryReport, DeliveryStatus, NeuralSignal, HormoneSignal, MetabolicSignal
export EventBus, subscribe!, publish!, flush!, clear!, inbox
export EVENT_PUBLISHED, EVENT_DELIVERED, EVENT_FILTERED, INBOX_OVERFLOW, TTL_EXPIRED
export save_checkpoint, load_checkpoint, MAX_INBOX_SIZE, DEFAULT_TTL
export DELIVERED, FILTERED, EXPIRED, OVERFLOW  # Экспортируем enum значения
export save_state, load_state!

# ============================================================================
# CONSTANTS & CONFIG
# ============================================================================

const MAX_INBOX_SIZE::Int = 10_000
const DEFAULT_TTL::Float64 = 300.0

@enum DeliveryStatus begin
    DELIVERED
    FILTERED
    EXPIRED
    OVERFLOW
end

const EVENT_PUBLISHED = :EVENT_PUBLISHED
const EVENT_DELIVERED = :EVENT_DELIVERED
const EVENT_FILTERED = :EVENT_FILTERED
const INBOX_OVERFLOW = :INBOX_OVERFLOW
const TTL_EXPIRED = :TTL_EXPIRED

# ============================================================================
# SIGNAL TYPES
# ============================================================================

mutable struct BaseSignal <: AbstractSignal
    id::UUID
    timestamp::Float64
    source::Symbol
    target::Symbol
    receptors::Vector{Symbol}
    data::NamedTuple
    ttl::Float64
    
    function BaseSignal(; id::UUID=uuid4(), timestamp::Float64, source::Symbol, target::Symbol,
                        receptors::Vector{Symbol}=Symbol[], data::NamedTuple=(;), ttl::Float64=DEFAULT_TTL)
        new(id, timestamp, source, target, receptors, data, ttl)
    end
end

# ============================================================================
# DELIVERY REPORT
# ============================================================================

struct DeliveryReport
    target::Symbol
    signal_type::String
    status::DeliveryStatus
    signal_id::UUID
    clock_time::Float64
end

# ============================================================================
# SUBSCRIPTION DESCRIPTOR
# ============================================================================

struct SubscriptionDescriptor
    system::Symbol
    signal_type::String
    receptors::Vector{Symbol}
    config::NamedTuple
end

# ============================================================================
# EVENT BUS STATE
# ============================================================================

mutable struct EventBus
    subscriptions::Dict{Tuple{Symbol, String}, Vector{Tuple{Function, Vector{Symbol}}}}
    pending_signals::Vector{AbstractSignal}
    inboxes::Dict{Symbol, Vector{AbstractSignal}}
    descriptors::Vector{SubscriptionDescriptor}
    stats::Dict{Symbol, Int}
    
    function EventBus()
        new(
            Dict{Tuple{Symbol, String}, Vector{Tuple{Function, Vector{Symbol}}}}(),
            Vector{AbstractSignal}(),
            Dict{Symbol, Vector{AbstractSignal}}(),
            Vector{SubscriptionDescriptor}(),
            Dict{Symbol, Int}(
                :published => 0,
                :delivered => 0,
                :filtered => 0,
                :expired => 0,
                :overflow => 0
            )
        )
    end
end

# ============================================================================
# PUBLIC API
# ============================================================================

function subscribe!(bus::EventBus, system::Symbol, signal_type::Type, handler::Function; 
                    receptors::Vector{Symbol}=Symbol[], config::NamedTuple=(;))
    key = (system, string(signal_type))
    
    if !haskey(bus.subscriptions, key)
        bus.subscriptions[key] = Vector{Tuple{Function, Vector{Symbol}}}()
    end
    
    push!(bus.subscriptions[key], (handler, receptors))
    
    descriptor = SubscriptionDescriptor(system, string(signal_type), copy(receptors), config)
    push!(bus.descriptors, descriptor)
    
    return nothing
end

function publish!(bus::EventBus, source::Symbol, signal::AbstractSignal)
    # Создаём копию сигнала с новым источником
    signal_copy = copy_with_source(signal, source)
    push!(bus.pending_signals, signal_copy)
    bus.stats[:published] += 1
    return nothing
end

function copy_with_source(signal::BaseSignal, source::Symbol)
    return BaseSignal(
        id=signal.id,
        timestamp=signal.timestamp,
        source=source,
        target=signal.target,
        receptors=copy(signal.receptors),
        data=signal.data,
        ttl=signal.ttl
    )
end

function copy_with_source(signal::NeuralSignal, source::Symbol)
    return NeuralSignal(signal.timestamp, source, signal.target;
                       receptors=copy(signal.receptors),
                       data=signal.data,
                       ttl=signal.ttl)
end

function copy_with_source(signal::HormoneSignal, source::Symbol)
    return HormoneSignal(signal.timestamp, source, signal.target;
                        receptors=copy(signal.receptors),
                        data=signal.data,
                        ttl=signal.ttl)
end

function copy_with_source(signal::MetabolicSignal, source::Symbol)
    return MetabolicSignal(signal.timestamp, source, signal.target;
                          receptors=copy(signal.receptors),
                          data=signal.data,
                          ttl=signal.ttl)
end

function flush!(bus::EventBus, clock_time::Float64)::Vector{DeliveryReport}
    reports = Vector{DeliveryReport}()
    
    # Сортируем сигналы по timestamp
    sort!(bus.pending_signals, by = s -> s.timestamp)
    
    for signal in bus.pending_signals
        signal_reports = process_signal!(bus, signal, clock_time)
        append!(reports, signal_reports)
    end
    
    empty!(bus.pending_signals)
    return reports
end

function clear!(bus::EventBus)
    empty!(bus.pending_signals)
    for key in keys(bus.inboxes)
        empty!(bus.inboxes[key])
    end
    for key in keys(bus.stats)
        bus.stats[key] = 0
    end
    return nothing
end

function inbox(bus::EventBus, system::Symbol)::Vector{AbstractSignal}
    return get(bus.inboxes, system, Vector{AbstractSignal}())
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
        push!(reports, DeliveryReport(signal.target, signal_type_str, EXPIRED, signal.id, clock_time))
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
    if signal.target == :ALL
        signal_type_str = string(typeof(signal))
        targets = Symbol[]
        for (sys, sig_type) in keys(bus.subscriptions)
            if sig_type == signal_type_str
                push!(targets, sys)
            end
        end
        return unique(targets)
    else
        return [signal.target]
    end
end

function deliver_to_target!(bus::EventBus, signal::AbstractSignal, target::Symbol, clock_time::Float64)::DeliveryReport
    signal_type_str = string(typeof(signal))
    key = (target, signal_type_str)
    
    # Проверяем наличие подписчиков
    if !haskey(bus.subscriptions, key)
        bus.stats[:filtered] += 1
        return DeliveryReport(target, signal_type_str, FILTERED, signal.id, clock_time)
    end
    
    # Инициализируем inbox если нужно
    if !haskey(bus.inboxes, target)
        bus.inboxes[target] = Vector{AbstractSignal}()
    end
    
    inbox_vec = bus.inboxes[target]
    subscribers = bus.subscriptions[key]
    delivered = false
    
    for (handler, sub_receptors) in subscribers
        # ИСПРАВЛЕННАЯ ЛОГИКА:
        # Сигнал доставляется если:
        # 1. У подписчика нет фильтрации по рецепторам (пустой список), ИЛИ
        # 2. У сигнала нет рецепторов (пустой список - broadcast для всех), ИЛИ
        # 3. Есть пересечение рецепторов сигнала и подписчика
        signal_has_no_receptors = isempty(signal.receptors)
        subscriber_has_no_filters = isempty(sub_receptors)
        has_intersection = !isempty(intersect(signal.receptors, sub_receptors))
        
        should_deliver = subscriber_has_no_filters || signal_has_no_receptors || has_intersection
        
        if should_deliver
            # Проверка переполнения
            if length(inbox_vec) >= MAX_INBOX_SIZE
                popfirst!(inbox_vec)
                bus.stats[:overflow] += 1
                @warn INBOX_OVERFLOW system=target max_size=MAX_INBOX_SIZE
            end
            
            push!(inbox_vec, signal)
            delivered = true
            
            # Вызываем обработчик
            try
                handler(signal)
            catch e
                @error "Handler error" target=target error=e
            end
        end
    end
    
    if delivered
        bus.stats[:delivered] += 1
        return DeliveryReport(target, signal_type_str, DELIVERED, signal.id, clock_time)
    else
        bus.stats[:filtered] += 1
        return DeliveryReport(target, signal_type_str, FILTERED, signal.id, clock_time)
    end
end

# ============================================================================
# SERIALIZATION UTILS
# ============================================================================

function save_checkpoint(bus::EventBus, filename::String)
    jldopen(filename, "w") do file
        file["pending_signals"] = bus.pending_signals
        file["inboxes"] = bus.inboxes
        file["descriptors"] = bus.descriptors
        file["stats"] = bus.stats
    end
    @info "Checkpoint saved" filename=filename
end

function load_checkpoint(bus::EventBus, filename::String)
    jldopen(filename, "r") do file
        bus.pending_signals = file["pending_signals"]
        bus.inboxes = file["inboxes"]
        bus.descriptors = file["descriptors"]
        bus.stats = file["stats"]
    end
    @info "Checkpoint loaded" filename=filename
end

# ============================================================================
# SERIALIZATION (for kernel checkpointing)
# ============================================================================

"""
    save_state(bus::EventBus) -> NamedTuple

Сохраняет состояние шины в JLD2-совместимом формате.
Возвращает подписки и ожидающие события без функций-обработчиков.
"""
function save_state(bus::EventBus)::NamedTuple
    # Преобразуем подписки в сериализуемый формат (без функций)
    subscriptions_data = Vector{NamedTuple}()
    for ((system, signal_type), handlers) in bus.subscriptions
        for (handler_func, receptors) in handlers
            # Находим descriptor для этой подписки
            desc_idx = findfirst(d -> d.system == system && d.signal_type == signal_type, bus.descriptors)
            config_str = desc_idx !== nothing ? string(bus.descriptors[desc_idx].config) : ""
            push!(subscriptions_data, (
                system = system,
                signal_type = signal_type,
                receptors = receptors,
                config = config_str
            ))
        end
    end
    
    return (
        subscriptions = subscriptions_data,
        pending_events = bus.pending_signals,
        inboxes = bus.inboxes,
        descriptors = bus.descriptors,
        stats = bus.stats
    )
end

"""
    load_state!(bus::EventBus, data::NamedTuple) -> Nothing

Восстанавливает состояние шины из сохранённых данных.
Обработчики событий не восстанавливаются — требуется повторная подписка систем.
"""
function load_state!(bus::EventBus, data::NamedTuple)::Nothing
    # Очищаем текущее состояние
    empty!(bus.subscriptions)
    empty!(bus.pending_signals)
    empty!(bus.inboxes)
    empty!(bus.descriptors)
    
    # Восстанавливаем дескрипторы
    bus.descriptors = data.descriptors
    
    # Восстанавливаем статистику
    bus.stats = data.stats
    
    # Восстанавливаем ожидающие события
    bus.pending_signals = data.pending_events
    
    # Восстанавливаем inbox'и
    bus.inboxes = data.inboxes
    
    # Восстанавливаем метаданные подписок (без функций-обработчиков)
    for sub_data in data.subscriptions
        key = (sub_data.system, sub_data.signal_type)
        if !haskey(bus.subscriptions, key)
            bus.subscriptions[key] = Vector{Tuple{Function, Vector{Symbol}}}()
        end
        # Пустой placeholder для handler — система должна переподписаться
        push!(bus.subscriptions[key], ((s)->nothing, sub_data.receptors))
    end
    
    @info "Состояние шины загружено" subscriptions = length(data.subscriptions) pending = length(data.pending_events)
    return nothing
end

end # module EventBus