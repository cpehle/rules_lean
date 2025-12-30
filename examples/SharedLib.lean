-- Example Lean code for shared library
-- This will be compiled into libmysharedlib.dylib/.so

def greet (name : String) : String :=
  s!"Hello, {name}! From Lean shared library."

def factorial (n : Nat) : Nat :=
  if n <= 1 then 1 else n * factorial (n - 1)

-- Export for FFI
@[export lean_factorial]
def leanFactorial (n : UInt64) : UInt64 :=
  (factorial n.toNat).toUInt64
