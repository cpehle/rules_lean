-- Root module that re-exports the MultiLib namespace
import MultiLib.Base
import MultiLib.Extended

-- Re-export everything from MultiLib namespace
export MultiLib (baseValue addBase extendedValue multiplyBase)
