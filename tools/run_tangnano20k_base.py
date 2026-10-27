#!/usr/bin/env python3
"""Run a Base RV32/RV64 image and serve an explicit rooted UART virtual device.

Requires the extended Q/V/H/T boot loader, including the RV32 SDRAM ROM.
"""
import argparse, math, re, functools, operator, os, select, struct, sys, termios, time
from pathlib import Path
from run_simple_risc import open_port
SIMPLE_RISC_ROOT = Path(os.environ.get('SIMPLE_RISC_ROOT', Path(__file__).resolve().parents[2] / 'simple-risc'))
sys.path.insert(0, str(SIMPLE_RISC_ROOT / 'boards/tangnano20k'))
import rom_protocol
MAX_PAYLOAD=1024*1024
MAX_ARGS=256
MAX_ARGS_BYTES=65536
PREFIX=b'@FPR1 '
def encode_args(args):
    if len(args)>MAX_ARGS:raise ValueError('at most 256 program arguments')
    payload=bytearray(struct.pack('<I',len(args)))
    for arg in args:
        if '\0' in arg:raise ValueError('program argument contains NUL')
        data=arg.encode('utf-8')
        if len(data)>MAX_ARGS_BYTES-len(payload)-4:raise ValueError('program arguments exceed 65536 encoded bytes')
        payload.extend(struct.pack('<I',len(data)));payload.extend(data)
    return bytes(payload)
def checksum(data):return functools.reduce(operator.xor,data,0)
def frame(seq,code,payload):
    if not 0<seq<=0xffffffff or not 0<=code<=255 or len(payload)>MAX_PAYLOAD:raise ValueError('frame bounds')
    return PREFIX+f'{seq:08x} {code:02x} {len(payload):08x} '.encode()+payload.hex().encode()+f' {checksum(payload):02x}\n'.encode()
def parse(line):
    parts=line.removesuffix(b'\n').split(b' ')
    if len(parts)!=6 or parts[0]!=b'@FPR1' or list(map(len,parts[1:4]))!=[8,2,8] or len(parts[5])!=2:raise ValueError('malformed RPC header')
    if any(re.fullmatch(b'[0-9a-f]+',part) is None for part in parts[1:4]+parts[5:]):raise ValueError('RPC hex')
    seq,op,n=(int(x,16) for x in parts[1:4])
    if n>MAX_PAYLOAD or len(parts[4])!=n*2:raise ValueError('RPC length')
    data=bytes.fromhex(parts[4].decode('ascii'))
    if checksum(data)!=int(parts[5],16):raise ValueError('RPC checksum')
    if seq==0:raise ValueError('RPC sequence')
    return seq,op,data
