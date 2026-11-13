# Export the RV64 timer and doorbell entry points used by the scheduler.
build compiler source target =
  exports = "ipiSend:hal_ipi_send,ipiClear:hal_ipi_clear,mtime:hal_mtime,timerPark:hal_timer_park,timerArm:hal_timer_arm";
  argv = [compiler,"--profile=bare-metal-builtin","--arc","--raw","--lib","--export={exports}",source,target];
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec argv "" [] "" 0));
  if status == 0 then Unit else error "compiling {source}: {out}{err}".
> case args Unit of [compiler,source,target] -> build compiler source target
  | _ -> error "usage: build-clint COMPILER SOURCE TARGET".
