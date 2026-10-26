-- Mirrors runtime/vec_layout.h. Keep native readers and column kernels on one
-- descriptor contract; word fields follow the two uint32_t header fields.
module Compiler.VectorABI
  (vectorTypeId,intRep,floatRep,intKind,f64Kind,f32Kind,
   lengthOffset,columnCountOffset,kindsOffset,columnsOffset,columnBaseOffset) where
vectorTypeId,intRep,floatRep :: Int
vectorTypeId=9006
intRep=1
floatRep=4
intKind,f64Kind,f32Kind :: Integer
intKind=1
f64Kind=3
f32Kind=7
lengthOffset,columnCountOffset,kindsOffset,columnsOffset,columnBaseOffset :: Int -> Int
lengthOffset _=8
columnCountOffset w=8+3*w
kindsOffset w=8+4*w
columnsOffset w=8+5*w
columnBaseOffset w=w
