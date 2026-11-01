-- The existing effect-order relaxation admits Int overflow, but not division.
-- Both checked fusion and the remaining compatibility pass share this policy.
module Core.FusionPolicy (safePrimitives,trapFreePrimitives) where
import Core.Primitives
import Data.List (isSuffixOf)

safePrimitives :: [String]
safePrimitives = [op | op<-uPrims,op/="/"]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]

-- What cannot trap at all: comparisons, Boolean operators and float
-- arithmetic other than division. Int +, - and * trap on overflow.
trapFreePrimitives :: [String]
trapFreePrimitives = ["==","!=","<",">","<=",">="]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]
