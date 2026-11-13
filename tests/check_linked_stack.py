#!/usr/bin/env python3
"""Final-image stack proofs: encoded control flow, refusals and C runtime traces."""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check_linked_stack import prove, parse_entries, Image
from tools.riscv_compressed import expand
from tools.linked_callback_work import callback_work

TARGET = dict(schema=1, target='linked-stack-fixture', elf_class_bits=64, ram_origin=0x80000000,
              ram_bytes=8*1024*1024, max_image_bytes=8*1024*1024-65536, min_free_bytes=65536)
MANIFEST = json.dumps(TARGET).encode()
ASM = '''
.option norvc
.text
.globl _start,leaf,root,tail,loop,cycle,dynamic,indirect,unbalanced,up,misaligned,join,frame,clobber,noreturn,panic_path
_start: j loop
leaf:
 addi sp,sp,-48
 sd ra,0(sp)
 ld ra,0(sp)
 addi sp,sp,48
 ret
root:
 addi sp,sp,-32
 sd ra,0(sp)
 call leaf
 ld ra,0(sp)
 addi sp,sp,32
 ret
tail:
 addi sp,sp,-64
 sd ra,0(sp)
 ld ra,0(sp)
 addi sp,sp,64
 j root
loop: j loop
cycle:
 addi sp,sp,-16
 sd ra,0(sp)
 call cycle
 ld ra,0(sp)
 addi sp,sp,16
 ret
dynamic: mv sp,a0
 ret
indirect: jr a0
unbalanced: addi sp,sp,-16
 ret
up: addi sp,sp,16
 ret
misaligned: addi sp,sp,-8
 ret
join:
 beq a0,zero,1f
 addi sp,sp,-16
1: j 1b
frame:
 li t0,-4096
 add sp,sp,t0
 sd ra,0(sp)
 li t0,4096
 add sp,sp,t0
 ret
clobber:
 addi sp,sp,-32
 sd ra,0(sp)
 li t0,32
 call leaf
 ld ra,0(sp)
 add sp,sp,t0
 ret
noreturn: j noreturn
panic_path:
 addi sp,sp,-16
 call noreturn
 .word 0
.globl mutual_a,mutual_b,may_return
mutual_a: j mutual_b
mutual_b: j mutual_a
may_return:
 beq a0,zero,1f
 addi sp,sp,-16
 sd ra,0(sp)
 call may_return
 ld ra,0(sp)
 addi sp,sp,16
1: ret
.globl same_depth,unresolved_join
same_depth:
 beq a0,zero,1f
 addi sp,sp,-16
 j 2f
1: addi sp,sp,-16
2: addi sp,sp,16
 ret
unresolved_join:
 beq a0,zero,1f
 la t0,leaf
 j 2f
1: la t0,root
2: jr t0
.globl lost_link,partial_link,clobbered_saved,escaped_write,twice
lost_link: call leaf
 ret
partial_link:
 addi sp,sp,-16
 sd ra,8(sp)
 sb zero,9(sp)
 ld ra,8(sp)
 addi sp,sp,16
 ret
clobbered_saved: li s3,7
 ret
escaped_write: sd zero,0(a0)
 ret
twice:
 addi sp,sp,-16
 sd ra,0(sp)
 call leaf
 call leaf
 ld ra,0(sp)
 addi sp,sp,16
 ret
.weak weak_entry
weak_entry: ret
'''


def run(command):
    p = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=180)
    assert p.returncode == 0, (command, p.stdout, p.stderr)
    return p.stdout


class LinkedStackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='fpr-linked-stack-unit-')
        cls.directory = Path(cls.temp.name)
        cls.images = []
        for compressed in (False, True):
            for relax in (False, True):
                cls.images.append(cls.build(ASM, f'fixture{relax}{compressed}', relax, compressed))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def build(cls, text, name, relax=False, compressed=False):
        source, image = cls.directory/(name+'.s'), cls.directory/(name+'.elf')
        source.write_text(text.replace('.option norvc','.option rvc') if compressed else text)
        run(['riscv64-unknown-elf-gcc','-ffixed-x27','-march=rv64imc' if compressed else '-march=rv64im','-mabi=lp64','-nostdlib',
             *([] if relax else ['-mno-relax','-Wl,--no-relax']),
             '-T', ROOT/'tests/typed_ir/kernel_link.ld',source,'-o',image])
        return image.read_bytes()

    def proof(self, data, name, limit=65536):
        return prove(data, MANIFEST, TARGET['target'], [(name, limit)])

    def test_callback_work_composes_real_calls_and_tail_transfers(self):
        for data in self.images:
            names = {n:n for n in ("root","leaf","tail")}
            report = callback_work(data,names,["root","tail","root","leaf"],100)
            costs = report["per_entry"]
            # AUIPC + JALR may relax to one JAL. An ordinary call charges
            # the continuation, and the tail transfer never duplicates it.
            self.assertEqual(costs["leaf"],5)
            self.assertIn(costs["root"],(11,12))
            self.assertEqual(costs["tail"],5+costs["root"])
            total=2*costs["root"]+costs["tail"]+costs["leaf"]
            self.assertEqual(report["required"],total)
            with self.assertRaisesRegex(ValueError,"instructions, limit"):
                callback_work(data,names,["root","tail","root","leaf"],total-1)
            for name in ("loop","cycle","mutual_a","may_return","panic_path"):
                with self.assertRaisesRegex(ValueError,"reachable cycle"):
                    callback_work(data,{name:name},[name],100000)
            doubled=callback_work(data,{"twice":"twice"},iter(["twice"]),100)
            self.assertIn(doubled["required"],(17,19))
            for name,reason in [("lost_link","return address"),("partial_link","return address"),
                                ("clobbered_saved","ABI register"),("escaped_write","outside proved frame"),
                                ("indirect","unresolved indirect"),("weak_entry","missing/weak"),("dynamic","dynamic stack")]:
                with self.assertRaisesRegex(ValueError,reason):
                    callback_work(data,{name:name},[name],100000)

    def test_calls_tail_transfers_frames_and_joins(self):
        for data in self.images:
            for name, expected in [('leaf',48),('root',80),('tail',80),('loop',0),('frame',4096),
                                   ('panic_path',16),('mutual_a',0),('same_depth',16)]:
                with self.subTest(name=name, image=hashlib.sha256(data).hexdigest()):
                    receipt = self.proof(data,name,max(expected,1))
                    self.assertEqual(receipt['entries'][0]['peak_bytes'],expected)
                    if expected:
                        with self.assertRaisesRegex(ValueError,'needs'):
                            self.proof(data,name,expected-1)

    def test_unknown_dynamic_and_invalid_control(self):
        for data in self.images:
            for name, message in [('cycle','retaining call cycle'),('may_return','retaining call cycle'),
                                  ('dynamic','dynamic stack'),('indirect','unresolved indirect'),
                                  ('unbalanced','unrestored'),('up','invalid stack'),
                                  ('misaligned','invalid stack'),('join','incompatible stack join'),
                                  ('clobber','dynamic stack'),('unresolved_join','unresolved indirect'),
                                  ('weak_entry','weak stack entry'),('missing','missing stack entry')]:
                with self.subTest(name=name):
                    with self.assertRaisesRegex(ValueError,message):
                        self.proof(data,name)

    def test_loaded_runtime_changes_the_bound(self):
        before = self.proof(self.images[0], 'root')
        # No function/signature/report names change. The actual linked callee
        # grows, so reusing an old assembly-comment bound would be unsound.
        changed = self.build(ASM.replace('sp,sp,-48','sp,sp,-96').replace('sp,sp,48','sp,sp,96'),'changed')
        after = self.proof(changed,'root')
        self.assertEqual(after['entries'][0]['peak_bytes'],128)
        self.assertNotEqual(before['image']['image_sha256'], after['image']['image_sha256'])
        with self.assertRaisesRegex(ValueError,'needs 128'):
            self.proof(changed,'root',80)

    def test_illegal_and_compressed_instructions(self):
        for word in ['0x00000000','0x00000073','0x0000202f','0x00007003']:
            image = self.build('.text\n.globl _start\n_start: .word '+word+'\n ret\n','invalid'+word)
            with self.assertRaises(ValueError):
                self.proof(image,'_start')

    def test_exhaustive_compressed_decoder_against_binutils(self):
        # Disassemble all 49,152 short encodings independently. Compare each
        # supported instruction's registers, immediates and branch destination
        # with the disassembly of its normalized base encoding at the same PC.
        # The oracle never extracts compressed operand bits itself.
        halves=[h for h in range(65536) if h & 3 != 3]
        expanded=[];accepted={}
        for index,h in enumerate(halves):
            try:
                w=expand(h);accepted[index*4]=h
            except ValueError:
                w=0x13
            expanded.append(struct.pack('<I',w))
        original=self.directory/'short.bin';normal=self.directory/'normal.bin'
        original.write_bytes(b''.join(struct.pack('<HH',h,1) for h in halves))
        normal.write_bytes(b''.join(expanded))
        def disassemble(path):
            output=run(['riscv64-unknown-elf-objdump','-D','-b','binary','-m','riscv:rv64','-M','no-aliases,numeric',path])
            return {int(m[1],16):(m[2],m[3].split('#')[0].strip())
                    for m in re.finditer(r'^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(\S+)\s*([^\n]*)$',output,re.M)}
        short,base=disassemble(original),disassemble(normal)
        def normalize(mnemonic, operands):
            return mnemonic,re.sub(r'(?<![\w])(-?(?:0x[0-9a-f]+|[0-9]+))',
                                   lambda m:str(int(m[0],16 if '0x' in m[0] else 10)),operands)
        def equivalent(mnemonic, operands):
            a=operands.split(',');name=mnemonic.removeprefix('c.')
            if name in ('lw','ld','sw','sd','lui'):pass
            elif name in ('lwsp','ldsp','swsp','sdsp'):name=name[:-2]
            elif name=='addi4spn':name='addi'
            elif name=='addi16sp':name='addi';a=[a[0],a[0],a[1]]
            elif name in ('addi','addiw','slli','srli','srai','andi','sub','xor','or','and','subw','addw','add'):
                a=[a[0],a[0],a[1]]
            elif name in ('slli64','srli64','srai64'):
                # Binutils uses the legacy RV128 mnemonic for the zero shift;
                # on RV64 these encodings are the architectural zero-shift HINT.
                name=name[:-2];a=[a[0],a[0],'0']
            elif name=='li':name='addi';a=[a[0],'x0',a[1]]
            elif name=='mv':name='add';a=[a[0],'x0',a[1]]
            elif name=='j':name='jal';a=['x0',a[0]]
            elif name in ('jr','jalr'):
                a=['x0' if name=='jr' else 'x1','0('+a[0]+')'];name='jalr'
            elif name in ('beqz','bnez'):name=name[:-1];a=[a[0],'x0',a[1]]
            else:raise AssertionError((mnemonic,operands))
            return normalize(name,','.join(a))
        for pc,h in accepted.items():
            self.assertEqual(normalize(*base[pc]),equivalent(*short[pc]),hex(h))
        self.assertEqual(len(accepted),38550)
        for h in (0,0x2001,0x6101,0x6001,0x4002,0x6002,0x8002,0x9002,0x9c41,0x9c61):
            with self.assertRaises(ValueError):expand(h)
        for invalid in (-1,65536,True,3):
            with self.assertRaises(ValueError):expand(invalid)

    def test_mixed_width_alignment_and_truncated_fetch(self):
        # A full-width instruction at an address congruent to two modulo four
        # is legal with RVC; the final compressed return needs only two bytes.
        data=self.build('.option rvc\n.text\n.globl _start\n_start:\n c.nop\n'
                        ' .4byte 0xff010113\n .4byte 0x01010113\n c.jr ra\n','mixed',compressed=True)
        image=Image(data)
        self.assertEqual(image.instruction(image.symbols['_start'][0]+2)[1],4)
        self.assertEqual(self.proof(data,'_start',16)['entries'][0]['peak_bytes'],16)
        changed=bytearray(data);struct.pack_into('<I',changed,48,0)  # Remove EF_RISCV_RVC.
        with self.assertRaisesRegex(ValueError,'without ELF RVC flag'):self.proof(bytes(changed),'_start')
        for body,reason in [('.2byte 0x0013','truncated instruction'),('.2byte 0x001f','instruction length')]:
            image=self.build('.option rvc\n.text\n.globl _start\n_start: '+body+'\n','truncated'+str(len(body)),compressed=True)
            with self.assertRaisesRegex(ValueError,reason):self.proof(image,'_start')

    def test_compressed_call_continuation_is_two_bytes(self):
        data=self.build('.option rvc\n.text\n.globl _start\n_start:\n'
                        ' c.addi sp,-16\n c.sdsp ra,0(sp)\n la t0,leaf\n c.jalr t0\n'
                        ' c.addi sp,-16\n c.addi sp,16\n c.ldsp ra,0(sp)\n c.addi sp,16\n c.jr ra\n'
                        'leaf: c.addi16sp sp,-48\n c.addi16sp sp,48\n c.jr ra\n','shortcall',compressed=True)
        self.assertEqual(self.proof(data,'_start',64)['entries'][0]['peak_bytes'],64)

    def test_rv64_zero_shift_hints_preserve_frame_evidence(self):
        data=self.build('.option rvc\n.text\n.globl _start\n_start:\n'
                        ' .2byte 0x0102\n c.addi sp,-16\n c.sdsp s0,0(sp)\n c.addi4spn s0,sp,16\n'
                        ' .2byte 0x8001\n .2byte 0x8401\n mv t0,s0\n c.ldsp s0,0(sp)\n mv sp,t0\n ret\n',
                        'hints',compressed=True)
        self.assertEqual(self.proof(data,'_start',16)['entries'][0]['peak_bytes'],16)

    def test_execution_oracle_detects_omitted_paths(self):
        from linked_stack_probe import qualify
        path=self.directory/'oracle.elf';path.write_bytes(self.images[0])
        image=Image(self.images[0])
        entry=image.symbols['root'][0];omitted=image.symbols['loop'][0]
        def execute(command, **_):
            # Fault-inject an executed path absent from the predicted call
            # graph. It is in executable memory and must not be filtered away.
            expected=','.join(f'{a:#x}..{b-1:#x}' for a,b,_ in image.code)
            self.assertEqual(command[command.index('-dfilter')+1],expected)
            trace=Path(command[command.index('-D')+1])
            trace.write_text(''.join(f' pc {pc:016x}\n x1/ra 000000008000ffff x2/sp 0000000080700000\n'
                                     for pc in (entry,omitted)))
            return subprocess.CompletedProcess(command,0,'HEAP_BUDGET_FIXED_ARENAS_PASS','')
        with patch('linked_stack_probe.subprocess.run',side_effect=execute):
            with self.assertRaisesRegex(AssertionError,hex(omitted)):
                qualify(path,TARGET,['root'],1)

    def test_budget_and_entry_contracts(self):
        for items in [['root:-1'],['root:1.5'],['root'],[':16'],['root:１２']]:
            with self.assertRaises(ValueError):
                parse_entries(items)
        for entries in [[],[('leaf',16),('leaf',16)],[('leaf',True)],[('leaf',0)],[('leaf',2**64)]]:
            with self.assertRaises(ValueError):
                prove(self.images[0],MANIFEST,TARGET['target'],entries)
        with self.assertRaisesRegex(ValueError,'selected build target'):
            prove(self.images[0],MANIFEST,'different',[('leaf',64)])

    def test_independent_acyclic_graph_oracle(self):
        # 216 actual linked three-function graphs. The oracle uses only the
        # chosen source graph/local frame sizes, not instruction decoding.
        parts, expected = ['.text\n.globl _start\n_start: j _start\n'], {}
        for mask in range(8):
            for graph in range(27):
                label = f'g{mask}_{graph}_'
                sizes = [16 if mask & (1<<i) else 32 for i in range(3)]
                edges = [[1]*(graph%3)+[2]*((graph//3)%3), [2]*(graph//9), []]
                bounds = [0]*3
                for i in (2,1,0):
                    bounds[i] = sizes[i] + max([0]+[bounds[j] for j in edges[i]])
                    parts.append(f'.globl {label}{i}\n{label}{i}:\n addi sp,sp,-{sizes[i]}\n sd ra,0(sp)\n')
                    parts.extend(f' call {label}{j}\n' for j in edges[i])
                    parts.append(f' ld ra,0(sp)\n addi sp,sp,{sizes[i]}\n ret\n')
                expected[label+'0'] = bounds[0]
        for compressed in (False,True):
            data = self.build(''.join(parts),'graphs'+str(compressed),compressed=compressed)
            receipt = prove(data,MANIFEST,TARGET['target'],list(expected.items()))
            self.assertEqual({e['symbol']:e['peak_bytes'] for e in receipt['entries']},expected)

    def test_cli_refusal_preserves_previous_report(self):
        image, manifest, report = [self.directory/n for n in ('cli.elf','manifest.json','report.json')]
        image.write_bytes(self.images[0]);manifest.write_bytes(MANIFEST)
        cmd=[sys.executable,ROOT/'tools/check_linked_stack.py','--image',image,'--manifest',manifest,
             '--target',TARGET['target'],'--entry','root:80','--report',report]
        run(cmd)
        previous=report.read_bytes()
        cmd[cmd.index('root:80')]='root:79'
        result=subprocess.run(list(map(str,cmd)),capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('needs 80',result.stderr)
        self.assertEqual(report.read_bytes(),previous)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-execution',action='store_true')
    parser.add_argument('--record',type=Path)
    args=parser.parse_args()
    missing=[name for name in ('riscv64-unknown-elf-gcc','riscv64-unknown-elf-objdump','qemu-system-riscv64') if not shutil.which(name)]
    if missing:
        if args.require_execution:
            raise SystemExit('missing required tools: '+', '.join(missing))
        print('SKIP linked stack:', ', '.join(missing));return
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(LinkedStackTests)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    with tempfile.TemporaryDirectory(prefix='fpr-linked-stack-run-') as directory:
        path=Path(directory)/'execution.json'
        output=run([sys.executable,ROOT/'tests/check_heap_budget.py','--require-execution','--linked-stack','--record',path])
        print(output,end='')
        record=dict(schema='linked-stack-validation-v2',unit_tests=result.testsRun,acyclic_graphs=216,
                    graph_encodings=['RV64IM','RV64IMC'],compressed_encodings_checked=49152,compressed_encodings_supported=38550,
                    compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
                    execution=json.loads(path.read_text()),sources={})
        output=run([sys.executable,ROOT/'tests/check_callback_stack.py','--require-execution','--linked-stack','--record',path])
        print(output,end='')
        record['native_stack_parity']=json.loads(path.read_text())
        output=run([sys.executable,ROOT/'tests/check_heap_budget.py','--require-execution','--linked-stack','--rvc','--record',path])
        print(output,end='')
        record['compressed_execution']=json.loads(path.read_text())
        output=run([sys.executable,ROOT/'tests/check_callback_stack.py','--require-execution','--linked-stack','--rvc','--record',path])
        print(output,end='')
        record['compressed_native_stack_parity']=json.loads(path.read_text())
        for mode in ('plain','measured'):
            proof=record['compressed_execution']['execution']['images'][mode]['linked_stack']['proof']
            assert any(f['compressed_instructions']>0 for f in proof['functions'])
            native=record['compressed_native_stack_parity']['images'][mode]['linked_stack']
            assert any(f['compressed_instructions']>0 for f in native['functions'])
    for name in ('tools/check_linked_stack.py','tools/riscv_compressed.py','tools/target-image.sol','tools/check_target_image.py','tests/check_linked_stack.py',
                 'tests/linked_stack_probe.py','tests/check_heap_budget.py','tests/check_callback_stack.py',
                 'machine/builtin/heap.c','machine/builtin/arc.c'):
        record['sources'][name]=hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
    if args.record:
        args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()
