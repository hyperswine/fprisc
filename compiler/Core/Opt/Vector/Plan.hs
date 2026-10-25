-- Vector admission plans. Operations carry their payloads directly; symbol
-- rendering is confined to the native ABI boundary below.
module Core.Opt.Vector.Plan
  (ElementOp(..), VectorOp(..), SpecPlan(..), PipePlan(..), MvPlan(..), RvvPlan(..),
   elementOpName, operationKey, pipelineOf, wfoldG) where
import Core.Syntax
import Core.Primitives (FloatWidth)
import KernelKinds (Kind)
import Compiler.VectorOperation
import qualified Data.Set as S

data VectorOp = ScalarOp ElementOp | RecordMap | RecordFilter
              | LayoutMap String | WritebackFold Name | FusedPipeline PipePlan
              deriving (Eq)

-- Keep the existing symbol/cache ABI. This serialization is not inspected
-- by optimization or admission: those consumers match constructors.
operationKey :: VectorOp -> String
operationKey (ScalarOp op) = elementOpName op
operationKey RecordMap = "mvmap"
operationKey RecordFilter = "rfilter"
operationKey (LayoutMap layout) = "mapAs@" ++ layout
operationKey (WritebackFold f) = "wfold@" ++ f
operationKey (FusedPipeline p) = "pipeline@PipePlan {pipeStages = "
  ++ show [(elementOpName op,f,caps) | (op,f,caps) <- pipeStages p]
  ++ ", pipeElement = " ++ show (pipeElement p)
  ++ ", pipeAccumulator = " ++ show (pipeAccumulator p) ++ "}"

pipelineOf :: SpecPlan -> Maybe PipePlan
pipelineOf p = case spOp p of FusedPipeline pipe -> Just pipe; _ -> Nothing

wfoldG :: SpecPlan -> Maybe Name
wfoldG p = case spOp p of WritebackFold f -> Just f; _ -> Nothing

data SpecPlan = SpecPlan
  { spOp :: VectorOp,
    spFn :: String, -- the element function (top-level supercombinator)
    spScalar :: Bool, -- scalar-Int loop possible (arith closure exists)
    spClosure :: S.Set String, -- fpr_ufn_ bodies this needs
    spSoa :: Maybe ([Int], [String], Core, (Int, Int)), -- fold only: (used cols, params, dualized body, required eltid/elvar)
    spRvv :: Maybe RvvPlan,
    -- Vec.map (f cap) v where f's body (after inlining) is a
    -- record->record multiply-add over the element's columns and the
    -- captured record's fields (the Mat4*Vec4 shape).  Per output
    -- column one tiny unboxed field fn; the loop runs IN PLACE.
    spMv :: Maybe MvPlan,
    -- Accumulator/result float width. Element and capture kinds are
    -- independent in spKinds; primitive opcodes select their own arithmetic.
    spFloat :: Maybe FloatWidth,
    -- Vec.map (f c1 .. ck) v / Vec.filter (p c1 .. ck) v with k SCALAR
    -- captures: the kernel takes them in a0..a(k-1) ahead of the vector,
    -- Int captures are guarded/untagged once; typed float captures retain
    -- their IEEE bits. Each argument has an independent kind in spKinds.  0 for the capture-free and record-captured plans.
    spCaps :: Int,
    spKinds :: Maybe ([Kind], Kind) -- captures, accumulator/columns, result
  }

-- Stage order is execution order; capture indices refer to entry arguments
-- saved in frame slots. Those arguments retain source evaluation order.
data PipePlan = PipePlan
  { pipeStages :: [(ElementOp,String,[Int])],
    pipeElement :: Kind,
    pipeAccumulator :: Maybe (Int,Kind)
  } deriving (Eq)

data MvPlan = MvPlan
  { mvTid :: (Int, Int), -- required eltid/elvar (spec guard)
    mvN :: Int, -- field/column count (cols 0..n-1, in place)
    mvKinds :: Maybe [([Kind],Kind)],
    mvFields :: [(([Int], [Int]), ([String], Core))] -- per field: ((cap projs, col idxs), (params, dual body))
  }
  deriving (Eq)

data RvvPlan
  = RvvMap String Core -- param name, straight-line body
  | RvvFoldSum -- fold whose fn is \a b -> a + b
  deriving (Eq)


