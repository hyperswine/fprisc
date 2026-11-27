# One library for FP-RISC and Sol (docs/2026-11-27-SOL-STD-LIBRARIES.md): each
# file in tests/shared is ONE source, run natively and as a Sol script, and the
# two runs must print the same bytes and end with the same exit status.
# - jsondoc: std/jsondoc (it replaced sol/lib/json) parses, reshapes, renders
# - ui: a std/ui page lowers to the same std/view statics and stylesheet
# - test-exit: std/test (it replaced sol/lib/test) reports the same, and main's
#   Int is the exit status on both sides
H = use "helpers".
sameBothWays root work env name =
  src = "{root}/tests/shared/{name}.fpr";
  ProcessResult bc bo be = H.call ["{root}/fpr","build",src,"-o","{work}/{name}"] env 600000;
  _ = (if bc != 0 then error "{name}: native build failed\n{bo}{be}" else Unit);
  _ = unwrap (Proc.runNow (ProcessSpec ["cp",src,"{work}/{name}.sol"] "" [] "" 5000));
  ProcessResult nc no ne = H.call ["sh","-c","\"$1\" > \"$2\"; echo $?","sh","{work}/{name}","{work}/{name}.native"] env 120000;
  ProcessResult sc so se = H.call ["sh","-c","\"$1\" sol \"$2\" > \"$3\"; echo $?","sh","{root}/fpr","{work}/{name}.sol","{work}/{name}.sol.out"] env 300000;
  ProcessResult cc co ce = H.call ["cmp","{work}/{name}.native","{work}/{name}.sol.out"] [] 5000;
  _ = (if cc != 0 then error "{name}: native and Sol print different bytes\n{co}{ce}{se}" else Unit);
  _ = (if Str.trim no != Str.trim so then error "{name}: exit status native {Str.trim no}, Sol {Str.trim so}\n{se}" else Unit);
  Str.trim no.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-std-shared";
  env = [("FPR_HOME",root),("XDG_CACHE_HOME","{work}/cache")];
  codes = List.map (sameBothWays root work env) ["jsondoc","ui","test-exit"];
  _ = (if codes != ["0","0","1"] then error "std-shared: exit statuses {codes}, want 0 0 1" else Unit);
  print "std shared: std/jsondoc, std/ui and std/test, one source natively and in Sol, identical bytes and exit status PASS".
>! main Unit.
