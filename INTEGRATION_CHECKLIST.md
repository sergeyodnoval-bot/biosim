# Integration Checklist — SimulationKernel.jl (Phase 0.6 → Phase 1)

## ✅ Deliverables Verification

| # | Artifact | Status | Location |
|---|----------|--------|----------|
| 1 | `src/SimulationKernel.jl` | ✅ Created | Main kernel logic, checkpointing, lifecycle |
| 2 | `src/ISystem.jl` | ✅ Created | Interface definition, validation helpers |
| 3 | `test/kernel_tests.jl` | ✅ Created | Lifecycle, aggregation, checkpoint, divergence, perf tests |
| 4 | `examples/demo_kernel.jl` | ✅ Created | CLI demo with 3 mock systems, 30-day simulation |
| 5 | `KERNEL_API.md` | ✅ Created | API documentation, lifecycle diagrams, contracts |
| 6 | This checklist | ✅ Created | Integration guide |

---

## 🔧 How to Connect Real Systems

### Step 1: Define Your System

```julia
using .SimulationKernel
using .ISystem

mutable struct MyRealSystem <: AbstractSystem
    # Your fields here (must be serializable!)
    param1::Float64
    state_vector::Vector{Float64}
    initialized::Bool
    
    function MyRealSystem(param1::Float64, initial_state::Vector{Float64})
        new(param1, initial_state, false)
    end
end
```

### Step 2: Implement ISystem Interface

```julia
# 2.1 Initialization
function init!(sys::MyRealSystem, clock, bus)::Nothing
    # Subscribe to events if needed
    subscribe!(bus, :my_system, NeuralSignal, sys -> begin
        # Handle signal
    end; receptors=[:receptor1])
    
    sys.initialized = true
    @info "MyRealSystem initialized" param1=sys.param1
    return nothing
end

# 2.2 Step execution
function step!(sys::MyRealSystem, dt::Float64, t::Float64)::Nothing
    # Update your state
    # IMPORTANT: No allocations in hot path!
    for i in eachindex(sys.state_vector)
        sys.state_vector[i] += sys.param1 * dt
    end
    return nothing
end

# 2.3 Derivative estimation (for adaptive dt)
function max_derivative(sys::MyRealSystem, t::Float64)::Float64
    # Return maximum expected rate of change
    # This affects clock's adaptive step size
    return abs(sys.param1) * length(sys.state_vector)
end

# 2.4 Shutdown
function shutdown!(sys::MyRealSystem)::Nothing
    # Clean up resources
    sys.initialized = false
    return nothing
end

# 2.5 Save state (MUST be JLD2-compatible!)
function save_state(sys::MyRealSystem)::NamedTuple
    return (
        param1 = sys.param1,
        state_vector = copy(sys.state_vector),
        # NO functions, closures, or file handles!
    )
end

# 2.6 Load state
function load_state!(sys::MyRealSystem, data::NamedTuple)::Nothing
    sys.param1 = data.param1
    sys.state_vector = copy(data.state_vector)
    return nothing
end
```

### Step 3: Register and Run

```julia
# Create your system
my_sys = MyRealSystem(1.5, zeros(100))

# Create kernel
config = KernelConfig(
    checkpoint_interval = 1.0,      # Checkpoint every 1 day
    max_steps_between_cp = 5000,    # Force checkpoint after 5000 steps
    divergence_threshold = 1e10     # NaN/Inf detection threshold
)

kernel = SimulationKernel(0.0, 365.0, 0.1; config=config)

# Add systems (can add multiple)
add_system!(kernel, my_sys)

# Run simulation
result = run!(kernel, 0.0, 365.0)

println("Completed: $(result.total_steps) steps in $(result.elapsed_wall_time)s")
```

---

## 🧪 Pre-Commit Verification

### 1. Type Stability Check

```julia
using .SimulationKernel

kernel = SimulationKernel(0.0, 10.0, 0.1)
sys = MyRealSystem(1.0, zeros(10))
add_system!(kernel, sys)

@code_warntype step!(kernel)
# Should show NO `Any` types in the output
# Look for red-highlighted types in the output
```

**Expected:** All types should be concrete (`Float64`, `Int`, `StepStatus`, etc.)

---

### 2. JLD2 Roundtrip Test

```julia
using .SimulationKernel
using Test

kernel = SimulationKernel(0.0, 30.0, 0.1)
sys = MyRealSystem(1.0, [1.0, 2.0, 3.0])
add_system!(kernel, sys)

# Run a few steps
for i in 1:10
    step!(kernel)
end

# Save original state
original_time = kernel.clock.current_time
original_state = copy(sys.state_vector)

# Save checkpoint
path = save_checkpoint!(kernel, "test_rt")
@test isfile(path)

# Modify state
sys.state_vector .= 999.0
@test sys.state_vector[1] == 999.0

# Create new kernel and load
kernel2 = SimulationKernel(0.0, 30.0, 0.1)
sys2 = MyRealSystem(1.0, zeros(3))
add_system!(kernel2, sys2)
load_checkpoint!(kernel2, path)

# Verify restoration
@test kernel2.clock.current_time ≈ original_time
@test sys2.state_vector ≈ original_state

# Cleanup
rm(path)
```

**Expected:** State restored within ±1e-12 tolerance

---

### 3. NaN Isolation Test

