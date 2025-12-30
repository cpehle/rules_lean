-- Chain C: Depends on B (and transitively A)
import ChainB

namespace ChainC

def valueC : Nat := ChainB.valueB + 25

end ChainC
