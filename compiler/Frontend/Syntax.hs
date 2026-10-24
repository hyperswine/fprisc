{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}

-- Surface syntax and stable cache instances, independent of checking/lowering.
module Frontend.Syntax where

import Control.DeepSeq ( NFData )
import Core.Syntax ( Name )
import Data.Binary ( Binary )
import GHC.Generics ( Generic )

data SExpr
  = SVar Name
  | SMark !Int SExpr -- source position wrapper (spans step 3): the Int
                     -- is the SOURCE OFFSET in the defining file,
                     -- attached by the parser at block-statement and
                     -- case-arm granularity.  INVISIBLE to semantics:
                     -- shape-sensitive matchers look through it
                     -- (unmark), stripPosTops erases it before module
                     -- hashing, the desugarer drops it at the Core
                     -- boundary.  Infer stamps the innermost enclosing
                     -- mark into its diagnostics ("@OFF~ "), which the
                     -- error sinks resolve to file:line:col.
  | SInt Integer
  | SAtom Name
  | SStrI [Seg]
  | SApp SExpr SExpr
  | SLam [Name] SExpr
  | SBlock [SStmt] SExpr
  | SCase SExpr [(SPat, SExpr)]
  | SBin Name SExpr SExpr
  | SProj SExpr [Name]
  | SRec [(Name, SExpr)]
  | SUpd SExpr [([Name], SExpr)]
  | STup [SExpr]
  | SList [SExpr]
  deriving (Show, Generic, NFData, Binary)

data Seg = SegStr String | SegExpr SExpr deriving (Show, Generic, NFData, Binary)

data SStmt
  = SBind Name [Name] SExpr
  | SBindPat SPat SExpr
  deriving (Show, Generic, NFData, Binary)

data SPat
  = PVar Name
  | PWild
  | PInt Integer
  | PStr String
  | PCon Name [SPat]
  | PTup [SPat]
  | PRec [Name]
  | PSig Name Name -- (s : Functor) — a param constrained by a named sig
  deriving (Show, Generic, NFData, Binary)

-- one component of a clause guard: `| e1, p <- e2, e3 = body`
data SGuard
  = GBool SExpr -- boolean condition
  | GPat SPat SExpr -- pattern-match binding `pat <- expr`
  deriving (Show, Generic, NFData, Binary)

guardBools :: [SGuard] -> [SExpr]
guardBools gs = [e | GBool e <- gs]

mapGuardE :: (SExpr -> SExpr) -> SGuard -> SGuard
mapGuardE f' (GBool e) = GBool (f' e)
mapGuardE f' (GPat p e) = GPat p (f' e)

data STop
  = TBind Name [SPat] [SGuard] SExpr
  | TType Name Bool [Name] [(Name, [Ty])]
  | TShape Name [(Name, Ty)]
  | TSig Name ([Ty], Ty) [Maybe (Name, SExpr)] -- per-PARAM precondition: (n : Int | n > 0)
  | TSigDef Name [(Name, Maybe Ty)] -- `Functor = Sig { map : ... }.`
  | TStruct Name [Name] [(Name, SExpr)] -- `Numeric = Struct Arith { ... }.`
  | TUse Name String -- MyMod = use "MyMod#hash".  (compile-time module import)
  | TAlias Name Name -- T = MyMod.T.  (name alias: types, constructors, values)
  | TEval SExpr -- `> effect.`  top-level eval (the HostedBytecode/sol view; profile-gated in Main)
  | TSkip
  deriving (Show, Generic, NFData, Binary)

data Ty
  = TCon Name [Ty]
  | TVarT Name
  | TTup [Ty]
  | TArrT Ty Ty
  | TVApp Name [Ty]
  | TRecT [(Name, Ty)] (Maybe Name) -- `{ f : T, g : U }` closed, `{ f : T | r }` open on row var r
  | TOther
  deriving (Show, Generic, NFData, Binary)