```julia
using .SimulationKernel
using Test

mutable struct BadSystem <: AbstractSystem
    bad_time::Float64
end

function init!(sys::BadSystem, clock, bus) end
function step!(sys::BadSystem, dt, t) 
    if t > sys.bad_time
        # Introduce NaN
        sys_val = NaN
    end
end
function max_derivative(sys::BadSystem, t)::Float64
    if t > sys.bad_time
        return NaN
    end
    return 1.0
end
function shutdown!(sys::BadSystem) end
function save_state(sys::BadSystem) (t=0.0,) end
function load_state!(sys::BadSystem, d) end

bad_sys = BadSystem(5.0)
kernel = SimulationKernel(0.0, 30.0, 0.1)
add_system!(kernel, bad_sys)

result = run!(kernel, 0.0, 30.0)

@test result.status == STEP_DIVERGENCE
@test result.divergence_t > 5.0

# Verify emergency checkpoint was created
cp_files = filter(f -> occursin("emergency", f), readdir("checkpoints"))
@test length(cp_files) >= 1
```

**Expected:** Simulation stops at divergence, emergency checkpoint created

---

### 4. Performance Benchmark

```julia
using .SimulationKernel
using BenchmarkTools

# Create 3 mock systems
sys1 = MockSystem(0.0, 1.0)
sys2 = MockSystem(0.0, 2.0)
sys3 = MockSystem(0.0, 3.0)

config = KernelConfig(checkpoint_interval=1000.0)  # Disable checkpoints
kernel = SimulationKernel(0.0, 10000.0, 0.1; config=config)
add_system!(kernel, sys1)
add_system!(kernel, sys2)
add_system!(kernel, sys3)

GC.gc()
start = time()

steps = 0
while steps < 10_000
    status = step!(kernel)
    steps += 1
    status == STEP_ENDED && break
end

elapsed = time() - start
println("10^4 steps: $(round(elapsed, digits=3))s")
@test elapsed <= 3.0
```

**Expected:** ≤ 3 seconds for 10⁴ steps with 3 systems

---

## 📋 What to Check Before Phase 1

### Functional Requirements

- [ ] **Lifecycle order**: `init! → step! (N×) → save_state → load_state! → step! → shutdown!`
- [ ] **Aggregation**: `max_derivative(t)` returns maximum across all systems
- [ ] **Empty kernel**: Works correctly with 0 systems (returns 0.0 derivative)
- [ ] **Event integration**: Systems can publish/subscribe via `bus`
- [ ] **Clock adaptation**: `dt` changes based on aggregated derivative
- [ ] **Checkpoint trigger**: Saves every `checkpoint_interval` days OR `max_steps_between_cp` steps
- [ ] **Atomic write**: Temp file → rename pattern prevents corruption
- [ ] **Divergence handling**: NaN/Inf → `STEP_DIVERGENCE` → emergency checkpoint → shutdown

### Non-Functional Requirements

- [ ] **Type stability**: `@code_warntype step!` shows no `Any`
- [ ] **Memory**: ≤ 80 MB RAM during 10⁴ steps
- [ ] **CPU**: Single-core bound (no parallelism required)
- [ ] **No globals**: All mutations through explicit state
- [ ] **No print()**: Use `@info`, `@warn`, `@error` only
- [ ] **Determinism**: Same input → same output (except RNG-dependent systems)

### Code Quality

- [ ] **Docstrings**: All public methods have Julia-style docstrings
- [ ] **Constants**: Magic numbers extracted to `const` in `KernelConfig`
- [ ] **Error handling**: Try-catch around system calls, graceful degradation
- [ ] **Logging**: Informative messages at key lifecycle points

---

## 🚀 Running the Demo

```bash
cd /workspace
julia --project examples/demo_kernel.jl
```

**Expected output:**
- 3 mock systems running for 30 simulated days
- Multiple checkpoints created in `checkpoints/` directory
- Final statistics printed
- Exit code 0

---

## 📁 File Structure After Implementation

```
/workspace/
├── src/
│   ├── SimulationKernel.jl    # Main kernel (NEW)
│   ├── ISystem.jl             # Interface definition (NEW)
│   ├── SimulationClock.jl     # Existing clock module
│   ├── EventBus.jl            # Existing event bus
│   └── SignalTypes.jl         # Existing signal types
├── test/
│   ├── kernel_tests.jl        # Kernel tests (NEW)
│   ├── clock_tests.jl         # Existing clock tests
│   └── bus_tests.jl           # Existing bus tests
├── examples/
│   ├── demo_kernel.jl         # Demo script (NEW)
│   ├── demo_clock.jl          # Existing clock demo
│   └── demo_bus.jl            # Existing bus demo
├── KERNEL_API.md              # API documentation (NEW)
├── INTEGRATION_CHECKLIST.md   # This file (NEW)
└── checkpoints/               # Auto-created during runs
```

---

## 🔗 Next Steps (Phase 1 Preparation)

1. **Replace mock systems** with real physiological models
2. **Add more event types** beyond Neural/Hormone/Metabolic signals
3. **Implement distributed checkpoints** (save to S3/network storage)
4. **Add profiling hooks** for performance analysis
5. **Create system templates** for common patterns (ODE-based, discrete-event, etc.)

---

## ⚠️ Known Limitations

- Functions/closures in system state cannot be serialized (design limitation of JLD2)
- Event callbacks are not restored from checkpoints (only metadata)
- No built-in parallelism (single-threaded by design for determinism)
- Checkpoint files are not compressed beyond Zstd (consider chunking for large states)

---

**Status:** ✅ Ready for Phase 1 integration

**Last updated:** 2026-01-XX  
**Author:** SimulationKernel Team
