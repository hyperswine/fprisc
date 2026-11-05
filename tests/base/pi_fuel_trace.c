/* Trace only a freshly exec'd, single-hart test child. Stop before calling
 * a runtime boundary, or after returning to the captured ABI continuation.
 * Isolated short-window cases tighten that child's window without moving SP.
 */
#define _GNU_SOURCE
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <asm/ptrace.h>
#include <elf.h>
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stddef.h>
#include "fpr.h"

_Static_assert(offsetof(fpr_hart_t, fuel) == 0 && offsetof(fpr_hart_t, stk_lo) == 456 &&
               offsetof(fpr_hart_t, stk_span) == 464, "unexpected hart layout for linked ARM64 protocol");

static void die(const char *message) { perror(message); exit(1); }
static void check(int ok, const char *why) {
    if (!ok) { fprintf(stderr, "trace: %s\n", why); exit(1); }
}
static uint64_t number(const char *s) {
    char *end;
    errno = 0;
    unsigned long long value = strtoull(s, &end, 0);
    check(!errno && s[0] && s[0] != '-' && !*end, "bad unsigned argument");
    return value;
}
static uint64_t peek(pid_t tid, uint64_t address) {
    errno = 0;
    long value = ptrace(PTRACE_PEEKDATA, tid, (void *)(uintptr_t)address, 0);
    if (errno) die("read child");
    return (uint64_t)value;
}
static void poke(pid_t tid, int op, uint64_t addr, uint64_t value) {
    if (ptrace(op, tid, (void *)(uintptr_t)addr, (void *)(uintptr_t)value) < 0) die("write child");
}
static struct user_pt_regs regs(pid_t tid) {
    struct user_pt_regs r;
    struct iovec iov = { &r, sizeof(r) };
    if (ptrace(PTRACE_GETREGSET, tid, (void *)NT_PRSTATUS, &iov) < 0) die("child registers");
    check(iov.iov_len == sizeof(r),"incomplete ARM64 register set");
    return r;
}
static void resume(pid_t tid, int sig) {
    if (ptrace(PTRACE_CONT, tid, 0, (void *)(uintptr_t)sig) < 0 && errno != ESRCH) die("continue child");
}
int main(int argc, char **argv) {
    check(argc == 11,"expected executable, entry, grow, fuel, room, incoming fuel, arguments mode runtime stop, optional switch and queue entry");
    int capture = !strcmp(argv[7],"add") || !strcmp(argv[7],"overflow");
    check(capture || !strcmp(argv[7],"ordinary"),"unknown argument mode");
    uint64_t other = number(argv[8]), switch_pc=number(argv[9]), queue_pc=number(argv[10]);
    uint64_t entry = number(argv[2]), grow = number(argv[3]), exhaust = number(argv[4]);
    int live_room = !strcmp(argv[5],"live"), live_fuel = !strcmp(argv[6],"live");
    uint64_t room = live_room ? 0 : number(argv[5]), budget = live_fuel ? 0 : number(argv[6]);
    check(!(entry & 3) && !(grow & 3) && !(exhaust & 3),"unaligned code address");
    check(live_fuel || (budget && budget <= INT64_MAX),"invalid fuel");
    alarm(30);
    pid_t child = fork();
    if (child < 0) die("fork");
    if (child == 0) {
        setenv("FPR_HARTS","1",1);
        if (ptrace(PTRACE_TRACEME,0,0,0) < 0) die("trace own child");
        execl(argv[1],argv[1],(char *)0); die("exec child");
    }
    int status;
    check(waitpid(child,&status,0)==child && WIFSTOPPED(status) && WSTOPSIG(status)==SIGTRAP,"missing exec stop");
    if (ptrace(PTRACE_SETOPTIONS,child,0,(void *)(PTRACE_O_TRACECLONE|PTRACE_O_EXITKILL)) < 0) die("trace options");
    uint64_t aligned=entry & ~(uint64_t)7, shift=(entry & 4)*8;
    uint64_t original=peek(child,aligned);
    poke(child,PTRACE_POKETEXT,aligned,(original & ~(UINT64_C(0xffffffff)<<shift)) | (UINT64_C(0xd4200000)<<shift));
    resume(child,0);
    pid_t tid;
    struct user_pt_regs start;
    for (;;) {
        tid=waitpid(-1,&status,__WALL);
        if (tid<0) die("wait for entry");
        if (!WIFSTOPPED(status)) { check(tid!=child,"entry never reached"); continue; }
        int sig=WSTOPSIG(status);
        if ((status>>16)==PTRACE_EVENT_CLONE || sig==SIGSTOP) { resume(tid,0); continue; }
        if (sig==SIGTRAP) {
            start=regs(tid);
            check(start.pc==entry,"unexpected breakpoint");
            break;
        }
        resume(tid,sig);
    }
    poke(tid,PTRACE_POKETEXT,aligned,original);
    uint64_t hart=start.regs[28], lo=peek(tid,hart+offsetof(fpr_hart_t,stk_lo)), span=peek(tid,hart+offsetof(fpr_hart_t,stk_span));
    uint64_t old_fuel=peek(tid,hart);
    check(hart && !(start.sp & 15) && lo<=start.sp && start.sp-lo<span && span<=UINT64_MAX-lo,"invalid live stack window");
    check(old_fuel>0 && old_fuel<=INT64_MAX,"invalid live fuel");
    if (live_room) room=start.sp-lo;
    else {
        check(room<=start.sp-lo,"cannot enlarge the live window");
        uint64_t restricted=start.sp-room;
        poke(tid,PTRACE_POKEDATA,hart+offsetof(fpr_hart_t,stk_lo),restricted);
        poke(tid,PTRACE_POKEDATA,hart+offsetof(fpr_hart_t,stk_span),lo+span-restricted);
    }
    if (live_fuel) budget=old_fuel;
    else poke(tid,PTRACE_POKEDATA,hart,budget);
    if (!strcmp(argv[7],"overflow")) {
        /* These are tagged FP-RISC maxInt and 1. Stop before the real
         * runtime slow-add entry rather than executing a fabricated call. */
        check(other!=0,"missing overflow boundary");
        start.regs[0] = INT64_MAX; start.regs[2] = 3;
        struct iovec iov = { &start, sizeof(start) };
        if (ptrace(PTRACE_SETREGSET,tid,(void *)NT_PRSTATUS,&iov) < 0) die("set fixture operands");
    }
    if (capture) check((start.regs[0]&1) && (start.regs[2]&1),"fixture arguments are not tagged integers");
    size_t steps=0;
    struct user_pt_regs r=start;
    uint64_t lowest=start.sp;
    const char *outcome;
    for (;;) {
        if (other && r.pc==other) { outcome="other_runtime"; break; }
        if (r.pc==grow) { outcome="grow_runtime"; break; }
        if (r.pc==exhaust) { outcome="fuel_runtime"; break; }
        if (r.pc==start.regs[30] && r.sp==start.sp) {
            outcome="return";
            for (unsigned i=19; i<=29; ++i) check(r.regs[i]==start.regs[i],"damaged saved register");
            break;
        }
        check(steps<65536,"trace did not reach a boundary");
        if (ptrace(PTRACE_SINGLESTEP,tid,0,0)<0) die("single-step");
        check(waitpid(tid,&status,__WALL)==tid && WIFSTOPPED(status) && WSTOPSIG(status)==SIGTRAP,"unexpected signal on step");
        r=regs(tid);
        if (r.sp<lowest) lowest=r.sp;
        ++steps;
    }
    uint64_t final_fuel=peek(tid,hart);
    check(final_fuel<=budget,"unexpected fuel reset before boundary");
    size_t switch_steps=0, queue_visits=0;
    if (switch_pc) {
        check(queue_pc && live_room && live_fuel && r.pc==exhaust, "scheduler observation needs a natural fuel exhaustion");
        while (r.pc!=switch_pc) {
            if (r.pc==queue_pc) ++queue_visits;
            check(switch_steps<65536,"scheduler observation timeout");
            if (ptrace(PTRACE_SINGLESTEP,tid,0,0)<0) die("single-step scheduler");
            check(waitpid(tid,&status,__WALL)==tid && WIFSTOPPED(status) && WSTOPSIG(status)==SIGTRAP,"scheduler step failed");
            r=regs(tid); ++switch_steps;
        }
    }
    if (kill(child,SIGKILL)<0) die("stop test child");
    while ((tid=waitpid(-1,&status,__WALL))>0) if (WIFSTOPPED(status)) resume(tid,SIGKILL);
    check(errno==ECHILD,"child reaping failed");
    if (capture) printf("{\"x0\":%"PRIu64",\"x2\":%"PRIu64",",(uint64_t)start.regs[0],(uint64_t)start.regs[2]);
    else putchar('{');
    if (switch_pc) printf("\"observed_scheduler_instructions\":%zu,\"queue_entries\":%zu,",switch_steps,queue_visits);
    printf("\"outcome\":\"%s\",\"instructions\":%zu,\"stack_bytes\":%"PRIu64
           ",\"ticks\":%"PRIu64",\"window_bytes\":%"PRIu64",\"live_window_bytes\":%"PRIu64
           ",\"incoming_fuel\":%"PRIu64",\"live_fuel\":%"PRIu64"}\n",
           outcome,steps,(uint64_t)start.sp-lowest,budget-final_fuel,room,(uint64_t)start.sp-lo,budget,old_fuel);
    return 0;
}
