-- The existing effect-order relaxation admits Int overflow, but not division.
-- Both checked fusion and the remaining compatibility pass share this policy.
module Core.FusionPolicy (safePrimitives) where
import Core.Primitives
import Data.List (isSuffixOf)

safePrimitives :: [String]
safePrimitives = [op | op<-uPrims,op/="/"]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]
