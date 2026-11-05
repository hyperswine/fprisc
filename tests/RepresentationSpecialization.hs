-- C2 admission is about representations and target images, not Core node
-- counts. Exercise the solver directly so earlier inlining cannot hide the
-- large helpers or recursive representation equations being tested.
module Main (main) where

import Control.Monad (unless)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Core.Syntax
import qualified Representation as R
import qualified Arc
import qualified Interrupt
import qualified Arc.Uniform as Uniform
import qualified Compiler.Native.TypeLayout as Layout
import Compiler.DataLayout (Layouts(..))
import Representation.Types
import qualified Core.Typed.Monomorphize as Mono
import qualified Core.Typed.Program as P
import qualified Core.Typed.Syntax as T
import Core.Identity (Namespace(..), BinderId(..))
import qualified Type.Syntax as Ty
import Ownership.TypeShape (linShapeT)

check label ok = unless ok (error label)
right = either error id
refused label needle result = case result of
  Left why -> check (label ++ ": " ++ why) (needle `isInfixOf` why)
  Right _ -> error ("accepted " ++ label)
call n = foldl CApp (CVar n)
word n = call "Word.fromInt" [CInt n]
sequenceOf = foldr (CLet "ignored") (CInt 0)
solve = R.representWithOptions True S.empty M.empty
padding n = foldr (\i -> CLet ("unused" ++ show i) (CInt i)) (CVar "x") [1..n]

main :: IO ()
main = do
  typedInstances
  immortalOwnership
  checkedLayouts
  uniformEntries
  uniformCalls
  scalarStorage
  productValuesCheck
  rawProductsCheck
  let large = M.fromList
        [("identity", (["x"], padding 200)),
         ("main", ([], sequenceOf [call "identity" [CInt 1], call "identity" [word 2]]))]
      (largeProg, _, largeArgs, notes) = right (solve large)
  check "a helper larger than 256 Core nodes specializes"
    (M.size largeProg == 3 && null notes
      && [Managed] `elem` M.elems largeArgs && [RawWord] `elem` M.elems largeArgs)
  let names = ["identity" ++ show i | i <- [1..32]]
      many = M.fromList ([(n, (["x"], padding 80)) | n <- names]
        ++ [("main", ([], sequenceOf [call n [v] | n <- names, v <- [CInt 1, word 2]]))])
      (manyProg, _, _, manyNotes) = right (solve many)
  check "a finite graph exceeding the former 4096 cloned nodes is admitted"
    (M.size manyProg == 65 && null manyNotes)

  let recursive = M.fromList
        [("f", (["x"], call "g" [word 1])),
         ("g", (["y"], call "f" [CVar "y"])),
         ("main", ([], call "f" [CInt 0]))]
      (recursiveProg, _, _, _) = right (solve recursive)
  check "finite representation-changing mutual recursion is admitted"
    (M.size recursiveProg == 4)
  let growing = M.fromList
        [("f", (["x"], call "g" [CMk 9 0 [CVar "x"]])),
         ("g", (["y"], call "f" [CVar "y"])),
         ("main", ([], call "f" [CInt 0]))]
  refused "expanding recursive specialization" "expanding recursive type specialization" (solve growing)
  let accumulating = M.fromList
        [("f", (["xs"], call "f" [CMk 2 1 [CInt 1, CVar "xs"]])),
         ("main", ([], call "f" [CMk 2 0 []]))]
      (accumulatingProg, _, _, _) = right (solve accumulating)
  check "ordinary recursive list accumulation ties a finite layout equation"
    (M.size accumulatingProg == 2)
  let transactional = M.fromList
        [("f", (["unused", "y"], call "f" [word 1, word 2])),
         ("main", ([], call "f" [CErr "unreachable", CInt 0]))]
      (_, _, transactionalArgs, _) = right (solve transactional)
  check "a failed recursive reuse attempt does not constrain the original signature"
    (M.lookup "f" transactionalArgs == Just [Managed, Managed])

  let generic = M.fromList
        [("identity", (["x"], CVar "x")),
         ("main", ([], sequenceOf [call "identity" [CInt 1], call "identity" [word 2]]))]
      pins = S.singleton "identity"
      known = M.singleton "identity" (CallSignature [Just (ScalarRep Managed)] (Just (ScalarRep Managed)))
  refused "unknown external ABI" "pinned boundary identity"
    (R.representWithOptions True pins M.empty generic)
  refused "incompatible external ABI" "incompatible representations"
    (R.representWithOptions True pins known generic)
  let one = M.fromList [("identity", (["x"], CVar "x")), ("main", ([], call "identity" [CInt 1]))]
      (oneProg, _, oneArgs, _) = right (R.representWithOptions True pins known one)
  check "a checked boundary keeps its entry and physical signature"
    (M.keys oneProg == ["identity", "main"] && M.lookup "identity" oneArgs == Just [Managed])

  let unreachable = M.fromList
        [("abort", (["x"], CErr "stop")),
         ("main", ([], sequenceOf [call "abort" [CInt 1], call "abort" [word 2]]))]
      outputs = M.singleton "abort" (CallSignature [Nothing] (Just (ScalarRep RawAddr)))
      (_, annotations, _, _) = right (R.representWithOptions True S.empty outputs unreachable)
      resultKinds = [k | (CApp (CVar n) _, k) <- M.toList annotations, "abort" `isInfixOf` n]
  check "every clone retains concrete checked result evidence"
    (length resultKinds == 2 && all (== RawAddr) resultKinds)
  putStrLn "C2: large finite graphs, finite/growing recursion, checked boundaries and clone results passed"

