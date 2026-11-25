-- StdDeprecations.hs — compatibility aliases for std modules renamed or
-- moved in the v0.15.0 stdlib consolidation (passes 1–3 on 24 Nov 2026,
-- plus the v1.0 Set removal).
--
-- An unpinned `use "std/bytes"` (and the other entries below) loads the
-- new module, rewrites imported names when they were prefixed to avoid
-- collisions, and prints a compile warning. The aliases are removed in
-- v0.17.0. Pinned uses (`use "std/bytes#hash"`) still resolve from the
-- .fpr store and are not rewritten.
--
-- Modules that left std entirely (appearance, pagination, …) are not in
-- this table: a deprecated copy stays in std/ with a `deprecated "…" .`
-- pragma, so an installed toolchain can still load them.
module StdDeprecations
  ( StdDeprecation (..),
    removalTarget,
    lookupStdDeprecation,
    normalizeStdSpec,
    deprecationWarning,
    retiredStdModuleMessage,
    isDeprecatedPragma,
    deprecatedPragmaReplacement,
    deprecatedPragmaNote,
  )
where

import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (listToMaybe)

data StdDeprecation = StdDeprecation
  { depOld :: String, -- "std/bytes"
    depNew :: String, -- "std/binary"
    depRenames :: [(String, String)] -- old export -> new export, only when different
  }

removalTarget :: String
removalTarget = "v0.17.0"

-- Strip a trailing .fpr so "std/bytes.fpr" and "std/bytes" share an entry.
normalizeStdSpec :: String -> String
normalizeStdSpec nm
  | ".fpr" `isSuffixOf` nm = take (length nm - 4) nm
  | otherwise = nm

lookupStdDeprecation :: String -> Maybe StdDeprecation
lookupStdDeprecation nm =
  listToMaybe [d | d <- stdDeprecations, depOld d == normalizeStdSpec nm]

deprecationWarning :: StdDeprecation -> String
deprecationWarning d =
  "warning: \""
    ++ depOld d
    ++ "\" is deprecated; use \""
    ++ depNew d
    ++ "\" instead (removed in "
    ++ removalTarget
    ++ ")"

-- Modules removed with no replacement. Only exact std/ paths, so a
-- user-local set.fpr is not intercepted.
retiredStdModuleMessage :: String -> Maybe String
retiredStdModuleMessage nm =
  case normalizeStdSpec nm of
    "std/set" ->
      Just
        ( "use: \"std/set\" was removed in v0.15.0 \
          \(the v1.0 spec removed the Set type). There is no compatibility alias."
        )
    _ -> Nothing

isDeprecatedPragma :: String -> Bool
isDeprecatedPragma n = "$deprecated:" `isPrefixOf` n

deprecatedPragmaReplacement :: String -> Maybe String
deprecatedPragmaReplacement n
  | isDeprecatedPragma n = Just (drop (length "$deprecated:") n)
  | otherwise = Nothing

deprecatedPragmaNote :: String -> [String] -> [String]
deprecatedPragmaNote usedNam pragmas =
  [ "warning: \""
      ++ normalizeStdSpec usedNam
      ++ "\" is deprecated; use \""
      ++ repl
      ++ "\" instead (removed in "
      ++ removalTarget
      ++ ")"
    | p <- pragmas,
      Just repl <- [deprecatedPragmaReplacement p]
  ]

-- ---------------------------------------------------------------------------
-- The table. dest is the module that absorbed the old file. Renames are
-- required whenever the old name still exists on the destination with a
-- *different* meaning, or was prefixed when the modules were merged.
-- ---------------------------------------------------------------------------

stdDeprecations :: [StdDeprecation]
stdDeprecations =
  -- pass 3: merge bytes / dir / native / ble / wifi / viewcache
  [ StdDeprecation "std/bytes" "std/binary" [],
    StdDeprecation "std/dir" "std/file" [],
    StdDeprecation "std/native" "std/reload" nativeRenames,
    StdDeprecation "std/ble" "std/esp" bleRenames,
    StdDeprecation "std/wifi" "std/esp" wifiRenames,
    StdDeprecation "std/viewcache" "std/view" viewcacheRenames,
    -- pass 2: merge log / durable
    StdDeprecation "std/logfile" "std/log" [],
    StdDeprecation "std/durable" "std/live" durableRenames,
    -- pass 1: os, transport, http, mqtt, browser
    StdDeprecation "std/osnet" "std/os" [],
    StdDeprecation "std/osio" "std/os" [],
    StdDeprecation "std/osfs" "std/os" [],
    StdDeprecation "std/oswatch" "std/os" [],
    StdDeprecation "std/osconnection" "std/os" osconnectionRenames,
    StdDeprecation "std/httpclient" "std/http" [],
    StdDeprecation "std/httpcore" "std/http" [],
    StdDeprecation "std/mqttclient" "std/mqtt" [],
    StdDeprecation "std/mqttsession" "std/mqtt" [],
    StdDeprecation "std/ownedmqtt" "std/mqtt" ownedmqttRenames,
    StdDeprecation "std/resolver" "std/transport" resolverRenames,
    StdDeprecation "std/sockettransport" "std/transport" socketRenames,
    StdDeprecation "std/connect" "std/transport" [],
    StdDeprecation "std/watchedtransport" "std/transport" watchedRenames,
    StdDeprecation "std/browserautocomplete" "std/browser" autocompleteRenames,
    StdDeprecation "std/browsercalc" "std/browser" [],
    StdDeprecation "std/browserconsole" "std/browser" consoleRenames,
    StdDeprecation "std/browserfeedback" "std/browser" feedbackRenames,
    StdDeprecation "std/browserformfill" "std/browser" formfillRenames,
    StdDeprecation "std/browsermedia" "std/browser" mediaRenames,
    StdDeprecation "std/browserstorage" "std/browser" storageRenames,
    StdDeprecation "std/livemetrics" "std/browser" metricsRenames,
    StdDeprecation "std/livenotice" "std/browser" noticeRenames
  ]

