// Minimal Verilator C++ wrapper for coverage collection
// No VCD tracing support — use sim_main.cpp for waveform runs

#include "verilated.h"
#include <cstdio>

#ifndef VM_PREFIX
#error "VM_PREFIX must be defined (e.g., -DVM_PREFIX=Vtb_pe_cell)"
#endif

#define STR(x) #x
#define XSTR(x) STR(x)
#define HEADER(x) XSTR(x.h)
#include HEADER(VM_PREFIX)

int main(int argc, char** argv) {
    setbuf(stdout, NULL);
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);

    VM_PREFIX* top = new VM_PREFIX{contextp};

    while (!contextp->gotFinish()) {
        contextp->timeInc(1);
        top->eval();
    }

    // Write coverage data before exit
    contextp->coveragep()->write("coverage.dat");

    delete top;
    delete contextp;
    return 0;
}
