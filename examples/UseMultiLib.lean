-- Main that uses the multi-file library
import MultiLib

def main : IO Unit := do
  IO.println s!"Base value: {baseValue}"
  IO.println s!"Extended value: {extendedValue}"
  IO.println s!"addBase 10 = {addBase 10}"
  IO.println s!"multiplyBase 3 = {multiplyBase 3}"
