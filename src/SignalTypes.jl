module SignalTypes

using UUIDs
using ..EventBus: AbstractSignal

export NeuralSignal, HormoneSignal, MetabolicSignal

"""
    NeuralSignal <: AbstractSignal

Сигнал нервной системы. Используется для быстрой передачи команд.

# Fields
Наследует все поля `BaseSignal`
"""
struct NeuralSignal <: AbstractSignal
    id::UUID
    timestamp::Float64
    source::Symbol
    target::Symbol
    receptors::Vector{Symbol}
    data::NamedTuple
    ttl::Float64
    
    function NeuralSignal(timestamp::Float64, source::Symbol, target::Symbol; 
                          receptors::Vector{Symbol}=Symbol[], 
                          data::NamedTuple=(;), 
                          ttl::Float64=10.0)  # Короткий TTL для нейросигналов
        new(uuid4(), timestamp, source, target, receptors, data, ttl)
    end
end

"""
    HormoneSignal <: AbstractSignal

Гормональный сигнал. Используется для медленной регуляции процессов.

# Fields
Наследует все поля `BaseSignal`
"""
struct HormoneSignal <: AbstractSignal
    id::UUID
    timestamp::Float64
    source::Symbol
    target::Symbol
    receptors::Vector{Symbol}
    data::NamedTuple
    ttl::Float64
    
    function HormoneSignal(timestamp::Float64, source::Symbol, target::Symbol; 
                           receptors::Vector{Symbol}=Symbol[], 
                           data::NamedTuple=(;), 
                           ttl::Float64=300.0)  # Длинный TTL для гормонов
        new(uuid4(), timestamp, source, target, receptors, data, ttl)
    end
end

"""
    MetabolicSignal <: AbstractSignal

Метаболический сигнал. Используется для передачи информации о состоянии метаболизма.

# Fields
Наследует все поля `BaseSignal`
"""
struct MetabolicSignal <: AbstractSignal
    id::UUID
    timestamp::Float64
    source::Symbol
    target::Symbol
    receptors::Vector{Symbol}
    data::NamedTuple
    ttl::Float64
    
    function MetabolicSignal(timestamp::Float64, source::Symbol, target::Symbol; 
                             receptors::Vector{Symbol}=Symbol[], 
                             data::NamedTuple=(;), 
                             ttl::Float64=100.0)
        new(uuid4(), timestamp, source, target, receptors, data, ttl)
    end
end

end # module SignalTypes
