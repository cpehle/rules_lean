-- Example Lean code for static library
-- This will be compiled into libmystaticlib.a

def addOne (n : Nat) : Nat := n + 1

def multiplyByTwo (n : Nat) : Nat := n * 2

def computeValue (n : Nat) : Nat :=
  multiplyByTwo (addOne n)

-- Export for FFI
@[export lean_compute_value]
def leanComputeValue (n : UInt64) : UInt64 :=
  (computeValue n.toNat).toUInt64
