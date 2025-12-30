// Simple C FFI implementation for Lean4
#include "myffi.h"

uint64_t c_add_numbers(uint64_t a, uint64_t b) {
    return a + b;
}

uint64_t c_factorial(uint64_t n) {
    if (n <= 1) return 1;
    uint64_t result = 1;
    for (uint64_t i = 2; i <= n; i++) {
        result *= i;
    }
    return result;
}
