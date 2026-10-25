-- Resolve structured diagnostics against source context, then render CLI text.
-- The legacy adapter is for old API callers; native/Sol inference bypass it.
module Diagnostic.Render
  (Sources,Anchors,LocatedDiagnostic,resolveDiagnostic,locatedDiagnostic,
   diagnosticLocation,locatedSpan,renderLocated,renderSourceDiagnostic,anchorLegacyMessage) where
import Diagnostic.Syntax
import Source.Span
import Data.List (isPrefixOf)
import Text.Read (readMaybe)
import qualified Data.Map.Strict as M

type Sources=M.Map FilePath String
type Anchors=M.Map String (FilePath,Int)
data LocatedDiagnostic=LocatedDiagnostic Diagnostic (Maybe SourceLocation) (Maybe SourceSpan)
locatedDiagnostic :: LocatedDiagnostic -> Diagnostic
locatedDiagnostic (LocatedDiagnostic d _ _)=d
diagnosticLocation :: LocatedDiagnostic -> Maybe SourceLocation
diagnosticLocation (LocatedDiagnostic _ p _)=p
locatedSpan :: LocatedDiagnostic -> Maybe SourceSpan
locatedSpan (LocatedDiagnostic _ _ s)=s

resolveDiagnostic :: Sources -> Anchors -> Diagnostic -> LocatedDiagnostic
resolveDiagnostic sources anchors d=case diagnosticSpan d >>= explicit of
  Just (p,s)->LocatedDiagnostic d (Just p) (Just s)
  Nothing->case diagnosticOwner d >>= (`M.lookup` anchors) of
    Nothing->LocatedDiagnostic d Nothing Nothing
    Just (file,line)->case diagnosticOffset d >>= point file of
      Just (p,s)->LocatedDiagnostic d (Just p) (Just s)
      Nothing->case tokenPosition sources anchors file line (diagnosticMessage d) of
        Just (l,c)->let off=SourceOffset (sum (map ((+1).length) (take (l-1) (lines (M.findWithDefault "" file sources))))+c-1)
                   in LocatedDiagnostic d (Just (AtPoint file l c)) (Just (pointSpan file off))
        Nothing->LocatedDiagnostic d (Just (AtLine file line)) Nothing
  where
    point file offset=do
      source<-M.lookup file sources
      (l,c)<-offsetPosition source offset
      pure (AtPoint file l c,pointSpan file offset)
    explicit span'=do
      source<-M.lookup (spanFile span') sources
      (l,c)<-offsetPosition source (spanStart span')
      _<-offsetPosition source (spanEnd span')
      if spanEnd span'<spanStart span' then Nothing
        else Just (AtPoint (spanFile span') l c,span')

renderLocated :: LocatedDiagnostic -> String
renderLocated (LocatedDiagnostic d location _)=prefix++diagnosticBody d
  where prefix=case location of
          Just (AtPoint file line col)->file++":"++show line++":"++show col++": "
          Just (AtLine file line)->file++":"++show line++": "
          Nothing->""
renderSourceDiagnostic :: Sources -> Anchors -> Diagnostic -> String
renderSourceDiagnostic sources anchors=renderLocated . resolveDiagnostic sources anchors

-- Old string APIs still accept their historical metadata spelling. Decode it
-- here once; no inference producer or structured renderer inspects prose for
-- owner/offset metadata. Literal marker-looking text in a Diagnostic is text.
anchorLegacyMessage :: Sources -> Anchors -> String -> String
anchorLegacyMessage sources anchors text=renderSourceDiagnostic sources anchors d
  where
    (owner,body)=case text of
      'i':'n':' ':rest | (n,':':' ':more)<-break (==':') rest -> (Just n,more)
      _->(Nothing,text)
    (offset,message)=case body of
      '@':rest | (digits@(_:_),'~':' ':more)<-span (`elem` ['0'..'9']) rest,
                 Just off<-readMaybe digits -> (Just (SourceOffset off),more)
      _->(Nothing,body)
    d=(diagnostic InferenceError offset message) {diagnosticOwner=owner}

-- Until all source nodes retain ranges, old unmarked diagnostics keep their
-- established best-effort token/definition fallback. It is display recovery,
-- never source metadata fed back into inference or checked Core.
tokenPosition :: Sources -> Anchors -> FilePath -> Int -> String -> Maybe (Int,Int)
tokenPosition sources anchors file line body=do
  source<-M.lookup file sources
  token<-messageToken body
  let end=case [l | (_, (f,l))<-M.toList anchors,f==file,l>line] of
        []->length (lines source); ls->minimum ls-1
      slice=take (end-line+1) (drop (line-1) (lines source))
  case [(line+i,c) | (i,text)<-zip [0..] slice,c<-take 1 (wordHits token text)] of
    p:_->Just p; []->Nothing
  where
    messageToken text=case break (=='\'') text of
      (_, '\'':rest) | (token@(_:_),'\'':_)<-break (=='\'') rest -> Just token
      _ | Just rest<-after "application of " text -> Just (takeWhile identChar rest)
        | otherwise->Nothing
    after pattern' text
      | pattern' `isPrefixOf` text=Just (drop (length pattern') text)
      | otherwise=case text of _:rest->after pattern' rest; []->Nothing
    wordHits token text=[i+1 | i<-[0..length text-length token],take (length token) (drop i text)==token,
      i==0 || not (identChar (text!!(i-1))),
      i+length token>=length text || not (identChar (text!!(i+length token)))]
    identChar c=c `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.'@" :: String)