nativeRenames =
  [ ("attach", "nativeAttach"),
    ("loadAt", "nativeLoadAt"),
    ("loadVersionAt", "nativeLoadVersionAt")
  ]

bleRenames =
  [ ("scan", "bleScan"),
    ("advertise", "bleAdvertise")
  ]

wifiRenames =
  [ ("info", "wifiInfo"),
    ("scan", "wifiScan"),
    ("startAp", "wifiStartAp"),
    ("stations", "wifiStations"),
    ("stop", "wifiStop")
  ]

viewcacheRenames =
  [ ("Output", "CacheOutput"),
    ("empty", "cacheEmpty"),
    ("begin", "cacheBegin"),
    ("output", "cacheOutput"),
    ("fragment", "cacheFragment"),
    ("item", "cacheItem"),
    ("fresh", "cacheFresh"),
    ("many", "cacheMany"),
    ("manyGo", "cacheManyGo"),
    ("finish", "cacheFinish"),
    ("retain", "cacheRetain"),
    ("stats", "cacheStats"),
    ("size", "cacheSize")
  ]

durableRenames =
  [ ("Store", "DurableStore"),
    ("open", "durableOpen"),
    ("save", "durableSave"),
    ("close", "durableClose"),
    ("log", "durableLog")
  ]

osconnectionRenames =
  [ ("adopt", "connAdopt"),
    ("begin", "connBegin"),
    ("fd", "connFd"),
    ("status", "connStatus"),
    ("read", "connRead"),
    ("write", "connWrite"),
    ("close", "connClose")
  ]

ownedmqttRenames =
  [ ("create", "ownedCreate"),
    ("begin", "ownedBegin"),
    ("next", "ownedNext"),
    ("subscribe", "ownedSubscribe"),
    ("publish", "ownedPublish"),
    ("takeNotices", "ownedTakeNotices"),
    ("phase", "ownedPhase"),
    ("close", "ownedClose"),
    ("stop", "ownedStop")
  ]

resolverRenames =
  [ ("create", "resolverCreate"),
    ("close", "resolverClose"),
    ("gate", "resolverGate"),
    ("nap", "resolverNap")
  ]

socketRenames =
  [ ("failure", "socketFailure"),
    ("handle", "socketHandle"),
    ("valid", "socketValid"),
    ("readNow", "socketReadNow"),
    ("writeNow", "socketWriteNow"),
    ("waitNow", "socketWaitNow"),
    ("release", "socketRelease"),
    ("now", "socketNow")
  ]

watchedRenames =
  [ ("failure", "watchFailure"),
    ("wait", "watchWait")
  ]

autocompleteRenames =
  [ ("src", "autocomplete"),
    ("scope", "autocompleteScope"),
    ("from", "autocompleteFrom"),
    ("prototypes", "autocompletePrototypes"),
    ("reset", "autocompleteReset"),
    ("onPointerDown", "autocompleteOnPointerDown")
  ]

consoleRenames =
  [ ("script", "console"),
    ("remembered", "consoleRemembered"),
    ("recallIndex", "consoleRecallIndex"),
    ("remember", "consoleRemember")
  ]

feedbackRenames =
  [ ("src", "feedback"),
    ("theme", "feedbackTheme"),
    ("prototypes", "feedbackPrototypes"),
    ("onPointerDown", "feedbackOnPointerDown")
  ]

formfillRenames =
  [ ("src", "formFill")
  ]

mediaRenames =
  [ ("program", "media"),
    ("programWithRetry", "mediaWithRetry"),
    ("programWithReconnect", "mediaWithReconnect"),
    ("active", "mediaActive"),
    ("evaluate", "mediaEvaluate"),
    ("phase", "mediaPhase"),
    ("message", "mediaMessage")
  ]

storageRenames =
  [ ("script", "storage")
  ]

metricsRenames =
  [ ("script", "metrics"),
    ("milliseconds", "metricsMilliseconds"),
    ("ms", "metricsMs"),
    ("summary", "metricsSummary"),
    ("initial", "metricsInitial"),
    ("sent", "metricsSent"),
    ("reset", "metricsReset"),
    ("frame", "metricsFrame")
  ]

noticeRenames =
  [ ("init", "noticeInit"),
    ("pending", "noticePending"),
    ("adopted", "noticeAdopted"),
    ("adoptedAt", "noticeAdoptedAt"),
    ("tick", "noticeTick"),
    ("expireAt", "noticeExpireAt"),
    ("view", "noticeView"),
    ("appearance", "noticeAppearance"),
    ("styles", "noticeStyles")
  ]
