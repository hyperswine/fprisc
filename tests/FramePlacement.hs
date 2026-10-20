import Codegen (compactFrameSlots, rv64)
import Control.Monad (unless)

main :: IO ()
main = do
  let pro = ["    addi sp, sp, -96", "    sd ra, 88(sp)",
             "    sd s0, 80(sp)", "    addi s0, sp, 96"]
      epilogue = ["    ld ra, -8(s0)", "    mv t0, s0",
                  "    ld s1, -80(s0)", "    ld s0, -16(s0)",
                  "    mv sp, t0", "    ret"]
      body = ["    sd s1, -80(s0)", "    sd a0, -56(s0)",
              "    call fpr_fuel_exhausted", "    ld a0, -56(s0)"] ++ epilogue
      actual = compactFrameSlots rv64 96 (pro ++ body)
      expected = ["    addi sp, sp, -32", "    sd ra, 24(sp)",
                  "    sd s0, 16(sp)", "    addi s0, sp, 32",
                  "    sd s1, -32(s0)", "    sd a0, -24(s0)",
                  "    call fpr_fuel_exhausted", "    ld a0, -24(s0)",
                  "    ld ra, -8(s0)", "    mv t0, s0",
                  "    ld s1, -32(s0)", "    ld s0, -16(s0)",
                  "    mv sp, t0", "    ret"]
  unless (actual == expected) $ error ("compaction mismatch: " ++ show actual)
  -- These frames may expose addresses or use another layout: reject them.
  mapM_ (\extra -> let input = pro ++ extra ++ body in
    unless (compactFrameSlots rv64 96 input == input) $
      error ("unsafe frame accepted: " ++ show extra))
    [ ["    mv a0, s0"], ["    add t2, s0, t2"],
      ["    addi a0, s0, -56"], ["    sd s0, -32(s0)"],
      ["    ld a0, -104(s0)"], ["    ld a0, 0(s0)"] ]
  unless (compactFrameSlots rv64 4096 (pro ++ body) == pro ++ body) $
    error "deep frame changed"
  putStrLn "Frame compaction: preserved values/register saves, dense layout, escaping/computed/deep frame fallback PASS"
