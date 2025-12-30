-- FFI test: calling C functions from Lean

-- Declare external C functions
@[extern "c_add_numbers"]
opaque cAddNumbers : UInt64 → UInt64 → UInt64

@[extern "c_factorial"]
opaque cFactorial : UInt64 → UInt64

def main : IO Unit := do
  -- Test c_add_numbers
  let sum := cAddNumbers 42 58
  IO.println s!"C add: 42 + 58 = {sum}"

  -- Test c_factorial
  let fact5 := cFactorial 5
  IO.println s!"C factorial(5) = {fact5}"

  let fact10 := cFactorial 10
  IO.println s!"C factorial(10) = {fact10}"
