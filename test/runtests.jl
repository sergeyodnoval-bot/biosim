# SimulationClock Test Runner

# Запуск тестов EventBus
push!(LOAD_PATH, joinpath(@__DIR__, "../src"))
include("bus_tests.jl")

println("\n" * "="^60)
println("Запуск тестов EventBus...")
println("="^60)

EventBusTests.run_all_tests()

println("\n" * "="^60)
println("Все тесты SimulationClock и EventBus завершены!")
println("="^60)