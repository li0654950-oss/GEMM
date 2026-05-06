#!/usr/bin/env bash
# GEMM Regression Script
# Usage: ./regress.sh [unit|integration|system|all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB_DIR="${SCRIPT_DIR}/tb"
REPORT_DIR="${SCRIPT_DIR}/build/reports"
REPORT_FILE="${REPORT_DIR}/regress_report_$(date +%Y%m%d_%H%M%S).txt"

# Test targets
UNIT_TARGETS=(
    pe_cell
    systolic_core
    buffer_bank
    a_loader
    b_loader
    d_storer
    postproc
    csr_if
    tile_scheduler
    rd_addr_gen
    err_checker
)

INTEGRATION_TARGETS=()
SYSTEM_TARGETS=(gemm_top)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "${REPORT_DIR}"

PASS=0
FAIL=0
TOTAL=0

run_target() {
    local target=$1
    local stage=$2
    TOTAL=$((TOTAL + 1))
    
    echo "[REGRESS] Running ${stage}: ${target} ..."
    if cd "${TB_DIR}" && make SIM=verilator TARGET="${target}" run > "${REPORT_DIR}/${target}.log" 2>&1; then
        echo -e "${GREEN}[PASS]${NC} ${target}"
        PASS=$((PASS + 1))
        echo "PASS: ${target}" >> "${REPORT_FILE}"
    else
        echo -e "${RED}[FAIL]${NC} ${target} (see ${REPORT_DIR}/${target}.log)"
        FAIL=$((FAIL + 1))
        echo "FAIL: ${target}" >> "${REPORT_FILE}"
    fi
}

STAGE=${1:-unit}

echo "========================================"
echo "GEMM Regression — $(date)"
echo "Stage: ${STAGE}"
echo "Simulator: Verilator"
echo "========================================"
echo ""

case "${STAGE}" in
    unit)
        for t in "${UNIT_TARGETS[@]}"; do
            run_target "${t}" "unit"
        done
        ;;
    integration)
        if [ ${#INTEGRATION_TARGETS[@]} -eq 0 ]; then
            echo -e "${YELLOW}[SKIP]${NC} No integration targets defined yet"
        else
            for t in "${INTEGRATION_TARGETS[@]}"; do
                run_target "${t}" "integration"
            done
        fi
        ;;
    system)
        for t in "${SYSTEM_TARGETS[@]}"; do
            run_target "${t}" "system"
        done
        ;;
    all)
        for t in "${UNIT_TARGETS[@]}"; do
            run_target "${t}" "unit"
        done
        for t in "${INTEGRATION_TARGETS[@]}"; do
            run_target "${t}" "integration"
        done
        for t in "${SYSTEM_TARGETS[@]}"; do
            run_target "${t}" "system"
        done
        ;;
    *)
        echo "Usage: $0 [unit|integration|system|all]"
        exit 1
        ;;
esac

echo ""
echo "========================================"
echo "Regression Complete"
echo "========================================"
echo "Total:  ${TOTAL}"
echo -e "Pass:   ${GREEN}${PASS}${NC}"
echo -e "Fail:   ${RED}${FAIL}${NC}"
echo "Report: ${REPORT_FILE}"
echo "========================================"

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
