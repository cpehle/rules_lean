-- Main module that uses the Lib module
import Lib

def main : IO Unit := do
  IO.println (MyLib.greet "World")
  IO.println s!"Double of 21 is {MyLib.double 21}"
