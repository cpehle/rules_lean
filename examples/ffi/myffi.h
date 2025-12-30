// Simple C FFI example for Lean4
#ifndef MYFFI_H
#define MYFFI_H

#include <stdint.h>

// A simple C function to call from Lean
uint64_t c_add_numbers(uint64_t a, uint64_t b);

// A more complex example - compute factorial
uint64_t c_factorial(uint64_t n);

#endif // MYFFI_H
