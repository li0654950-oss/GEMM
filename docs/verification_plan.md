# GEMM Accelerator Verification Plan

**Version**: v0.1
**Date**: 2026-05-02
**Project**: FP16 Systolic Array GEMM (D = A×B + C)
**Target**: Verilator (unit/integration), VCS/UVM (system)

---

## 1. Verification Strategy

### 1.1 Verification Pyramid

```
┌─────────────────────────────────────────┐
│  System-Level (gemm_top)               │
│  ── FPGA prototype / Palladium / UVM   │
│  ── End-to-end with AXI VIP            │
├─────────────────────────────────────────┤
│  Integration-Level (subsystems)        │
│  ── DMA+Buffer+Scheduler               │
│  ── Systolic Core + Adapter            │
│  ── CSR + IRQ + Control                │
├─────────────────────────────────────────┤
│  Unit-Level (single module)            │
│  ── pe_cell, systolic_core, acc_ctrl   │
│  ── array_io_adapter, buffer_bank      │
│  ── axi_master, addr_gen, loader       │
└─────────────────────────────────────────┘
```

**Rule**: A module may NOT advance to integration until its unit-level
regression passes 100%.

### 1.2 Tool Chain

| Stage | Simulator | Method | CI Target |
|-------|-----------|--------|-----------|
| Unit | Verilator 5.x | SV testbench + self-checking | `make regress` |
| Integration | Verilator 5.x / VCS | SV TB + reference model (Python) | `make regress_integ` |
| System | VCS + UVM | UVM env + AXI VIP + Python ref | nightly regression |

### 1.3 Reference Model

A Python golden model (`tools/gemm_ref.py`) computes FP32 `D = A×B + C`
using NumPy, then casts back to FP16. The RTL result is compared against
the reference with a configurable **ULP threshold** (default: 1 ULP for
normal numbers, 4 ULP for subnormals).

```python
# tools/gemm_ref.py (template)
import numpy as np

def gemm_ref(A, B, C):
    A_f = A.astype(np.float32)
    B_f = B.astype(np.float32)
    C_f = C.astype(np.float32)
    D_f = A_f @ B_f + C_f
    return D_f.astype(np.float16)
```

---

## 2. Unit-Level Verification

### 2.1 Module Test Matrix

| Module | TB File | Key Checks | Status |
|--------|---------|------------|--------|
| `pe_cell` | `tb/tb_pe_cell.sv` | FP16 MAC, acc clear/hold, valid chain, sat flag | ✅ PASS |
| `systolic_core` | `tb/tb_systolic_core.sv` | 2×2 tile compute, mask, reset recovery, mode | ✅ PASS |
| `array_io_adapter` | (covered in systolic_core TB) | Skew alignment, valid delay | ✅ PASS |
| `acc_ctrl` | (covered in systolic_core TB) | Accumulator latch, clear/hold broadcast | ✅ PASS |
| `buffer_bank` | `tb/tb_buffer_bank.sv` | Read/write, bank conflict, ping-pong | 🔲 TODO |
| `a_loader` / `b_loader` | `tb/tb_loader.sv` | Stride read, burst assembly | 🔲 TODO |
| `rd_addr_gen` / `wr_addr_gen` | `tb/tb_addr_gen.sv` | Address sequence, boundary clip | 🔲 TODO |
| `axi_rd_master` / `axi_wr_master` | `tb/tb_axi_master.sv` | AXI4 protocol compliance, backpressure | 🔲 TODO |
| `csr_if` | `tb/tb_csr_if.sv` | Register R/W, W1P, W1C, err code | 🔲 TODO |
| `tile_scheduler` | `tb/tb_scheduler.sv` | FSM, tile loop, mask gen, ping-pong switch | 🔲 TODO |
| `postproc` | `tb/tb_postproc.sv` | FP32→FP16 cast, rounding, saturation | 🔲 TODO |

### 2.2 Test Categories (applicable to each unit)

#### A. Functional
- **Smoke**: One typical pass per feature
- **Directed**: Edge dimensions, boundary tiles, all-zeros/ones
- **Random**: Random FP16 values, random dimensions within parameter range

#### B. Protocol / Interface
- **Backpressure**: `ready` de-asserted mid-transfer
- **Invalid beats**: `valid` toggled, partial data
- **Reset recovery**: Assert reset during active operation, resume

#### C. Numerical
- **Normal range**: Values around 1.0, -1.0, powers of two
- **Subnormal**: Smallest positive/negative FP16
- **Specials**: Inf, NaN, ±0 (NaN handling: propagate or flush to zero)
- **Saturation**: MAC result exceeding FP32 representable range

#### D. Stress
- **Continuous**: Run 100+ tiles back-to-back
- **Max dimension**: K = K_MAX (4096), M/N = max supported tile size
- **Switching**: Rapid mode/mask changes between tiles

---

## 3. Integration-Level Verification

### 3.1 Subsystem Definition

| Subsystem | Modules | Testbench | Checks |
|-----------|---------|-----------|--------|
| **Compute Core** | `array_io_adapter` → `systolic_core` → `acc_ctrl` | `tb/tb_compute_subsys.sv` | Tile compute, fill/drain, wavefront propagation |
| **Read DMA** | `rd_addr_gen` → `axi_rd_master` → `dma_rd` | `tb/tb_dma_rd_subsys.sv` | Burst read, stride, boundary split |
| **Write DMA** | `wr_addr_gen` → `axi_wr_master` → `dma_wr` | `tb/tb_dma_wr_subsys.sv` | Burst write, resp check |
| **Buffer + Loader** | `buffer_bank` + `a_loader` + `b_loader` | `tb/tb_buffer_loader.sv` | Data flow from DMA to core, bank arbitration |
| **Control** | `csr_if` + `tile_scheduler` + `irq_ctrl` | `tb/tb_control_subsys.sv` | Register config, tile loop, interrupt timing |