immortalOwnership = do
  let lower = right . Arc.lowerArc M.empty
      noOwnership p = all (\n -> not (n `isInfixOf` show p)) ["$arc.retain", "$arc.release"]
      unit = CMk 0 0 []
      boolean = CMk 1 1 []
      identities value = M.fromList
        [("identity", (["x"], CVar "x")),
         ("main", ([], CLet "x" (call "identity" [value]) (call "identity" [CVar "x"])))]
  check "Unit parameters, repeated reads and results need no reference counting"
    (noOwnership (lower (identities unit)))
  check "Bool parameters, repeated reads and results need no reference counting"
    (noOwnership (lower (identities boolean)))
  check "effectful Unit results are evaluated without retaining their lifetimes"
    (noOwnership (lower (M.singleton "main" ([], sequenceOf [call "print" [CInt n] | n <- [1..20]]))))
  let branch = M.fromList
        [("choose", (["b"], CIf (CVar "b") unit unit)),
         ("main", ([], call "choose" [boolean]))]
  check "immortal branch conditions need no cleanup" (noOwnership (lower branch))
  let heap = lower (identities (call "strcat" [CStr "a", CStr "b"]))
  check "managed strings still retain and release despite the shared tagged ABI"
    (all (`isInfixOf` show heap) ["$arc.retain", "$arc.release"])
  let projected = lower (M.singleton "main" ([], CLet "p" (CMk 9 0 [boolean, call "strcat" [CStr "a", CStr "b"]])
        (CIf (CProj 0 (CVar "p")) (CProj 1 (CVar "p")) (CStr "fallback"))))
  check "a container with immortal and owned fields keeps heap ownership"
    (all (`isInfixOf` show projected) ["$arc.retain", "$arc.release", "$arc.setLayout"])

checkedLayouts = do
  let a=Ty.TV 0
      list=Ty.tList
      wordTy=Ty.TC "Word"
      wordList=list wordTy
      nested=list wordList
      schemas=M.fromList
        [("Nil",Ty.Forall [0] [] (list a)),
         ("Cons",Ty.Forall [0] [] (Ty.TFn a (Ty.TFn (list a) (list a))))]
      physical=Layouts (M.fromList [("Nil",(2,0,0)),("Cons",(2,1,2)),("Tup2",(8,0,2))])
        (M.singleton ["a","b"] 20)
      context=T.TypeContext [] schemas
      build=Layout.layoutsFor physical context
      table=right (build [nested,wordList,list Ty.tInt])
      key=right . Mono.typeKey
      listRep=LayoutRep (key wordList)
  check "checked recursive fields do not depend on constructed list lengths"
    (M.lookup (key wordList) table==Just (LayoutDef 2 (M.fromList
      [(0,[]),(1,[Just (ScalarRep RawWord),Just listRep])])))
  check "checked layout graph is independent of root order and repetition"
    (table==right (build [list Ty.tInt,wordList,nested,nested]))
  check "nested instantiations retain distinct finite layout identities"
    (M.size table==3 && M.lookup (key nested) table==Just (LayoutDef 2 (M.fromList
      [(0,[]),(1,[Just listRep,Just (LayoutRep (key nested))])])))
  let declaration=M.singleton "head" (ClosedSignature [Just listRep] Nothing)
      headOnly=M.singleton "head" (["xs"],CProj 0 (CVar "xs"))
      (_,annotations,_,_,_,_)=right (R.representWithCheckedLayouts table True S.empty declaration headOnly)
  check "an uncalled projection gets its Word field from the type, without a constructed cell"
    ([k | (CProj {},k)<-M.toList annotations]==[RawWord])
  refused "missing checked graph" "missing checked layout"
    (R.representWithCheckedLayouts M.empty True S.empty declaration headOnly)
  refused "aggregate external ABI without conversion" "no uniform conversion"
    (R.representWithCheckedLayouts table True (S.singleton "head") declaration headOnly)
  let bad=M.singleton "head" (["xs"],call "+" [CProj 0 (CVar "xs"),CInt 1])
  refused "checked field contradicted by arithmetic" "incompatible representations"
    (R.representWithCheckedLayouts table True S.empty declaration bad)
  let record=Ty.TRec (Ty.RExt "b" Ty.tStr (Ty.RExt "a" wordTy Ty.RNil))
      aggregates=right (build [Ty.TTupT [wordTy,Ty.tStr],record])
  check "tuple and canonical closed-record fields have checked layouts"
    (M.lookup (key record) aggregates==Just (LayoutDef 20 (M.singleton 2
      [Just (ScalarRep RawWord),Just TextRep]))
      && M.lookup (key (Ty.TTupT [wordTy,Ty.tStr])) aggregates==Just (LayoutDef 8
        (M.singleton 0 [Just (ScalarRep RawWord),Just TextRep])))
  let grow x=Ty.TAp (Ty.TC "Grow") x
      growth=T.TypeContext [] (M.singleton "More" (Ty.Forall [0] [] (Ty.TFn (grow (list a)) (grow a))))
      growthLayouts=physical {constructorLayouts=M.insert "More" (30,0,1) (constructorLayouts physical)}
  refused "expanding inductive layout" "finite layout graph"
    (Layout.layoutsFor growthLayouts growth [grow wordTy])
  let hiddenTy=Ty.TC "Hidden"
      hidden=T.TypeContext [] (M.insert "Hide" (Ty.Forall [0] [] (Ty.TFn a hiddenTy)) schemas)
      hiddenLayouts=physical {constructorLayouts=M.insert "Hide" (31,0,1) (constructorLayouts physical)}
  let hiddenTable=right (Layout.layoutsFor hiddenLayouts hidden [hiddenTy,list hiddenTy])
  check "hidden constructor fields have explicit uniform storage authority"
    (M.lookup (key hiddenTy) hiddenTable==Just (LayoutDef 31 (M.singleton 0 [Just UniformRep]))
      && M.size hiddenTable==2)
  check "raw units do not silently allocate hidden-field boxes"
    (M.null (right (Layout.layoutsForRaw hiddenLayouts hidden [hiddenTy,list hiddenTy])))
  let openTable=right (build [list (Ty.TV 0),list (Ty.TV 99)])
      genericKey=key (Layout.uniformType (list (Ty.TV 0)))
  check "generic list layout is independent of the source variable ordinal"
    (M.size openTable==1 && M.lookup genericKey openTable==Just (LayoutDef 2
      (M.fromList [(0,[]),(1,[Just UniformRep,Just (LayoutRep genericKey)])])))
  let openRow n=Ty.TRec (Ty.RExt "a" wordTy (Ty.RV n))
  check "open records have a tagged boundary independent of row identity or known shapes"
    (all (\n->Layout.representation aggregates (openRow n)==Just UniformRep
      && Layout.representation M.empty (openRow n)==Just UniformRep) [0,17,99]
      && M.null (right (build [openRow 0,openRow 17]))
      && not (Layout.openRecord record)
      && right (build [list (openRow 0),list (openRow 17)])==openTable)
  putStrLn "C2 checked layouts: finite recursion, nested instances, scope-independent fields and boundary refusals passed"

