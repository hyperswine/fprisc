#!/usr/bin/env python3
"""Isolated decoder bounds/auth/coalescing tests. No printer credentials needed."""
import concurrent.futures
import http.client
import importlib.util
from pathlib import Path
import tempfile
import threading
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('snapshot',ROOT/'tools/printer_snapshot.py')
snapshot=importlib.util.module_from_spec(spec);spec.loader.exec_module(snapshot)
JPEG=b'\xff\xd8test\xff\xd9'


class Tests(unittest.TestCase):
    def test_shared_capture_and_failure_recovery(self):
        calls=[]
        def capture(*args):
            calls.append(1);time.sleep(.05);return JPEG
        source=snapshot.Source({},'test-only','unused',capture)
        self.assertEqual(len(calls),0)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results=list(pool.map(lambda _:source.picture(),range(6)))
        self.assertEqual(len(calls),1)
        self.assertTrue(all(r==results[0] for r in results))
        source.last=0
        source.capture=lambda *args:b'bad'
        with self.assertRaises(ValueError):source.picture()
        self.assertEqual(source.frame,b'')
        with self.assertRaises(ValueError):source.picture()
        source.failed=0;source.capture=capture
        self.assertEqual(source.picture()[0],JPEG)

    def test_http_auth_routes_and_idle(self):
        calls=[]
        def capture(*args):calls.append(1);return JPEG
        server=snapshot.Server(('127.0.0.1',0),{'test':snapshot.Source({},'test-only','unused',capture)})
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        def get(path,code=None):
            c=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=2)
            c.request('GET',path,headers={} if code is None else {'X-Printer-Camera-Code':code})
            r=c.getresponse();result=r.status,r.read(),r.getheader('X-Camera-Captured-At');c.close();return result
        try:
            for route,code in [('/snapshot/test.jpg',None),('/snapshot/test.jpg','wrong'),('/snapshot/test.jpg','é'),('/snapshot/other.jpg','test-only'),('/snapshot/../test.jpg','test-only')]:
                self.assertEqual(get(route,code)[0],403)
            self.assertEqual(calls,[])
            status,body,captured=get('/snapshot/test.jpg','test-only')
            self.assertEqual((status,body),(200,JPEG));self.assertGreater(int(captured),0)
            time.sleep(.1);self.assertEqual(len(calls),1,'no background polling')
        finally:server.shutdown();server.server_close();worker.join()

    def test_subprocess_bounds_and_credentials_not_in_argv(self):
        row={'host':'127.0.0.1','tls_peer':'server.example','tls_ca':'/synthetic/ca.pem'}
        with tempfile.TemporaryDirectory() as temp:
            fake=Path(temp)/'ffmpeg'
            def install(body):
                fake.write_text('#!/usr/bin/env python3\nimport sys,time\n'+body);fake.chmod(0o700)
            install("assert 'test-secret' not in str(sys.argv)\nassert 'test-secret' in sys.stdin.read()\nsys.stdout.buffer.write(b'\\xff\\xd8ok\\xff\\xd9')\n")
            self.assertEqual(snapshot.decode(row,'test-secret',str(fake)),b'\xff\xd8ok\xff\xd9')
            install("sys.stdin.read()\ntime.sleep(10)\n")
            start=time.monotonic()
            with self.assertRaises(TimeoutError):snapshot.decode(row,'test-secret',str(fake),timeout=.2)
            self.assertLess(time.monotonic()-start,2)
            install("sys.stdin.read()\nsys.stdout.buffer.write(b'x'*4194305)\n")
            with self.assertRaises(ValueError):snapshot.decode(row,'test-secret',str(fake))
            install("sys.stdin.read()\nsys.stdout.buffer.write(b'not a jpeg')\n")
            with self.assertRaises(ValueError):snapshot.decode(row,'test-secret',str(fake))


if __name__=='__main__':unittest.main()
