# SimulationClock Test Runner

# Запуск тестов EventBus
include("bus_tests.jl")
using .EventBusTests

println("\n" * "="^60)
println("Запуск тестов EventBus...")
println("="^60)

run_all_tests()

println("\n" * "="^60)
println("Все тесты SimulationClock и EventBus завершены!")
println("="^60)