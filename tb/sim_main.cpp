// Verilator C++ wrapper for testbench
// Auto-generated minimal main for SystemVerilog testbench

#include "verilated.h"
#include "verilated_vcd_c.h"

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
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);

    VM_PREFIX* top = new VM_PREFIX{contextp};

    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("waveform.vcd");

    // Run until $finish (testbench has its own clock generator)
    while (!contextp->gotFinish()) {
        contextp->timeInc(1);
        top->eval();
        tfp->dump(contextp->time());
    }

    tfp->close();
    delete tfp;
    delete top;
    delete contextp;
    return 0;
}
