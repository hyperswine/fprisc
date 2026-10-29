#!/usr/bin/env python3
"""Measure Sol REPL startup and prompt round trips with validated output.

Uses real PTYs, isolated caches and GPU-disabled/default-JIT settings.
The before compiler is required; save it before rebuilding. No user files or
external effects are used. --output must be fresh. Raw samples and transcripts
are retained there. The library comparison uses the current compiler in both
modes because older REPL versions lose imported aliases between commands.
"""
import argparse,hashlib,json,os,platform,pty,select,statistics,subprocess,termios,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--before',type=Path,required=True)
ap.add_argument('--before-revision',default='unspecified')
ap.add_argument('--after',type=Path,default=ROOT/'fpr')
ap.add_argument('--output',type=Path,required=True)
args=ap.parse_args()
BEFORE=args.before.resolve();AFTER=args.after.resolve();OUT=args.output.resolve()
if not BEFORE.is_file() or not AFTER.is_file():ap.error('both compiler executables must exist')
OUT.mkdir(parents=True,exist_ok=False)
ROWS=[]
BASE={k:v for k,v in os.environ.items() if not k.startswith(('SOL_','FPR_','GHCRTS'))}
BASE.update(FPR_HOME=str(ROOT),SOL_GPU='0')

def env_for(cache, extra=None):
    return dict(BASE,SOL_CACHE_DIR=str(cache),**(extra or {}))

def save():
    (OUT/'samples.json').write_text(json.dumps(ROWS,indent=2)+'\n')

def add(row):
    ROWS.append(row);save();print(row['name'],row.get('medianMs',row.get('meanMs')),flush=True)

def stats(values):
    s=sorted(values)
    return dict(samplesMs=values,medianMs=statistics.median(s),p95Ms=s[min(len(s)-1,int(.95*len(s)))],minMs=min(s),maxMs=max(s))

