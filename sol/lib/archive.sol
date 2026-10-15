# Deferred native libarchive streaming. Bounds are application policy.
Limits = Type (Limits Int Int).
defaultLimits = Limits 100000 1073741824.
createWith (Limits entries bytes) source target =
  NativeArchive.afterCommit source target entries bytes.
create source target = createWith defaultLimits source target.
