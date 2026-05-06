// Verilator C++ wrapper for testbench
// Auto-generated minimal main for SystemVerilog testbench

#include "verilated.h"

// VCD tracing headers only needed when compiled with --trace
#ifdef VM_TRACE
#include "verilated_vcd_c.h"
#endif
#include <cstdio>

// Forward declaration: top module class name is passed via -DVM_PREFIX
#ifndef VM_PREFIX
#error "VM_PREFIX must be defined (e.g., -DVM_PREFIX=Vtb_pe_cell)"
#endif

// String pasting to include correct header
#define STR(x) #x
#define XSTR(x) STR(x)
#define HEADER(x) XSTR(x.h)
#include HEADER(VM_PREFIX)

int main(int argc, char** argv) {
    setbuf(stdout, NULL);  // Force unbuffered output
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);

    VM_PREFIX* top = new VM_PREFIX{contextp};

    // If compiled with --trace, always enable traceEverOn before time 0
    // to avoid "traceEverOn(true) call before time 0" abort.
    #ifdef VM_TRACE
    contextp->traceEverOn(true);
    #endif

    // Only dump VCD if --trace flag is passed at runtime
    #ifdef VM_TRACE
    VerilatedVcdC* tfp = nullptr;
    #endif
    bool trace_en = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0) trace_en = true;
    }
    #ifdef VM_TRACE
    if (trace_en) {
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("waveform.vcd");
    }
    #endif

    // Run until $finish (testbench has its own clock generator)
    while (!contextp->gotFinish()) {
        contextp->timeInc(1);
        top->eval();
        #ifdef VM_TRACE
        if (trace_en && tfp) tfp->dump(contextp->time());
        #endif
    }

    #ifdef VM_TRACE
    if (tfp) {
        tfp->close();
        delete tfp;
    }
    #endif
    delete top;
    delete contextp;
    return 0;
}