### 3.2 Integration Test Scenarios

1. **Single tile end-to-end**: CPU writes CSR → scheduler starts → DMA reads A/B → core computes → postproc + C → DMA writes D → IRQ asserted
2. **Multi-tile pipeline**: Two tiles with ping-pong buffer switching, verify no stall bubble
3. **Boundary tile**: M or N not divisible by P_M/P_N, verify mask disables out-of-bound PEs
4. **Error injection**: AXI slave returns SLVERR, verify `err` bit and IRQ
5. **Performance**: Measure cycles per tile, compare against theoretical bound

---

## 4. System-Level Verification

### 4.1 Scope

- Full `gemm_top` with AXI4-Lite CSR and AXI4 data paths
- Connected to AXI VIP (or a simple AXI memory model in Verilator)
- Compared against Python reference model

### 4.2 System Test Matrix

| Dimension (M×N×K) | Data Pattern | Stride | Note |
|---------------------|--------------|--------|------|
| 2×2×2 | All 1.0 | 1 | Smoke |
| 8×8×8 | Random | 1 | Small square |
| 16×16×256 | Random | 1 | Typical tile |
| 65×65×65 | Random | 1 | Boundary (not divisible by 2) |
| 1024×1024×1024 | Random | 1 | Large stress |
| 1024×1024×1024 | Identity + 1.0 | 1 | Known result |
| 8×8×8 | Random | 65 | Non-unit stride |
| 1×1×1 | 1.0 | 1 | Minimum dimension |
| 2048+1×2048+1×2 | All 1.0 | 1 | Extreme boundary |

### 4.3 Sign-Off Criteria

| Metric | Target | Method |
|--------|--------|--------|
| Functional pass rate | 100% | `make regress` |
| Line coverage | >95% | Verilator/VCS coverage |
| FSM state coverage | 100% | All states visited |
| FSM transition coverage | 100% | All arcs visited |
| Cross coverage | (M,N,K) × (data pattern) × (mode) | At least 5 samples per bin |
| Protocol assertion pass | 100% | AXI4 SVA |
| ULP mismatch rate | 0% | Reference model compare |

---

## 5. Regression Infrastructure

### 5.1 Makefile Targets

```makefile
# Unit tests
make regress_unit:
	for m in pe_cell systolic_core buffer_bank ...; do \
	  $(MAKE) SIM=verilator TARGET=$$m run || exit 1; \
	done

# Integration tests
make regress_integ:
	for t in compute_subsys dma_rd_subsys ...; do \
	  $(MAKE) SIM=verilator TARGET=$$t run || exit 1; \
	done

# Full regression
make regress: regress_unit regress_integ
	@echo "All tests passed. See build/regress_report.txt"
```

### 5.2 CI Integration

- **Pre-merge**: `make regress_unit` must pass (fast, < 5 min)
- **Nightly**: `make regress` including integration + random seeds
- **Weekly**: System-level with AXI VIP on VCS (if available)

### 5.3 Report Format

```text
Regression Report — 2026-05-02
==============================
Unit:      12/12 passed
Integration: 5/5 passed
System:    8/8 passed
Coverage:  line=96.2%, fsm=100%, cross=87%
ULP errors: 0
Duration:  4m 32s
Status:    PASS
```

---

## 6. Milestone Plan

| Phase | Deliverable | ETA | Owner |
|-------|-------------|-----|-------|
| M1 | Unit TB for pe_cell, systolic_core, adapter, acc_ctrl | ✅ Done | RTL dev |
| M1 | Unit TB for buffer_bank, loader, addr_gen | Week 1 | Verification |
| M1 | Unit TB for axi_master, csr_if, scheduler, postproc | Week 2 | Verification |
| M2 | Integration TB: compute_subsys, DMA subsys | Week 3 | Verification |
| M2 | Python reference model + scoreboard | Week 3 | Verification |
| M3 | System TB: gemm_top + AXI memory model | Week 4 | Verification |
| M3 | Random test generator + coverage closure | Week 5 | Verification |
| M4 | Regression script + CI hook + sign-off checklist | Week 6 | Lead |

---

## 7. Appendices

### A. File Structure

```
gemm-repo/
├── rtl/              # RTL source
├── tb/               # Testbenches (unit)
├── tb_integ/         # Integration testbenches
├── tb_system/        # System testbenches
├── tools/
│   └── gemm_ref.py   # Python golden model
├── docs/
│   └── verification_plan.md  # This file
└── Makefile          # Regression targets
```

### B. Terminology

| Term | Definition |
|------|------------|
| ULP | Unit in the Last Place; 1 ULP = difference of 1 in mantissa LSB |
| Smoke | Minimal test to prove the module does not catch fire |
| Directed | Hand-crafted test for a specific scenario |
| Random | Auto-generated stimulus with constrained randomization |
| FSM coverage | State + transition visited by test vectors |
| Cross coverage | Cartesian product of multiple dimensions sampled |

---

*Document owner: Verification Lead*
*Approval: RTL Lead, System Architect*