uniformEntries = do
  let declaration=M.singleton "identity" (ClosedSignature [Just (ScalarRep RawWord)] (Just (ScalarRep RawWord)))
      source=M.fromList [("identity",(["identity"],CVar "identity")),
                        ("main",([],call "identity" [word 17]))]
      (signatures,program)=right (Uniform.entries (S.singleton "identity") declaration source)
  check "uniform export keeps a managed public signature and a private raw worker"
    (M.lookup "identity" signatures==Just (ClosedSignature [Just UniformRep] (Just UniformRep))
      && M.lookup "$uniform.raw.identity" signatures==M.lookup "identity" declaration)
  check "checked internal calls bypass uniform boxing"
    (M.lookup "main" program==Just ([],call "$uniform.raw.identity" [word 17]))
  check "entry rewriting respects lexical shadowing"
    (M.lookup "$uniform.raw.identity" program==Just (["identity"],CVar "identity"))
  check "public scalar entry has real conversion calls"
    (case M.lookup "identity" program of
      Just (_,body)->all (`isInfixOf` show body) ["$uniform.unboxWord","$uniform.boxWord"]
      _->False)
  let (lowered,_)=right (Arc.lowerArcWithOptions True (S.singleton "identity") declaration M.empty source)
  check "uniform entry participates in owned-call lowering"
    (all (`isInfixOf` show (lowered M.! "identity"))
      ["$arc.uniformUnboxWord","$arc.uniformBoxWord","$arc.release"])
  let listRep=LayoutRep "word-list"
      layouts=M.singleton "word-list" (LayoutDef 2 (M.fromList
        [(0,[]),(1,[Just (ScalarRep RawWord),Just listRep])]))
      aggregateDecl=M.singleton "identity" (ClosedSignature [Just listRep] (Just listRep))
      aggregate=M.singleton "identity" (["xs"],CVar "xs")
      (aggregateSigs,aggregateProg)=right (Uniform.entriesWithLayouts layouts (S.singleton "identity") aggregateDecl aggregate)
  check "aggregate entry generates a finite graph and distinct public/worker contracts"
    (M.lookup "identity" aggregateSigs==Just (ClosedSignature [Just UniformRep] (Just UniformRep))
      && all (`isInfixOf` show (aggregateProg M.! "identity"))
           ["$uniform.unboxAggregate","$uniform.boxAggregate","U1 5 1 2 2 0 0 1 2 1 5"])
  mapM_ (\enabled->do
    let (p,_)=right (Arc.lowerArcWithLayouts layouts enabled (S.singleton "identity") aggregateDecl M.empty aggregate)
    check "aggregate adapters lower with specialization on and off"
      (all (`isInfixOf` show (p M.! "identity")) ["$arc.uniformUnboxAggregate","$arc.uniformBoxAggregate"])) [False,True]
  let managedLayouts=M.singleton "word-list" (LayoutDef 2 (M.fromList
        [(0,[]),(1,[Just (ScalarRep Managed),Just listRep])]))
      (_,managedProg)=right (Uniform.entriesWithLayouts managedLayouts (S.singleton "identity") aggregateDecl aggregate)
  check "an already managed aggregate needs no conversion graph or copying"
    ("$uniform.boxManaged" `isInfixOf` show managedProg && not ("boxAggregate" `isInfixOf` show managedProg))

