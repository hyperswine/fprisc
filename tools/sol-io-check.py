#!/usr/bin/env python3
"""Phase 2 exact bytes, bounded streams, ownership and script host contracts."""
import json
import os
from pathlib import Path
import signal
import resource
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()


def literal(value):
    return json.dumps(str(value), ensure_ascii=False).replace('\\u0000', '\\0').replace('{', '\\{').replace('}', '\\}')


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-io-check-') as tmp:
        work = Path(tmp).resolve()
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
        env |= {'SOL_GPU': '0', 'SOL_JIT': os.environ.get('FPR_TEST_JIT', '1'), 'SOL_CACHE_DIR': str(work / 'cache')}
        def run(name, source, expected=b'', *, code=0, stdin=None, error=None, cwd=None, extra=None, exact_stderr=None, allow_retry=False, fd_limit=None):
            nonlocal count
            path = work / (name + '.sol')
            path.write_text(source)
            def limit_descriptors():
                _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (fd_limit, hard))
            p = subprocess.run([str(FPR), 'sol', str(path)], input=stdin, capture_output=True,
                               env=env | (extra or {}), cwd=cwd or work, timeout=30,
                               preexec_fn=limit_descriptors if fd_limit else None)
            assert p.returncode == code and p.stdout == expected, (name, p)
            if error is not None:
                assert error in p.stderr, (name, p)
            if exact_stderr is not None:
                assert p.stderr == exact_stderr, (name, p)
            if code == 0:
                assert b'PANIC' not in p.stderr and (allow_retry or b'conflict on' not in p.stderr), (name, p)
            count += 1
            return p

        all_bytes = bytes(range(256))
        source = work / 'binary.dat'
        source.write_bytes(all_bytes * 17)
        src = literal(source)
        run('all_octets', '> b = unwrap (Bytes.fromList (List.range 0 255)); IO.stdout b.\n', all_bytes,
            exact_stderr=b'')
        run('immutable_bytes', '> b = unwrap (Bytes.fromList [0,128,255]); s = unwrap (Bytes.slice 1 2 b);'
            ' print (Bytes.toList b, Bytes.toList s, b == b).\n', b'([0, 128, 255], [128, 255], True)\n')
        run('byte_range_error', '> print (isOk (Bytes.fromList [256])).\n', b'False\n')
        run('byte_index_error', '> b = Bytes.empty Unit; print (isOk (Bytes.at 0 b)).\n', b'False\n')
        run('nul_utf8', '> b = unwrap (Bytes.fromList [0]); print (Bytes.toList (unwrap (Utf8.encode (unwrap (Utf8.decode b))))).\n', b'[0]\n')
        run('invalid_utf8', '> b = unwrap (Bytes.fromList [255,192,128]); print (isOk (Utf8.decode b)).\n', b'False\n')
        run('replacement_utf8', '> b = unwrap (Bytes.fromList [255]); IO.stdoutText (Utf8.decodeReplace b).\n', '\ufffd'.encode())
        run('incremental_utf8', '> a = unwrap (Bytes.fromList [240,159]); b = unwrap (Bytes.fromList [152,128]);'
            ' (s,c) = unwrap (Utf8.decodeChunk (Bytes.empty Unit) a False);'
            ' (t,d) = unwrap (Utf8.decodeChunk c b True); print (s,t,Bytes.len d).\n', '(, 😀, 0)\n'.encode())
        run('truncated_utf8', '> a = unwrap (Bytes.fromList [226]);'
            ' print (isOk (Utf8.decodeChunk (Bytes.empty Unit) a True)).\n', b'False\n')
        run('invalid_partial_utf8', '> a = unwrap (Bytes.fromList [224,128]);'
            ' print (isOk (Utf8.decodeChunk (Bytes.empty Unit) a False)).\n', b'False\n')
        for index, text in enumerate(['A', 'λ', '世', '😀', 'aλ世😀z']):
            raw = text.encode()
            for split in range(len(raw) + 1):
                left, right = json.dumps(list(raw[:split])), json.dumps(list(raw[split:]))
                run(f'utf8_boundary_{index}_{split}',
                    f'> a = unwrap (Bytes.fromList {left}); b = unwrap (Bytes.fromList {right});'
                    ' (s,c) = unwrap (Utf8.decodeChunk (Bytes.empty Unit) a False);'
                    ' (t,d) = unwrap (Utf8.decodeChunk c b True); IO.stdoutText (strcat s t).\n', raw)
        for index, raw in enumerate([b'\x80', b'\xc0\x80', b'\xe0\x80\x80', b'\xed\xa0\x80', b'\xf4\x90\x80\x80']):
            run(f'utf8_invalid_scalar_{index}',
                f'> b = unwrap (Bytes.fromList {json.dumps(list(raw))}); print (isOk (Utf8.decode b)).\n', b'False\n')
        run('utf8_surrogate_encode', '> print (isOk (Utf8.encode (Str.fromCode 55296))).\n', b'False\n')
        run('exact_channels', '> u = IO.stdoutText "out"; IO.stderrText "err".\n', b'out', exact_stderr=b'err')
        run('text_line_eof', '> a = IO.readLine 32; b = IO.readLine 32; c = IO.readLine 32; print (a,b,c).\n',
            b'(Ok LineText , Ok LineText last, Ok EndText)\n', stdin=b'\nlast')
        run('text_line_limit', '> print (isOk (IO.readLine 2)).\n', b'False\n', stdin=b'abc\n')
        run('text_line_invalid', '> print (isOk (IO.readLine 10)).\n', b'False\n', stdin=b'\xff\n')

        fold = ('count n b = n + Bytes.len b.\n'
                f'> r = unwrap (Stream.openRead {src} 7);'
                ' (result,r2) = Stream.foldChunks count 0 r; u = Stream.closeRead r2; print result.\n')
        run('stream_chunk_fold', fold, f'Ok {source.stat().st_size}\n'.encode())
        run('stream_stdin', 'emit n b = u = unwrap (IO.stdout b); n + Bytes.len b.\n'
            '> r = unwrap (Stream.stdin 3); (result,r2) = Stream.foldChunks emit 0 r; Stream.closeRead r2.\n',
            all_bytes, stdin=all_bytes)
        lines = work / 'lines.txt'
        lines.write_bytes(b'\nlast')
        run('stream_lines_exact', 'emit n b = u = unwrap (IO.stdout b); n + 1.\n'
            f'> r = unwrap (Stream.openRead {literal(lines)} 2);'
            ' (result,r2) = Stream.foldLines emit 0 10 r; Stream.closeRead r2.\n', b'\nlast')
        run('stdin_cursor_shared', 'emit n b = u = unwrap (IO.stdout b); n + 1.\n'
            '> first = IO.readLine 64; r = unwrap (Stream.stdin 2);'
            ' (result,r2) = Stream.foldChunks emit 0 r; u = Stream.closeRead r2; print first.\n',
            b'restOk LineText first\n', stdin=b'first\nrest')
        run('line_limit_keeps_owner',
            f'> r = unwrap (Stream.openRead {src} 3); (result,r2) = Stream.readLine 2 r;'
            ' u = Stream.closeRead r2; print (isOk result).\n', b'False\n')
        tiny_chunks = work / 'tiny-chunks.txt'
        tiny_chunks.write_bytes(b'x' * 16383 + b'\n')
        run('line_with_one_byte_chunks',
            f'> r = unwrap (Stream.openRead {literal(tiny_chunks)} 1); (result,r2) = Stream.readLine 16384 r;'
            ' u = Stream.closeRead r2; n = case unwrap result of ChunkBytes b -> Bytes.len b | EndBytes -> -1; print n.\n',
            b'16384\n')
        target = work / 'written.dat'
        run('owned_writer', f'> w = unwrap (Stream.openWrite {literal(target)} 4);'
            ' b = unwrap (Bytes.fromList [0,255]); (result,w2) = Stream.writeChunk b w;'
            ' u = unwrap result; Stream.closeWrite w2.\n')
        assert target.read_bytes() == b'\0\xff'
        folded = work / 'folded-copy.dat'
        run('fold_owned_writer_state',
            'step w b = (result,w2) = Stream.writeChunk b w; u = unwrap result; w2.\n'
            f'> r = unwrap (Stream.openRead {src} 11); w = unwrap (Stream.openWrite {literal(folded)} 11);'
            ' (result,r2) = Stream.foldChunks step w r; u = Stream.closeRead r2;'
            ' w2 = unwrap result; Stream.closeWrite w2.\n')
        assert folded.read_bytes() == source.read_bytes()
        run('writer_limit', f'> w = unwrap (Stream.openWrite {literal(work / "limit.dat")} 1);'
            ' b = unwrap (Bytes.fromList [0,255]); (result,w2) = Stream.writeChunk b w;'
            ' u = Stream.closeWrite w2; print (isOk result).\n', b'False\n')
        run('reader_cannot_duplicate', f'> r = unwrap (Stream.openRead {src} 4);'
            ' u = Stream.closeRead r; Stream.closeRead r.\n', code=1, error=b'LINEARITY')
        run('reader_cannot_drop', f'> r = Stream.openRead {src} 4; print "dropped".\n',
            code=1, error=b'LINEARITY')
        run('forged_reader_refused', '> r = ByteReader 1; Stream.closeRead r.\n',
            code=1, error=b'forged')

        copy = work / 'copy.dat'
        run('binary_copy', f'> print (Fs.copyNow {src} {literal(copy)} 11).\n', f'Ok {source.stat().st_size}\n'.encode())
        assert copy.read_bytes() == source.read_bytes()
        why = 'why r = case r of Ok x -> "ok" | Err (FsError op path reason message) -> "{reason}".\n'
        run('copy_no_clobber', why + f'> print (why (Fs.copyNow {src} {literal(copy)} 11)).\n', b'FsExists\n')
        publish = work / 'published.dat'
        run('publish_copy', f'> print (Fs.copyPublishNow {src} {literal(publish)} 13 False).\n', f'Ok {source.stat().st_size}\n'.encode())
        assert publish.read_bytes() == source.read_bytes()
        publish.chmod(0o751)
        run('publish_replace', f'> print (Fs.copyPublishNow {src} {literal(publish)} 13 True).\n', f'Ok {source.stat().st_size}\n'.encode())
        assert publish.stat().st_mode & 0o777 == 0o751
        long_target = work / ('n' * 240 + '.bin')
        run('publish_long_destination_name', f'> print (Fs.copyPublishNow {src} {literal(long_target)} 13 False).\n',
            f'Ok {source.stat().st_size}\n'.encode())
        assert long_target.read_bytes() == source.read_bytes()
        link = work / 'link'
        link.symlink_to(source)
        run('publish_symlink_refused', why + f'> print (why (Fs.copyPublishNow {src} {literal(link)} 13 True)).\n', b'FsOther\n')
        assert link.is_symlink() and source.read_bytes() == all_bytes * 17
        run('source_symlink_refused', why + f'> print (why (Fs.copyNow {literal(link)} {literal(work / "bad-copy")} 13)).\n', b'FsLoop\n')
        assert not (work / 'bad-copy').exists()
        run('copy_path_nul', f'> print (isOk (Fs.copyNow {src} {literal(str(work / "nul") + chr(0) + "ignored")} 13)).\n', b'False\n')
        assert not (work / 'nul').exists()
        moved = work / 'moved.dat'
        run('rename_atomic', f'> print (Fs.renameNow {literal(copy)} {literal(moved)} False).\n', b'Ok ()\n')
        assert not copy.exists() and moved.read_bytes() == source.read_bytes()
        run('rename_no_clobber', why + f'> print (why (Fs.renameNow {literal(moved)} {literal(publish)} False)).\n', b'FsExists\n')
        assert moved.exists()
        directory_source = work / 'dir-before'
        directory_source.mkdir()
        (directory_source / 'child').write_bytes(b'kept')
        directory_target = work / 'dir-after'
        run('rename_directory', f'> print (Fs.renameNow {literal(directory_source)} {literal(directory_target)} False).\n', b'Ok ()\n')
        assert not directory_source.exists() and (directory_target / 'child').read_bytes() == b'kept'
        run('immediate_fence', f'> u = writePath {literal(work / "queued")} "q";'
            f' print (isOk (Fs.copyNow {src} {literal(work / "fenced")} 7)).\n', b'False\n')
        assert not (work / 'fenced').exists() and (work / 'queued').read_text() == 'q'
        run('fold_callback_order_fence',
            f'step n b = u = writePath {literal(work / "callback-queued")} "q"; n + Bytes.len b.\n'
            f'> r = unwrap (Stream.openRead {src} 3); (result,r2) = Stream.foldChunks step 0 r;'
            ' u = Stream.closeRead r2; print (isOk result).\n', b'False\n')
        assert not list(work.glob('*.sol-stage-*')) and not list(work.glob('.*.sol-stage-*'))

        key = 'SOL_PHASE2_TEST_VALUE'
        run('env_override_remove', f'> a = Env.set "{key}" "a b"; b = Env.get "{key}";'
            f' c = Env.unset "{key}"; d = Env.get "{key}"; print (b,d).\n', b'(Ok EnvText a b, Ok EnvMissing)\n')
        run('env_restored_before_retry', f'> old = Env.get "{key}"; u = Env.set "{key}" "changed"; print old.\n',
            b'Ok EnvMissing\n' * 3, extra={'SOL_FORCE_RETRY': '2', 'SOL_RETRY_POLICY': 'legacy'}, allow_retry=True)
        run('cwd_is_invocation', '> r = IO.cwd Unit; print r.\n', f'Ok {ROOT}\n'.encode(), cwd=ROOT)
        committed = work / 'exit-committed'
        run('requested_exit_commits', f'> u = writePath {literal(committed)} "yes"; Script.exit 7.\n> print "unreachable".\n', code=7)
        assert committed.read_text() == 'yes'
        aborted = work / 'exit-aborted'
        run('requested_abort_rolls_back', f'> u = writePath {literal(aborted)} "no"; Script.abort 9.\n', code=9)
        assert not aborted.exists()
        run('exit_cannot_mask_failed_effect', '> u = Proc.afterCommit (ProcessSpec ["/usr/bin/false"] "" [] "" 1000); Script.exit 0.\n',
            code=1, error=b'deferred process FAILED')
        run('exit_status_limit', '> Script.exit 256.\n', code=1, error=b'exit status')
        # Explicitly stop before the syntactic closes. Five attempts open
        # 150 descriptors in one process under a 96-fd limit: without attempt
        # cleanup this necessarily exhausts the OS limit before completion.
        opens = ' '.join(f'r{i} = unwrap (Stream.openRead {src} 4);' for i in range(30))
        closes = ' '.join(f'c{i} = Stream.closeRead r{i};' for i in range(30))
        run('exit_retry_descriptor_cleanup', f'> {opens} u = print "attempt"; stop = Script.exit 0; {closes} Unit.\n',
            b'attempt\n' * 5, extra={'SOL_FORCE_RETRY': '4', 'SOL_RETRY_POLICY': 'legacy'}, allow_retry=True, fd_limit=96)
        run('move_text_compat', f'> u = writePath {literal(work / "old-text")} "text";'
            f' moveText {literal(work / "old-text")} {literal(work / "new-text")}.\n')
        assert not (work / 'old-text').exists() and (work / 'new-text').read_text() == 'text'

        # The CLI examples use raw argv paths and preserve exact filter bytes.
        example_copy = work / 'example output.dat'
        p = subprocess.run([str(FPR), 'sol', str(ROOT / 'sol/scripts/copy-binary.sol'), str(source), str(example_copy)],
                           env=env, capture_output=True, timeout=30)
        assert p.returncode == 0 and example_copy.read_bytes() == source.read_bytes(), p
        example_input = work / 'example.log'
        example_input.write_bytes(b'yes one\nno\nyes last')
        p = subprocess.run([str(FPR), 'sol', str(ROOT / 'sol/scripts/text/filter-stream.sol'), 'yes', str(example_input)],
                           env=env, capture_output=True, timeout=30)
        assert p.returncode == 0 and p.stdout == b'yes one\nyes last', p
        count += 2

        shared_memory = Path('/dev/shm')
        if shared_memory.is_dir() and shared_memory.stat().st_dev != work.stat().st_dev:
            with tempfile.TemporaryDirectory(prefix='sol-rename-', dir=shared_memory) as other:
                across = Path(other) / 'target'
                run('rename_cross_device', why + f'> print (why (Fs.renameNow {src} {literal(across)} False)).\n', b'FsCrossDevice\n')
                assert source.exists() and not across.exists()
        else:
            print('note: cross-device rename fixture unavailable; native EXDEV case was not exercised')

        # Cancellation must remove staged output while preserving an existing
        # destination. A sparse input makes the copy long enough to interrupt
        # without retaining a multi-GiB source fixture on disk.
        big = work / 'sparse-input'
        with big.open('wb') as f:
            f.truncate(2 * 1024**3)
        cancel_target = work / 'cancel-output'
        cancel_target.write_bytes(b'original')
        cancel = work / 'cancel.sol'
        cancel.write_text(f'> Fs.copyPublishNow {literal(big)} {literal(cancel_target)} 4096 True.\n')
        child = subprocess.Popen([str(FPR), 'sol', str(cancel)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            until = time.monotonic() + 15
            while time.monotonic() < until and not list(work.glob('.sol-stage-*')):
                assert child.poll() is None, child.communicate()
                time.sleep(.005)
            assert list(work.glob('.sol-stage-*')), 'copy did not reach staging'
            child.send_signal(signal.SIGINT)
            out, err = child.communicate(timeout=10)
            assert child.returncode == 130 and not out, (child.returncode, out, err)
            assert cancel_target.read_bytes() == b'original'
            assert not list(work.glob('.sol-stage-*'))
            count += 1
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

        # Direct-copy cleanup owns the created inode, not every future file
        # somebody may publish at that pathname.
        cancel_target.unlink()
        cancel.write_text(f'> Fs.copyNow {literal(big)} {literal(cancel_target)} 4096.\n')
        child = subprocess.Popen([str(FPR), 'sol', str(cancel)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            until = time.monotonic() + 15
            while not cancel_target.exists() and time.monotonic() < until:
                assert child.poll() is None, child.communicate()
                time.sleep(.002)
            assert cancel_target.exists()
            replacement = work / 'foreign-replacement'
            replacement.write_bytes(b'foreign')
            os.replace(replacement, cancel_target)
            child.send_signal(signal.SIGINT)
            out, err = child.communicate(timeout=10)
            assert child.returncode == 130 and cancel_target.read_bytes() == b'foreign', (child.returncode, out, err)
            assert b'preserved a foreign replacement' in err, err
            count += 1
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    print(f'sol byte/stream/script I/O: {count} checks passed')


if __name__ == '__main__':
    main()
