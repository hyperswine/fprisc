-- Closed, serializable effect plans. No VM closures enter the redo journal.
module Sol.Effects where

import Sol.Native (GitRequest(..))
import qualified Data.IntMap.Strict as IM
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isPrefixOf)
import Text.Read (readMaybe)

data ProcessSpec = ProcessSpec
  { psArgv :: [String], psCwd :: Maybe FilePath, psEnv :: [(String,String)]
  , psStdin :: String, psTimeoutMs :: Maybe Int }
  deriving (Show, Read)
data Projection = Out | Trim | Line Int | Field String Int deriving (Eq, Show, Read)
data DeferredRef = DeferredRef Int [Projection] deriving (Eq, Show, Read)
data Argument = LiteralArg String | FromArg DeferredRef deriving (Show, Read)
data DeferredStep = PlannedProcess [Argument] ProcessSpec | PlannedGit GitRequest
  | PlannedTag FilePath String DeferredRef Integer deriving (Show, Read)
data Capture = ProcessCapture Int String String | TextCapture String deriving (Eq, Show, Read)
type Completion = Either String Capture
type Done = IM.IntMap Completion

data Effect = EWrite FilePath String | ERemove FilePath | EMkdir FilePath | ERmdir FilePath
  | EShell String | EShellAt FilePath String | EProcess ProcessSpec | EGit GitRequest
  | EArchive FilePath FilePath Integer Integer | ELater DeferredStep
  | ELogWrite FilePath String deriving (Show, Read)

data GitUndo = GitUndo FilePath String String String Integer deriving (Eq, Show, Read)
data UndoRecord = UndoRecord FilePath Bool GitUndo deriving (Eq, Show, Read)

completionFailed :: Completion -> Bool
completionFailed (Left _) = True
completionFailed (Right (ProcessCapture code _ _)) = code /= 0
completionFailed _ = False

resolveDeferred :: Done -> DeferredRef -> Either String String
resolveDeferred done (DeferredRef i ps) = do
  captured <- maybe (Left ("missing deferred result " ++ show i)) id (IM.lookup i done)
  if completionFailed (Right captured) then Left ("failed deferred result " ++ show i)
    else go captured ps
  where
    go (TextCapture s) [] = Right s
    go (ProcessCapture _ _ _) [] = Left "process result needs Deferred.out"
    go (ProcessCapture _ out _) (Out:xs) = go (TextCapture out) xs
    go (TextCapture s) (Trim:xs) = go (TextCapture (dropWhileEnd isSpace (dropWhile isSpace s))) xs
    go (TextCapture s) (Line n:xs) = select "line" n (lines s) >>= \v -> go (TextCapture v) xs
    go (TextCapture s) (Field sep n:xs)
      | null sep = Left "Deferred.field separator must not be empty"
      | otherwise = select "field" n (split sep s) >>= \v -> go (TextCapture v) xs
    go _ _ = Left "invalid deferred projection type"
    select label n xs | n > 0, x:_ <- drop (n-1) xs = Right x
                      | otherwise = Left ("Deferred." ++ label ++ " index out of range: " ++ show n)
    split sep = walk ""
      where walk acc [] = [reverse acc]
            walk acc s | sep `isPrefixOf` s = reverse acc : walk "" (drop (length sep) s)
            walk acc (c:cs) = walk (c:acc) cs

stepRefs :: DeferredStep -> [DeferredRef]
stepRefs (PlannedProcess args _) = [r | FromArg r <- args]
stepRefs (PlannedTag _ _ ref _) = [ref]
stepRefs _ = []
isPush :: Effect -> Bool
isPush (ELater (PlannedGit (GitRequest _ 15 _ _ _ _ _))) = True
isPush _ = False

-- Validate before the commit point and again before replaying journal data.
validatePlan :: [Effect] -> Either String ()
validatePlan es
  | length (filter external es) > 4096 = Left "deferred result count exceeds 4096 receipt limit"
  | otherwise = walk IM.empty False 0 es
  where
    external EShell{} = True
    external EShellAt{} = True
    external EProcess{} = True
    external EGit{} = True
    external EArchive{} = True
    external ELater{} = True
    external _ = False
    walk _ _ _ [] = Right ()
    walk types pushed i (e:es)
      | pushed, not (isLog e) = Left "Git.push must be the last queued effect"
      | otherwise = do
          case e of
            ELater step -> mapM_ (check types i) (stepRefs step)
            _ -> Right ()
          let ty = case e of ELater (PlannedProcess _ _) -> Just True
                             ELater _ -> Just False
                             _ -> Nothing
          walk (maybe types (\t -> IM.insert i t types) ty) (pushed || isPush e) (i+1) es
    isLog (ELogWrite _ _) = True
    isLog _ = False
    check types i (DeferredRef root ps)
      | root >= i = Left "deferred argument must reference an earlier step"
      | otherwise = case IM.lookup root types of
          Nothing -> Left "deferred argument does not name a result-producing step"
          Just process -> projections process ps
    projections False [] = Right ()
    projections True (Out:ps) = projections False ps
    projections False (Trim:ps) = projections False ps
    projections False (Line n:ps) | n > 0 = projections False ps
    projections False (Field sep n:ps) | n > 0 && not (null sep) = projections False ps
    projections _ _ = Left "invalid deferred argument projection"

encodeJournal :: [Effect] -> String
encodeJournal es = unlines ["SOLJ2", show es, "COMMIT"]
decodeJournal :: String -> Maybe [Effect]
decodeJournal txt = case lines txt of
  version:body:"COMMIT":_ | version `elem` ["SOLJ1","SOLJ2"] -> readMaybe body
  _ -> Nothing
encodeDone :: Done -> String
encodeDone d = unlines ["SOLR2", show (IM.toList d), "COMMIT"]
decodeDone :: String -> Either String Done
decodeDone txt = case lines txt of
  ["SOLR2",body,"COMMIT"] | Just xs <- readMaybe body -> Right (IM.fromList xs)
  [] -> Right IM.empty
  ls | all (not . null) ls, Just ns <- traverse readMaybe ls -> Right (IM.fromList [(n,Right (TextCapture "")) | n <- ns])
  _ -> Left "corrupt Sol completion journal"
encodeUndo :: UndoRecord -> String
encodeUndo u = unlines ["SOLUNDO1",show u,"COMMIT"]
decodeUndo :: String -> Maybe UndoRecord
decodeUndo txt = case lines txt of ["SOLUNDO1",body,"COMMIT"] -> readMaybe body; _ -> Nothing