uniformCalls = do
  let generic=ClosedSignature [Just UniformRep] (Just UniformRep)
      identity=("identity",(["x"],CVar "x"))
      lower enabled layouts signatures program=fst (right (Arc.lowerArcWithLayouts layouts enabled S.empty signatures M.empty program))
      scalar=M.fromList [identity,("main",([],call "identity" [word 7]))]
      scalarSigs=M.fromList [("identity",generic),("main",ClosedSignature [] (Just (ScalarRep RawWord)))]
  mapM_ (\enabled->do
    let p=lower enabled M.empty scalarSigs scalar
    check "a generic scalar edge has real box/unbox operations with or without cloning"
      (all (`isInfixOf` show p) ["$arc.uniformBoxWord","$arc.uniformUnboxWord"]
        && not ("$uniform.coerce." `isInfixOf` show p))) [False,True]
  refused "raw units cannot acquire allocating uniform conversion edges" "raw unit"
    (Arc.lowerRawWithLayouts M.empty False S.empty scalarSigs M.empty scalar)
  let handler=M.fromList [identity,("machineInterrupt",(["c","p","v"],
        call "Mem.writeWord" [call "Addr.fromWord" [CVar "p"],call "identity" [CVar "c"]]))]
      handlerSigs=M.fromList [("identity",generic),("machineInterrupt",
        ClosedSignature (replicate 3 (Just (ScalarRep RawWord))) (Just (DataRep 0)))]
  refused "interrupts cannot acquire allocating uniform conversion edges" "interrupt contract"
    (Arc.lowerArcWithLayouts M.empty False S.empty handlerSigs M.empty handler)
  let layouts=M.singleton "mixed" (LayoutDef 20 (M.singleton 0 [Just UniformRep,Just (ScalarRep RawWord)]))
      signatures=M.fromList [("identity",generic),("main",ClosedSignature [] (Just (LayoutRep "mixed")))]
      program=M.fromList [identity,("main",([],call "identity" [CMk 20 0 [CInt 1,word 2]]))]
  mapM_ (\enabled->do
    let p=lower enabled layouts signatures program
    check "mixed aggregates passed through a generic value retain conversion graphs"
      (all (`isInfixOf` show p) ["$arc.uniformBoxAggregate","$arc.uniformUnboxAggregate"]
        && not ("$uniform.coerce." `isInfixOf` show p))) [False,True]
  let badLayout=M.singleton "wrong" (LayoutDef 20 (M.singleton 0 [Just UniformRep,Just (ScalarRep RawAddr)]))
      badSigs=M.fromList [("identity",generic),("target",ClosedSignature [Just (LayoutRep "wrong")] (Just (LayoutRep "wrong")))]
      badProg=M.fromList [identity,("target",(["x"],CVar "x")),
        ("main",([],call "target" [CMk 20 0 [call "identity" [CInt 1],word 2]]))]
  refused "a uniform neighbor cannot hide a contradictory concrete field" "incompatible representations"
    (Arc.lowerArcWithLayouts badLayout True S.empty badSigs M.empty badProg)
  putStrLn "C2 uniform calls: scalar/aggregate conversions, cloning rollback and concrete-field refusals passed"

