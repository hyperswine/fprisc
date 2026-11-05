-- Keep a tagged-word entry for ARC exports and a private raw worker for
-- checked internal calls. Explicit --raw units never run this transform.
module Arc.Uniform (entries, entriesWithLayouts, descriptorTid, convert, convertChecked) where
import Core.Syntax
import Representation.Types
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

entries :: S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (M.Map String CallSignature, Prog)
entries=entriesWithLayouts M.empty

-- A compiler-private chain must not collide with List Word under rollback.
descriptorTid :: Int
descriptorTid=0x1fff0001

entriesWithLayouts :: LayoutTable -> S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (M.Map String CallSignature, Prog)
entriesWithLayouts layouts pinned declarations input
  | M.null selected=Right (declarations,input)
  | otherwise=do
      mapM_ (\n->unless (M.notMember (worker n) input)
        (Left ("uniform boundary: reserved worker collision at "++n))) (M.keys selected)
      let renamed=M.fromList [(rename n,(ps,rewrite (S.fromList ps) body)) | (n,(ps,body))<-M.toList input]
          signatures=M.fromList [(rename n,sc) | (n,sc)<-M.toList declarations]
          wrappers=M.mapWithKey wrapper selected
          public=M.map (\sc->let (ps,r)=signatureParts sc in ClosedSignature (map uniform ps) (uniform r)) selected
      pure (public `M.union` signatures, wrappers `M.union` renamed)
  where
    selected=M.filterWithKey (\n sc->S.member n pinned && n `notElem` ["main","machineInterrupt"]
      && M.member n input && let (ps,r)=signatureParts sc in all known (r:ps) && any adapted (r:ps)) declarations
    known Nothing=False
    known (Just (LayoutRep key))=complete S.empty key
    known _=True
    complete seen key | S.member key seen=True
    complete seen key=case M.lookup key layouts of
      Nothing->False
      Just def->let (_,vs)=layoutParts def in all (field (S.insert key seen)) (concat (M.elems vs))
    field seen (Just (LayoutRep key))=complete seen key
    field _ rep=known rep
    raw (Just (ScalarRep k))=k/=Managed
    raw _=False
    adapted (Just LayoutRep {})=True
    adapted rep=raw rep
    uniform rep | adapted rep=Just UniformRep
                | otherwise=rep
    worker n="$uniform.raw."++n
    rename n=if M.member n selected then worker n else n
    call n=foldl CApp (CVar n)
    adapt direction rep value=case rep of
      Just r | adapted rep->convert layouts direction r value
      _->value
    wrapper n sc=
      let (ps,r)=signatureParts sc
          names=["$uniform.arg."++show i | i<-[0..length ps-1]]
          args=zipWith (adapt "unbox") ps (map CVar names)
      in (names,adapt "box" r (call (worker n) args))
    rewrite bound expr=case expr of
      CVar n | S.notMember n bound->CVar (rename n)
      CApp f x->CApp (rewrite bound f) (rewrite bound x)
      CLet n a b->CLet n (rewrite bound a) (rewrite (S.insert n bound) b)
      CLam ps b->CLam ps (rewrite (bound `S.union` S.fromList ps) b)
      CIf c t f->CIf (rewrite bound c) (rewrite bound t) (rewrite bound f)
      CMk t v fs->CMk t v (map (rewrite bound) fs)
      CProj i x->CProj i (rewrite bound x)
      CTagEq t v x->CTagEq t v (rewrite bound x)
      _->expr

-- Physical conversions shared by public wrappers and generic call edges.
-- The caller supplies complete field evidence before graph serialization.
convert :: LayoutTable -> String -> Rep -> Core -> Core
convert=convertWith False

-- A value extracted from a uniform slot has no concrete representation
-- evidence. Check even managed leaves and non-copying aggregate subgraphs.
convertChecked :: LayoutTable -> String -> Rep -> Core -> Core
convertChecked=convertWith True

convertWith checked layouts direction rep value=adapt rep value
  where
    validating=checked && direction=="unbox"
    call n=foldl CApp (CVar n)
    suffix k=case k of RawWord->"Word";RawAddr->"Addr";RawF64->"F64";RawF32->"F32";Managed->"Managed"
    adapt rep value=case rep of
      ScalarRep k | k/=Managed->call ("$uniform."++direction++suffix k) [value]
      ScalarRep Managed | validating->call "$uniform.unboxTagged" [value]
      TextRep | validating->call "$uniform.unboxText" [value]
      DataRep tid | validating->call "$uniform.unboxData" [value,CInt (toInteger tid)]
      LayoutRep key
        | validating || needs S.empty key->let (plan,descriptors)=graph key in
            call ("$uniform."++direction++"Aggregate") [value,CStr plan,descriptors]
        | otherwise->call ("$uniform."++direction++"Managed") [value]
      UniformRep->value
      _->call ("$uniform."++direction++"Managed") [value]
    needs seen key | S.member key seen=False
    needs seen key=case layouts M.! key of
      ScalarLayoutDef {}->True
      LayoutDef _ vs->any (\rep->case rep of
        Just (LayoutRep child)->needs (S.insert key seen) child
        Just (ScalarRep k)->k/=Managed
        _->False) (concat (M.elems vs))
    graph root=
      let reach seen key | S.member key seen=seen
          reach seen key=case layouts M.! key of
            def->let (_,vs)=layoutParts def in foldl reach (S.insert key seen) [child | Just (LayoutRep child)<-concat (M.elems vs)]
          keys=S.toAscList (reach S.empty root)
          scalar=any ((/=Nothing) . scalarLayout . (layouts M.!)) keys
          strict=validating || scalar
          base=if strict then 9 else 5
          indices=M.fromList (zip keys [base..])
          ref (Just (LayoutRep key))=indices M.! key
          ref (Just (ScalarRep k))=case k of Managed->if strict then 5 else 0;RawWord->1;RawAddr->2;RawF64->3;RawF32->4
          ref (Just TextRep) | strict=6
          ref (Just (DataRep 1)) | strict=7
          ref (Just (DataRep 0)) | strict=8
          ref _=0
          variants=[(tid,scalarLayout def/=Nothing,M.toAscList vs) | key<-keys,let def=layouts M.! key,let (tid,vs)=layoutParts def]
          numbers=indices M.! root:length keys:concat
            [[tid]++[if immediate then 1 else 0 | scalar]++[length vs]++concat [v:length fs:map ref fs | (v,fs)<-vs] | (tid,immediate,vs)<-variants]
          strings=[CStr [case rep of Just (ScalarRep k)->kindTag k;Just (LayoutRep key)->either (const '?') kindTag (layoutKind layouts key);_->'t' | rep<-fs] | (_,_,vs)<-variants,(_,fs)<-vs]
          descriptors=foldr (\s rest->CMk descriptorTid 1 [s,rest]) (CMk descriptorTid 0 []) strings
      in ((if scalar then "U3 " else if validating then "U2 " else "U1 ")++unwords (map show numbers),descriptors)
