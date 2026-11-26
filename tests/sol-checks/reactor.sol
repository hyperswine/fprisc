# Descriptor waits off the harts (runtime/actors.c fpr_io_wait, the epoll
# reactor in machine/posix/os_io.c): each program in tests/reactor reads its
# stdin from a slow writer through a pipe and must print its line. Linux only;
# elsewhere a read still waits in the kernel and iowait would print
# "first 1006 then 1".
H = use "helpers".
build root work env name = ProcessResult c o e = H.call ["{root}/fpr","build","{root}/tests/reactor/{name}.fpr","-o","{work}/{name}"] env 300000;
  if c == 0 then "{work}/{name}" else error "build {name}: {o}{e}".
piped env writer reader millis =
  pipe = PipelineSpec [ProcessSpec [writer] "" env "" 0, ProcessSpec [reader] "" env "" 0] (PipeBytes (Bytes.empty Unit)) (PipeCapture 65536) (PipeCapture 65536) millis PipeFail;
  case Proc.start pipe of
    Err why -> error "start {reader}: {why}"
  | Ok job -> (case Proc.wait job of
      Ok (PipelineResult code _ out errs) -> (code, H.text out, Str.join "" (List.map H.text errs))
    | Err why -> error "wait {reader}: {why}").
expect env writer reader want =
  (code, out, err) = piped env writer reader 60000;
  if code == 0 and out == want then print "reactor: {Str.trim out}" else error "{reader}: exit {code}, stdout={out}, stderr={err}, want {want}".
>! root = H.root Unit; work = tempDir "fpr-reactor";
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  delay = build root work env "delay"; drip = build root work env "drip";
  iowait = build root work env "iowait"; iokill = build root work env "iokill"; ioloop = build root work env "ioloop";
  _ = expect env delay iowait "iowait: first 1 then 1006\n";
  _ = expect env delay iokill "iokill: 1006\n";
  _ = expect env drip ioloop "ioloop: 1001742\n";
  print "reactor: a parked read leaves its hart to the other actors: PASS".