typedInstances = do
  let ns = Namespace "type-instantiation-tests"
      context = T.TypeContext [] M.empty
      e ty node = T.Expr ty (linShapeT [] ty) T.Generated Nothing node
      parameter = T.Binder (BinderId ns 0) "x" (Ty.Forall [] [] (Ty.TV 0)) (linShapeT [] (Ty.TV 0))
      local = e (Ty.TV 0) (T.Var (T.Local (T.binderId parameter)))
      identity = T.Function "identity" [parameter] local
      schema = Ty.Forall [0] [] (Ty.TFn (Ty.TV 0) (Ty.TV 0))
      int = e Ty.tInt (T.IntValue 1)
      wordSchema = Ty.Forall [] [] (Ty.TFn Ty.tInt (Ty.TC "Word"))
      word = e (Ty.TC "Word") (T.Apply (e (Ty.TFn Ty.tInt (Ty.TC "Word")) (T.Var (T.Global "Word.fromInt" wordSchema))) int)
      use n sc x r = e r (T.Apply (e (Ty.TFn (T.exprType x) r) (T.Var (T.Global n sc))) x)
      mainFor xs = T.Function "main" [] (e (Ty.TTupT (map T.exprType xs)) (T.TupleValue xs))
      source fn sc mainFn = right (P.program ns context
        (M.fromList [(T.functionName fn,sc),("main",Ty.Forall [] [] (T.functionType mainFn)),("Word.fromInt",wordSchema)])
        (M.fromList [(T.functionName fn,1),("main",0),("Word.fromInt",1)])
        (M.fromList [(T.functionName fn,fn),("main",mainFn)]))
      run pins keep = right . Mono.monomorphize pins keep
      build xs = source identity schema (mainFor [use "identity" schema x (T.exprType x) | x<-xs])
      result xs = P.programFunctions (run S.empty S.empty (build xs))
      names xs = M.keysSet (M.delete "main" (result xs))
      forward = names [int,word]
  check "type-directed identities are independent of call order"
    (forward == names [word,int] && S.size forward == 2)
  check "single and repeated instantiations retain the same identities"
    (names [word] `S.isSubsetOf` forward && names [word,word] == names [word])
  check "closed clone types are independent of the first caller"
    (S.fromList [T.functionType f | (n,f)<-M.toList (result [word,int]), n/="main"]
      == S.fromList [Ty.TFn Ty.tInt Ty.tInt, Ty.TFn (Ty.TC "Word") (Ty.TC "Word")])
  check "only explicitly retained generic entries remain alongside clones"
    (M.member "identity" (P.programFunctions (run S.empty (S.singleton "identity") (build [word])))
      && M.notMember "identity" (result [word]))
  let pinned = P.programFunctions (run (S.singleton "identity") S.empty (build [word,int]))
  check "pinned generic entries retain their original alongside checked internal instances"
    (M.size pinned==4 && M.member "identity" pinned && names [word,int] `S.isSubsetOf` M.keysSet pinned)
  let recursive = identity {T.functionBody=use "identity" schema local (Ty.TV 0)}
      repeated = P.programFunctions (run S.empty S.empty (source recursive schema (mainFor [use "identity" schema int Ty.tInt])))
  check "regular typed recursion closes on one instance" (M.size repeated == 2)
  let growingSchema = Ty.Forall [0] [] (Ty.TFn (Ty.TV 0) Ty.tInt)
      nested = e (Ty.tList (Ty.TV 0)) (T.ListValue [local])
      growing = identity {T.functionBody=use "identity" growingSchema nested Ty.tInt}
      growingProgram = source growing growingSchema (mainFor [use "identity" growingSchema int Ty.tInt])
  let (bounded,growthNotes)=right (Mono.monomorphizeWithNotes S.empty S.empty growingProgram)
  check "typed expanding recursion retains a bounded instance and its generic fallback"
    (M.size (P.programFunctions bounded)==3 && M.member "identity" (P.programFunctions bounded)
      && growthNotes==[("identity","expanding recursive type specialization; using tagged generic entry")])
  let rowA = Ty.TRec (Ty.RExt "a" Ty.tInt (Ty.RExt "b" (Ty.TC "Word") Ty.RNil))
      rowB = Ty.TRec (Ty.RExt "b" (Ty.TC "Word") (Ty.RExt "a" Ty.tInt Ty.RNil))
  check "closed row ordering cannot fragment instance identity" (Mono.typeKey rowA == Mono.typeKey rowB)
  refused "open type key" "open type" (Mono.typeKey (Ty.TV 30))
  let shorter = e (Ty.tList Ty.tInt) (T.ListValue [int])
      longer = e (Ty.tList Ty.tInt) (T.ListValue [int,int])
      nestedList = e (Ty.tList (Ty.tList Ty.tInt)) (T.ListValue [shorter])
  check "list lengths do not create type instances; nested element types do"
    (S.size (names [shorter,longer]) == 1 && S.size (names [shorter,nestedList]) == 2)
  putStrLn "C2 typed instances: stable identities, complete types, rows, recursive admission and retained boundaries passed"

