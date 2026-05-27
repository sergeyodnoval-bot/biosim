module SignalTypes

using UUIDs

abstract type AbstractSignal end

export AbstractSignal, NeuralSignal, HormoneSignal, MetabolicSignal

mutable struct NeuralSignal <: AbstractSignal
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
                          ttl::Float64=10.0)
        new(uuid4(), timestamp, source, target, receptors, data, ttl)
    end
end

mutable struct HormoneSignal <: AbstractSignal
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
                           ttl::Float64=300.0)
        new(uuid4(), timestamp, source, target, receptors, data, ttl)
    end
end

mutable struct MetabolicSignal <: AbstractSignal
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