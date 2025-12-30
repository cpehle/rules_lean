-- Chain B: Depends on A
import ChainA

namespace ChainB

def valueB : Nat := ChainA.valueA + 50

end ChainB