scalarStorage = do
  let wrapper=LayoutRep "wrapper"
      nested=LayoutRep "nested"
      layouts=M.fromList [("wrapper",ScalarLayoutDef 40 0 (ScalarRep RawWord)),
                          ("nested",ScalarLayoutDef 41 0 wrapper)]
      signatures=M.fromList
        [("make",ClosedSignature [Just (ScalarRep RawWord)] (Just nested)),
         ("get",ClosedSignature [Just nested] (Just (ScalarRep RawWord)))]
      source=M.fromList [("make",(["x"],CMk 41 0 [CMk 40 0 [CVar "x"]])),
                        ("get",(["x"],CProj 0 (CProj 0 (CVar "x")))),
                        ("main",([],call "print" [call "make" [word 7]]))]
  mapM_ (\enabled->do
    let (p,_,args,_,_,scalars,_)=right (R.representWithStorage layouts enabled S.empty signatures source)
        (lowered,_)=right (Arc.lowerArcWithLayouts layouts enabled S.empty signatures M.empty source)
    check "nested checked wrappers use their leaf register kind"
      (M.lookup "get" args==Just [RawWord] && not (M.null scalars))
    check "wrapper construction/projection disappears while printing keeps the nominal boxes"
      (not ("CMk 41" `isInfixOf` show (lowered M.! "make"))
       && not ("CProj" `isInfixOf` show (lowered M.! "get"))
       && "uniformBoxAggregate" `isInfixOf` show (lowered M.! "main")
       && "U3 " `isInfixOf` show p)
    let rawSource=M.delete "main" source
        (raw,_)=right (Arc.lowerRawWithLayouts layouts enabled (S.fromList ["make","get"]) signatures M.empty rawSource)
    check "fixed scalar wrappers are allocation-free in raw units"
      (not ("CMk" `isInfixOf` show raw || "CProj" `isInfixOf` show raw))) [False,True]
  refused "recursive scalar authority" "cyclic scalar layout"
    (R.representWithStorage (M.singleton "wrapper" (ScalarLayoutDef 40 0 wrapper)) True S.empty M.empty M.empty)
  refused "managed scalar authority" "managed payload"
    (R.representWithStorage (M.singleton "wrapper" (ScalarLayoutDef 40 0 TextRep)) True S.empty M.empty M.empty)
  let a=Ty.TV 0;wrap t=Ty.TAp (Ty.TC "Wrap") t
      schemas=M.singleton "Wrap" (Ty.Forall [0] [] (Ty.TFn a (wrap a)))
      physical=Layouts (M.singleton "Wrap" (40,0,1)) M.empty
      roots=[wrap (Ty.TC "Word"),wrap Ty.tInt,wrap Ty.tStr,wrap a,wrap (wrap (Ty.TC "Word"))]
      table=right (Layout.layoutsFor physical (T.TypeContext [] schemas) roots)
      key=right . Mono.typeKey . Layout.uniformType
  check "storage is determined by the instantiated definition and not root order"
    (table==right (Layout.layoutsFor physical (T.TypeContext [] schemas) (reverse roots))
      && M.lookup (key (wrap (Ty.TC "Word"))) table==Just (ScalarLayoutDef 40 0 (ScalarRep RawWord))
      && M.lookup (key (wrap Ty.tStr)) table==Just (LayoutDef 40 (M.singleton 0 [Just TextRep]))
      && M.lookup (key (wrap a)) table==Just (LayoutDef 40 (M.singleton 0 [Just UniformRep])))
  putStrLn "Scalar storage: canonical selection, nominal printing, nested erasure, rollback and raw admission passed"

