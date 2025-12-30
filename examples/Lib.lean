-- Library module for multi-file test

namespace MyLib

def greet (name : String) : String :=
  s!"Hello, {name}!"

def double (n : Nat) : Nat := n * 2

end MyLib
