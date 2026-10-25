-- Identity of the actual lowered input to native optimization. Unit source
-- hashes alone cannot distinguish operator/layout/region decisions inherited
-- from a checked import context. Keep reachable elided constructor stubs (the
-- inliner can read them), and external call arities used by this program.
-- Unrelated root declarations must not invalidate unchanged unit code.
module Core.CacheIdentity (CallArities(..),coreCacheIdentity) where
import Core.Syntax (Prog,Name,freeVars)
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Bits (xor)
import Data.Word (Word64)
import Numeric (showHex)

data CallArities = CallArities
  { globalCalls :: M.Map Name Int, primitiveCalls :: M.Map Name Int }

coreCacheIdentity :: S.Set Name -> CallArities -> Prog -> String
coreCacheIdentity elided (CallArities globals primitives) program = "core1-"++replicate (16-length hex) '0'++hex
  where
    references p=S.unions [S.fromList (freeVars body) S.\\ S.fromList ps | (ps,body)<-M.elems p]
    needed p=let extra=M.restrictKeys program (references p S.\\ M.keysSet p)
             in if M.null extra then p else needed (M.union p extra)
    relevant=needed (M.withoutKeys program elided)
    external=references relevant S.\\ M.keysSet relevant
    bytes=encode (relevant,M.restrictKeys globals external,M.restrictKeys primitives external)
    hash=BL.foldl' (\h byte->(h `xor` fromIntegral byte)*1099511628211) 14695981039346656037 bytes :: Word64
    hex=showHex hash ""