class Session:
    def __init__(self,binary,cache,extra=None):
        self.master,slave=pty.openpty();attrs=termios.tcgetattr(slave);attrs[3]&=~termios.ECHO;termios.tcsetattr(slave,termios.TCSANOW,attrs)
        self.buffer=b'';self.trace=[];t=time.perf_counter_ns()
        self.process=subprocess.Popen([str(binary),'sol','--repl'],cwd=OUT,env=env_for(cache,extra),stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        os.close(slave);self.read_prompt();self.startupMs=(time.perf_counter_ns()-t)/1e6
    def read_prompt(self):
        deadline=time.monotonic()+30;token=b'sol> '
        while token not in self.buffer:
            left=deadline-time.monotonic()
            if left<=0:raise TimeoutError(self.buffer[-1500:])
            ready,_,_=select.select([self.master],[],[],left)
            if not ready:continue
            try:chunk=os.read(self.master,65536)
            except OSError as e:raise RuntimeError(f'PTY ended: {self.buffer[-1500:]!r}') from e
            if not chunk:raise RuntimeError(self.buffer)
            self.buffer+=chunk
        data,self.buffer=self.buffer.split(token,1);text=data.decode(errors='replace').replace('\r\n','\n');self.trace.append(text);return text
    def send(self,line,expected=None,error=False):
        data=(line+'\n').encode();t=time.perf_counter_ns()
        while data:
            n=os.write(self.master,data);data=data[n:]
        text=self.read_prompt();ms=(time.perf_counter_ns()-t)/1e6
        if error:
            assert expected in text,(line,text)
        else:
            assert not any(x in text for x in ('TYPE ERRORS','SOL PANIC','input rejected','unbound name','already defined this session')),(line,text)
            if expected is not None:assert text==expected,(line,text,expected)
        return ms
    def close(self):
        if self.process.poll() is None:
            os.write(self.master,b'\x04')
            try:self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:self.process.terminate();self.process.wait(timeout=5)
        code=self.process.returncode;os.close(self.master);assert code==0,code


def prompt_trials(version,binary):
    for state in ('fresh-cache','warm-cache'):
        samples=[];cache=OUT/f'cache-prompt-{version}-{state}'
        if state=='warm-cache':
            s=Session(binary,cache);s.close()
        for trial in range(5):
            actual=cache/str(trial) if state=='fresh-cache' else cache
            s=Session(binary,actual);samples.append(s.startupMs);s.close()
        add(dict(name=f'prompt-{version}-{state}',**stats(samples)))


def command_trials(name,binary,setup,command,expected,extra=None,count=50):
    cache=OUT/('cache-'+name);all_ms=[];startups=[];setup_ms=[];medians=[]
    for trial in range(3):
        s=Session(binary,cache,extra);startups.append(s.startupMs);total=0
        try:
            for line in setup:total+=s.send(line)
            sample=[s.send(command(i),expected(i)) for i in range(count)]
            all_ms+=sample;medians.append(statistics.median(sample));setup_ms.append(total)
            (OUT/f'{name}-{trial}.transcript.txt').write_text(''.join(s.trace))
        finally:s.close()
    add(dict(name=name,setupMs=setup_ms,promptMs=startups,sessionMediansMs=medians,**stats(all_ms)))


def pipe_and_process(version,binary):
    cache=OUT/('cache-pipe-'+version);per_cmd=[];proc_cmd=[]
    for trial in range(3):
        expected=''.join(f'tick {i}\n' for i in range(50));lines=''.join(f'> print "tick {i}".\n' for i in range(50))
        t=time.perf_counter_ns();p=subprocess.run([str(binary),'sol','--repl'],input=lines,text=True,cwd=OUT,env=env_for(cache),capture_output=True,timeout=120);elapsed=(time.perf_counter_ns()-t)/1e6
        assert p.returncode==0 and p.stdout==expected and p.stderr=='',p
        per_cmd.append(elapsed/50)
        folder=OUT/f'distinct-{version}-{trial}';folder.mkdir();scripts=[]
        for i in range(50):
            path=folder/f'{i}.sol';value=f'tick {i} trial {trial}';path.write_text(f'> print "{value}".\n');scripts.append((path,value+'\n'))
        t=time.perf_counter_ns()
        for path,value in scripts:
            p=subprocess.run([str(binary),'sol',str(path)],text=True,cwd=OUT,env=env_for(cache),capture_output=True,timeout=30)
            assert p.returncode==0 and p.stdout==value and p.stderr=='',p
        proc_cmd.append((time.perf_counter_ns()-t)/1e6/50)
    add(dict(name=f'piped-{version}-per-command-including-startup',commandsPerRun=50,**stats(per_cmd)))
    add(dict(name=f'distinct-process-{version}-per-command',commandsPerRun=50,**stats(proc_cmd)))


def main():
    assert not (OUT/'samples.json').exists(),'use a new output directory for another run'
    meta=dict(head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),before={'head':args.before_revision,'compilerSha256':hashlib.sha256(BEFORE.read_bytes()).hexdigest()},compilerSha256=hashlib.sha256(AFTER.read_bytes()).hexdigest(),machine=platform.platform(),options={'SOL_GPU':'0','SOL_JIT':'default','SOL_CACHE':'default'},method='PTY input echo disabled; write-to-next-prompt wall time; output validated; cache roots isolated; 3 sessions per command workload, 5 prompt trials')
    (OUT/'benchmark-metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
    for version,binary in (('before',BEFORE),('after',AFTER)):prompt_trials(version,binary)
    for version,binary in (('before',BEFORE),('after',AFTER)):
        command_trials('trivial-'+version,binary,[],lambda i:f'> print "tick {i}".',lambda i:f'tick {i}\n')
    command_trials('arithmetic-after',AFTER,[],lambda i:'> print (41 + 1).',lambda i:'42\n')
    imports=[f'J = use "{ROOT}/sol/lib/json". C = use "{ROOT}/sol/lib/csv".']
    cmd=lambda i:'> u = print (J.render (J.strs ["a", "b"])); print (C.render [["c", "d"]]).'
    expected=lambda i:'["a","b"]\nc,d\n\n'
    command_trials('json-csv-current-default',AFTER,imports,cmd,expected,count=30)
    command_trials('json-csv-current-unsliced-control',AFTER,imports,cmd,expected,{'SOL_LIB_INCREMENTAL':'0'},count=30)
    for count in (100,500):
        defs=[f'v{i} = {i}.' for i in range(count)];chunks=[' '.join(defs[i:i+50]) for i in range(0,len(defs),50)]
        command_trials(f'definitions-{count}',AFTER,chunks,lambda i:f'> print (v{count-1} + 1).',lambda i:f'{count}\n',count=20)
    samples=[];recover=[];cache=OUT/'cache-errors'
    for trial in range(3):
        s=Session(AFTER,cache)
        try:
            for _ in range(5):
                samples.append(s.send('> print (1 + "x").','TYPE ERRORS',error=True));recover.append(s.send('> print "ok".','ok\n'))
        finally:s.close()
    add(dict(name='type-error-response',**stats(samples)));add(dict(name='recovery-after-type-error',**stats(recover)))
    for version,binary in (('before',BEFORE),('after',AFTER)):pipe_and_process(version,binary)
    print('REPL_BENCHMARK_PASSED',flush=True)
if __name__=='__main__':main()
