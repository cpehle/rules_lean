-- Simple Lean4 example to test Bazel toolchain

def hello : String := "Hello from Lean4!"

def main : IO Unit := do
  IO.println hello
