C = use "qualification-compile".
showNames names = _ = List.map print names; Unit.
> case args Unit of
    root :: source :: exe :: cross :: driver :: probe :: hal :: "pi-image" :: expectations -> showNames (C.buildChecked [] root source exe cross driver probe hal True expectations)
  | [root,source,exe,cross,driver,probe,hal] -> showNames (C.buildChecked [] root source exe cross driver probe hal False [])
  | _ -> error "usage: pi-qualification-compile ROOT SOURCE EXE MODE CC PROBE HAL [pi-image]".
