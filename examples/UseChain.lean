-- Use the chain of libraries
import ChainC

def main : IO Unit := do
  -- ChainC.valueC should be 100 + 50 + 25 = 175
  IO.println s!"ChainC value: {ChainC.valueC}"
