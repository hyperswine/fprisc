# The named SDRAM presets select a clock, XLEN and compressed instruction policy together.
setting name value preset = case unwrap (Env.get name) of
    EnvMissing -> unwrap (Env.set name value)
  | EnvText actual -> if actual == value then Unit else error "FPR_PRESET={preset} requires {name}={value} (got {actual})".
select preset =
  (mhz,rvc) = case preset of "fprisc-48" -> ("48","1") | "fprisc-72" -> ("72","1")
    | "fprisc-81" -> ("81","0") | "fprisc-84" -> ("84","0") | _ -> error "unknown FPR_PRESET: {preset}";
  _ = setting "FPR_XLEN" "32" preset;
  _ = setting "FPR_RVC" rvc preset;
  setting "FPR_CPU_MHZ" mhz preset.
apply u = case unwrap (Env.get "FPR_PRESET") of EnvMissing -> Unit | EnvText p -> if p == "" then Unit else select p.
value key = case unwrap (Env.get key) of EnvText v -> v | EnvMissing -> "".
> _ = apply Unit; print (Str.join " " (List.map value ["FPR_CPU_MHZ","FPR_XLEN","FPR_RVC"])).