class Device:
    def __init__(self,root,env=None,lines=None,args=None):
        self.root=Path(root).resolve();self.env=env or {};self.lines=iter(lines or [])
        self.args=encode_args(args or [])
    def path(self,data):
        name=data.decode('utf-8')
        if '\0' in name or Path(name).is_absolute():raise ValueError('virtual path must be relative')
        path=(self.root/name).resolve()
        if not path.is_relative_to(self.root):raise ValueError('virtual path escapes root')
        return path
    def dispatch(self,op,data):
        try:
            if op==1:
                p=self.path(data)
                with p.open('rb') as f:value=f.read(MAX_PAYLOAD+1)
            elif op==2:value=b'1' if self.path(data).exists() else b'0'
            elif op in (3,4):
                name,sep,contents=data.partition(b'\0')
                if not sep:raise ValueError('write request has no path separator')
                with self.path(name).open('wb' if op==3 else 'ab') as f:f.write(contents)
                value=b''
            elif op==5:
                name=data.decode('utf-8')
                if name not in self.env:return 1,b'unset'
                value=self.env[name].encode()
            elif op==6:
                if data:raise ValueError('clock payload must be empty')
                value=str(time.monotonic_ns()//1000).encode()
            elif op==8:
                if data:raise ValueError('input payload must be empty')
                try:value=next(self.lines).encode()
                except StopIteration:return 1,b'eof'
            elif op==9:
                if data:raise ValueError('arguments payload must be empty')
                value=self.args
            else:return 1,b'virtual operation unavailable'
            if len(value)>MAX_PAYLOAD:return 1,b'virtual reply too large'
            return 0,value
        except (OSError,ValueError,UnicodeError) as e:return 1,str(e).encode()[:4096]
def send(fd,data):
    view=memoryview(data)
    while view:
        _,w,_=select.select([], [fd],[],1)
        if not w:continue
        try:n=os.write(fd,view[:4096]);view=view[n:]
        except BlockingIOError:pass
    termios.tcdrain(fd)
def response(fd,data):
    # Stop-and-wait per byte protects the hardware's one-byte receiver even
    # while the guest allocates the reply or parses its header.
    for byte in data:
        send(fd,bytes([byte]));end=time.monotonic()+5
        while time.monotonic()<end:
            if select.select([fd],[],[],.05)[0]:
                ack=os.read(fd,1)
                if ack!=b'+':raise ValueError(f'virtual device expected ACK, got {ack!r}')
                break
        else:raise TimeoutError('virtual device ACK timeout')
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('image',type=Path,nargs='?');p.add_argument('--root',type=Path,default=Path.cwd())
    p.add_argument('--port',default='/dev/cu.usbserial-20250303171');p.add_argument('--freq-mhz',type=float,default=27)
    p.add_argument('--timeout',type=float,default=120);p.add_argument('--probe',action='store_true')
    p.add_argument('--identify',action='store_true',help="query board identity ('I') and verify compatibility")
    p.add_argument('--manifest',type=Path,help='verify board identity against a preset build-manifest.json')
    p.add_argument('--protocol',choices=('u','q'),default='u',help="upload protocol: 'u' (I+U+C+G) or legacy 'q' (Q+V+H)")
    p.add_argument('--env',action='append',default=[]);p.add_argument('--input',action='append',default=[])
    p.add_argument('--arg',action='append',default=[],help='program argument; use --arg=-x for a leading dash; repeat in order')
    a=p.parse_args()
    if not a.probe and not a.identify and not a.image:p.error('image required')
    if not math.isfinite(a.freq_mhz) or a.freq_mhz<=0 or not math.isfinite(a.timeout) or a.timeout<=0:p.error('clock and timeout must be finite and positive')
    if any('=' not in e for e in a.env):p.error('--env requires NAME=value')
    try:device=Device(a.root,dict(e.split('=',1) for e in a.env),a.input,a.arg)
    except (ValueError,UnicodeError) as e:p.error(str(e))
    image=b'' if (a.probe or (a.identify and not a.image)) else a.image.read_bytes()
    if a.image and not 0<len(image)<=2*1024*1024:p.error('image must contain 1..2 MiB')
    port=rom_protocol.discover_port(a.port)
    fd=open_port(port,round(a.freq_mhz*1e6/868));started=False
    try:
        if a.probe and not a.identify and not a.manifest:
            send(fd,b'T');end=time.monotonic()+3;data=b''
            while time.monotonic()<end and not data.endswith(b'DONE'):
                if select.select([fd],[],[],.05)[0]:data+=os.read(fd,4096)
            if data!=b'DONE':raise TimeoutError(f'board diagnostic failed: {data!r}')
            print('PASS: board UART diagnostic');return
        initial=b''
        if a.identify or a.manifest or a.protocol=='u':
            ident=rom_protocol.query_identity(fd,expected_mhz=a.freq_mhz)
            rom_protocol.check_compatibility(
                ident,
                expected_cpu_mhz=round(a.freq_mhz),
                image_bytes=len(image) if a.image else None,
                required_caps='UICG' if a.protocol=='u' else 'QVHT',
                manifest=a.manifest,
            )
            if (a.identify or a.probe) and not a.image:
                print(ident.raw)
                return
        if a.protocol=='u':
            upload_timeout=max(15.0,len(image)*8680/(a.freq_mhz*1e6)+5.0)
            rom_protocol.upload_image_u(fd,image,max_words=ident.max_bytes//4,timeout=upload_timeout)
            initial=rom_protocol.start_guarded(fd);started=True
        else:
            image+=b'\0'*(-len(image)%4)
            send(fd,b'Q'+struct.pack('<I',len(image)//4)+image+b'V')
            expected=0
            for i in range(0,len(image),4):expected^=int.from_bytes(image[i:i+4],'little')
            verify=b'';verify_end=time.monotonic()+15
            while len(verify)<9 and time.monotonic()<verify_end:
                if select.select([fd],[],[],.05)[0]:verify+=os.read(fd,9-len(verify))
            if verify!=f'{expected:08x}\n'.encode():raise ValueError(f'image readback mismatch: {verify!r}, expected {expected:08x}')
            send(fd,b'H');started=True
        end=time.monotonic()+a.timeout;buffer=initial;output=b'';sequence=0
        while time.monotonic()<end:
            if not buffer and not select.select([fd],[],[],.05)[0]:continue
            if select.select([fd],[],[],0)[0]:
                buffer+=os.read(fd,4096)
            if len(buffer)>2*MAX_PAYLOAD+128:raise ValueError('oversized guest frame')
            while b'\n' in buffer:
                line,buffer=buffer.split(b'\n',1);line+=b'\n'
                if line.startswith(PREFIX):
                    seq,op,payload=parse(line)
                    if seq!=sequence+1:raise ValueError('guest sequence out of order')
                    sequence=seq;status,reply=device.dispatch(op,payload)
                    response(fd,frame(seq,status,reply))
                else:output+=line;sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
            if buffer.endswith(b'DONE'):
                output+=buffer;sys.stdout.buffer.write(buffer+b'\n');sys.stdout.buffer.flush()
                if b'FPR EXIT 0\n' not in output:raise ValueError('CPU halted without successful runtime exit')
                return
            if not select.select([fd],[],[],.05)[0]:continue
            buffer+=os.read(fd,4096)
        raise TimeoutError(f'no successful exit; pending={buffer[:80]!r}')
    except BaseException:
        if started:
            send(fd,b'\x03');time.sleep(.2)
        raise
    finally:os.close(fd)
if __name__=='__main__':main()