productValuesCheck = do
  let layout=M.singleton "pair" (LayoutDef 901 (M.singleton 0 [Just (ScalarRep RawWord),Just (ScalarRep RawWord)]))
      pair=LayoutRep "pair"
      declarations=M.fromList
        [("make",ClosedSignature [Just (ScalarRep RawWord)] (Just pair)),
         ("identity",ClosedSignature [Just pair] (Just pair)),
         ("pick",ClosedSignature [Just pair] (Just (ScalarRep RawWord)))]
      program=M.fromList
        [("make",(["w"],CMk 901 0 [CVar "w",CVar "w"])),
         ("identity",(["p"],CVar "p")),
         ("pick",(["p"],CProj 1 (CVar "p"))),
         ("main",([],call "print" [call "Word.toInt" [call "pick" [call "identity" [call "make" [word 7]]]]]))]
      ((_,_,_,_,_,_,_),proof)=right (R.representWithProductEvidence 8 M.empty layout True S.empty declarations program)
      (lowered,_)=right (Arc.lowerArcWithProductEvidence 8 M.empty layout True S.empty declarations M.empty program)
  check "product evidence comes from complete checked definitions"
    (M.lookup "make" (productResults proof)==Just (Just (ProductShape 901 0 [RawWord,RawWord])))
  check "private product parameters expand to their immediate fields"
    (fmap (length . fst) (M.lookup "$worker.ret2.$product.identity" lowered)==Just 2
      && fmap (length . fst) (M.lookup "pick" lowered)==Just 2)
  check "private scalar-product path does not materialize its nominal constructor"
    (not ("CMk 901" `isInfixOf` show lowered) && "$product.pack2" `isInfixOf` show lowered)
  let ownedLayouts=M.singleton "owned" (LayoutDef 902 (M.singleton 0 [Just TextRep,Just (ScalarRep RawWord)]))
      ownedRep=LayoutRep "owned"
      ownedSignatures=M.singleton "identity" (ClosedSignature [Just ownedRep] (Just ownedRep))
      ownedProgram=M.singleton "identity" (["p"],CVar "p")
  check "checked managed fields carry individual ownership in product packets"
    (productLayout 8 ownedLayouts "owned"==Just (OwnedProductShape 902 0 [Managed,RawWord] [True,False]))
  let wrapperLayouts=M.singleton "text" (LayoutDef 920 (M.singleton 0 [Just TextRep]))
      wrapperRep=LayoutRep "text"
      wrapperSignatures=M.singleton "identity" (ClosedSignature [Just wrapperRep] (Just wrapperRep))
      (wrapperLowered,_)=right (Arc.lowerArcWithProductEvidence 8 M.empty wrapperLayouts True S.empty wrapperSignatures M.empty ownedProgram)
  check "owned one-field wrappers use a checked one-word private payload"
    (productLayout 1 wrapperLayouts "text"==Just (OwnedProductShape 920 0 [Managed] [True])
      && productLayout 0 wrapperLayouts "text"==Nothing
      && M.member "$worker.payload.$product.identity" wrapperLowered
      && not ("CMk 920" `isInfixOf` show wrapperLowered)
      && not ("$product.pack1" `isInfixOf` show wrapperLowered)
      && not ("CProj" `isInfixOf` show wrapperLowered))
  refused "owned wrappers in raw entry" "owned-reference products"
    (Arc.lowerRawWithProductEvidence 8 M.empty wrapperLayouts True S.empty wrapperSignatures M.empty ownedProgram)
  let nestedWrapper=M.insert "outer" (LayoutDef 921 (M.singleton 0 [Just wrapperRep])) wrapperLayouts
  check "nested owned one-field wrappers retain one leaf owner"
    (fmap productParts (productLayout 8 nestedWrapper "outer")==Just (921,0,[Managed])
      && fmap productOwners (productLayout 8 nestedWrapper "outer")==Just [True])
  check "unknown fields do not acquire an ownership or representation default"
    (productLayout 8 (M.singleton "unknown" (LayoutDef 903 (M.singleton 0 [Nothing,Just TextRep]))) "unknown"==Nothing)
  refused "owned products in raw entry" "owned-reference products"
    (Arc.lowerRawWithProductEvidence 8 M.empty ownedLayouts True S.empty ownedSignatures M.empty ownedProgram)
  let ((ownedRepresented,_,_,_,_,_,_),ownedProof)=right (R.representWithProductEvidence 8 M.empty ownedLayouts True S.empty ownedSignatures ownedProgram)
  refused "owned products in interrupt entry" "owned-reference products"
    (Interrupt.checkInterruptWithProducts M.empty (productValues ownedProof)
      (M.singleton "machineInterrupt" (ownedRepresented M.! "identity")))
  check "product capacity is a target constraint"
    (productLayout 1 layout "pair"==Nothing && productLayout 2 layout "pair"==Just (ProductShape 901 0 [RawWord,RawWord]))
  let nestedLayouts=M.insert "outer" (LayoutDef 903 (M.singleton 0 [Just (LayoutRep "owned"),Just TextRep])) ownedLayouts
      nestedShape=NestedProductShape 903 0 [ProductNested (OwnedProductShape 902 0 [Managed,RawWord] [True,False]),ProductWord Managed True]
  check "nested packets flatten exact leaf kinds and independent owners"
    (productLayout 8 nestedLayouts "outer"==Just nestedShape
      && productParts nestedShape==(903,0,[Managed,RawWord,Managed])
      && productOwners nestedShape==[True,False,True]
      && productLayout 2 nestedLayouts "outer"==Just (OwnedProductShape 903 0 [Managed,Managed] [True,True]))
  let recursiveLayouts=M.fromList
        [("a",LayoutDef 904 (M.singleton 0 [Just (LayoutRep "b"),Just (ScalarRep RawWord)])),
         ("b",LayoutDef 905 (M.singleton 0 [Just (LayoutRep "a"),Just (ScalarRep RawWord)])),
         ("parent",LayoutDef 906 (M.singleton 0 [Just (LayoutRep "a"),Just (ScalarRep RawWord)]))]
  check "recursive fields retain deterministic boxed edges"
    (M.elems (productLayouts 8 recursiveLayouts)==
      [OwnedProductShape tid 0 [Managed,RawWord] [True,False] | tid<-[904,905,906]])
  let wideNested=M.fromList
        [("four",LayoutDef 907 (M.singleton 0 (replicate 4 (Just (ScalarRep RawWord))))),
         ("eight",LayoutDef 908 (M.singleton 0 (replicate 2 (Just (LayoutRep "four"))))),
         ("nine",LayoutDef 909 (M.singleton 0 [Just (LayoutRep "eight"),Just (ScalarRep RawWord)])),
         ("deep",LayoutDef 910 (M.singleton 0 [Just (LayoutRep "nine"),Just (ScalarRep RawWord)]))]
  check "eight nested leaves qualify while nine retain the inner heap boundary"
    (fmap productParts (productLayout 8 wideNested "eight")==Just (908,0,replicate 8 RawWord)
      && productLayout 8 wideNested "nine"==Just (OwnedProductShape 909 0 [Managed,RawWord] [True,False])
      && fmap productParts (productLayout 8 wideNested "deep")==Just (910,0,[Managed,RawWord,RawWord])
      && fmap productOwners (productLayout 8 wideNested "deep")==Just [True,False,False])
  check "canonical child choices are independent of ancestors and map insertion order"
    (M.restrictKeys (productLayouts 8 wideNested) (S.fromList ["four","eight"])
       ==productLayouts 8 (M.restrictKeys wideNested (S.fromList ["four","eight"]))
      && productLayouts 8 wideNested==productLayouts 8 (M.fromList (reverse (M.toList wideNested))))
  let nestedScalar=M.insert "outer" (LayoutDef 903 (M.singleton 0 [Just pair,Just (ScalarRep RawWord)])) layout
      outer=Just (LayoutRep "outer");wordRep=Just (ScalarRep RawWord)
      nestedSigs=M.fromList [("make",ClosedSignature [wordRep] outer),
        ("get",ClosedSignature [outer] wordRep),("entry",ClosedSignature [wordRep] wordRep)]
      nestedProgram=M.fromList
        [("make",(["w"],CMk 903 0 [CMk 901 0 [CVar "w",CVar "w"],CVar "w"])),
         ("get",(["p"],call "Word.add" [CProj 1 (CProj 0 (CVar "p")),CProj 1 (CVar "p")])),
         ("entry",(["w"],call "get" [call "make" [CVar "w"]]))]
      (nestedRaw,_)=right (Arc.lowerRawWithProductEvidence 8 M.empty nestedScalar True (S.singleton "entry") nestedSigs M.empty nestedProgram)
  check "nested raw products flatten calls and projections without boxes"
    (not ("CMk 901" `isInfixOf` show nestedRaw || "CMk 903" `isInfixOf` show nestedRaw)
      && fmap (length . fst) (M.lookup "get" nestedRaw)==Just 3)
  refused "nested owned leaves remain forbidden in raw code" "owned-reference products"
    (Arc.lowerRawWithProductEvidence 8 M.empty nestedLayouts True S.empty
      (M.singleton "identity" (ClosedSignature [outer] outer)) M.empty ownedProgram)


