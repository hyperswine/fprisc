-- The existing effect-order relaxation admits Int overflow, but not division.
-- Both checked fusion and the remaining compatibility pass share this policy.
module Core.FusionPolicy (safePrimitives,trapFreePrimitives,safePrimitiveArity) where
import Core.Primitives
import Data.List (isSuffixOf)

bitwisePrimitives :: [String]
bitwisePrimitives = ["band","bor","bxor"]

safePrimitives :: [String]
safePrimitives = [op | op<-uPrims,op/="/"]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]
  ++bitwisePrimitives

-- What cannot trap at all: comparisons, Boolean operators, bitwise ops, and
-- float arithmetic other than division. band/bor/bxor are total on exact Int
-- (including T_BIGINT): they may allocate a bignum result but never trap on a
-- well-typed Int. FusionSafety is an effect-order judgement, not a no-heap
-- one, so allocation does not make them unsafe to fuse. Int +, - and * trap on overflow.
trapFreePrimitives :: [String]
trapFreePrimitives = ["==","!=","<",">","<=",">="]
  ++[op | width<-[Float64,Float32],op<-fPrimsOf width,not ("/" `isSuffixOf` op)]
  ++["and","or","not","and2","or2"]
  ++bitwisePrimitives

-- Arity of a fusion-safe primitive, including total HAL bitwise ops that are
-- not core primArities entries.
safePrimitiveArity :: String -> Maybe Int
safePrimitiveArity name
  | name `elem` bitwisePrimitives = Just 2
  | otherwise = lookup name primArities