rawProductsCheck = do
  let layouts=M.singleton "pair" (LayoutDef 901 (M.singleton 0 (replicate 2 (Just (ScalarRep RawWord)))))
      pair=Just (LayoutRep "pair")
      wordRep=Just (ScalarRep RawWord)
      signatures=M.fromList
        [("make",ClosedSignature [wordRep] pair),
         ("get",ClosedSignature [pair] wordRep),
         ("entry",ClosedSignature [wordRep] wordRep)]
      source=M.fromList
        [("make",(["w"],CMk 901 0 [CVar "w",CVar "w"])),
         ("get",(["p"],CProj 1 (CVar "p"))),
         ("entry",(["w"],call "get" [call "make" [CVar "w"]]))]
      lower pinned sigs input=Arc.lowerRawWithProductEvidence 8 M.empty layouts True pinned sigs M.empty input
      (raw,_)=right (lower (S.singleton "entry") signatures source)
  check "raw checked products lower without heap fields or ownership calls"
    (not ("CMk 901" `isInfixOf` show raw || "$arc.retain" `isInfixOf` show raw || "$arc.release" `isInfixOf` show raw)
      && "$product.pack2" `isInfixOf` show raw)
  refused "a raw exported product requires a concrete one-word boundary" "pinned boundary"
    (lower (S.singleton "make") signatures source)
  refused "a raw public boxed parameter is refused" "pinned boundary"
    (lower (S.singleton "get") signatures source)
  refused "an exported constructor stub is checked even when unused" "heap construction"
    (Interrupt.checkRawUnitWithProducts M.empty M.empty (S.singleton "make") (M.restrictKeys source (S.singleton "make")))
  let wide=M.insert "wide" (["a","b","c","d","e"],CProj 0 (CVar "a")) source
      wideSigs=M.insert "wide" (ClosedSignature (replicate 5 pair) wordRep) signatures
  refused "raw physical arguments are checked after expansion" "after product expansion"
    (lower S.empty wideSigs wide)
  let handler=M.insert "machineInterrupt" (["cause","pc","value"],call "Mem.writeWord"
        [call "Addr.fromWord" [CVar "pc"],call "get" [call "make" [CVar "cause"]]]) source
      handlerSigs=M.insert "machineInterrupt" (ClosedSignature (replicate 3 wordRep) (Just (DataRep 0))) signatures
      (lowered,_)=right (Arc.lowerArcWithProductEvidence 8 M.empty layouts True S.empty handlerSigs M.empty handler)
  check "interrupt helpers use checked products without materialization"
    (not ("CMk 901" `isInfixOf` show lowered))
  let physical p=Interrupt.checkLoweredProducts False Arc.primitiveContracts ["entry"] (M.singleton "entry" ([],p))
  refused "lowered proof rejects heap construction" "heap materialization" (physical (CMk 901 0 [CInt 1,CInt 2]))
  refused "lowered proof rejects arbitrary projections" "heap projection" (physical (CProj 0 (CInt 1)))
  refused "lowered proof rejects conversion adapters" "may allocate" (physical (call "$arc.uniformBoxWord" [CInt 1]))
  refused "lowered proof rejects heap effects inside a product packet" "heap materialization"
    (physical (call "$product.pack2" [CInt 1,CMk 901 0 [CInt 1,CInt 2]]))
  putStrLn "Raw/interrupt products: checked source fields, physical argument limits and post-lowering box/projection refusal passed"
