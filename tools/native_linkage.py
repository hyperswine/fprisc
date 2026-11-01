"""Mach-O linkage rules for a self-contained toolchain (macOS).

Shared by tools/stage-toolchain.py and tools/package-toolchain.py.

A toolchain may load libraries from only three places:
- /usr/lib and /System (the operating system);
- files inside the toolchain itself, through @rpath, @executable_path or
  @loader_path.

`bundle` copies every other library the compiler loads into
libexec/fprisc/lib, rewrites the load commands to @rpath, and re-signs each
changed file. `problems` checks every Mach-O file in a prefix against the
rules; the packagers refuse a prefix with any problem.
"""
from pathlib import Path
import shutil
import subprocess

SYSTEM = ('/usr/lib/', '/System/')
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
NOTICE_PREFIXES = ('LICENSE', 'LICENCE', 'COPYING', 'NOTICE')


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as f:
        return f.read(4) in MAGIC


def install_id(path):
    lines = subprocess.check_output(['otool', '-D', path], text=True).splitlines()[1:]
    return lines[0].strip() if lines else None


def dependencies(path):
    """The libraries a Mach-O file loads, without its own install name."""
    own = install_id(path)
    deps = []
    for line in subprocess.check_output(['otool', '-L', path], text=True).splitlines()[1:]:
        name = line.strip().split(' (compatibility')[0]
        if name and name != own and name not in deps:
            deps.append(name)
    return deps


def rpaths(path):
    out, found, lines = [], False, subprocess.check_output(['otool', '-l', path], text=True).splitlines()
    for line in lines:
        words = line.split()
        if words[:2] == ['cmd', 'LC_RPATH']:
            found = True
        elif found and words[:1] == ['path']:
            out.append(words[1])
            found = False
    return out


def _expand(entry, image, executable):
    if entry.startswith('@loader_path'):
        return Path(str(image.parent) + entry[len('@loader_path'):])
    if entry.startswith('@executable_path'):
        return Path(str(executable.parent) + entry[len('@executable_path'):])
    return Path(entry)


def problems(prefix, executable):
    """Every load command or rpath in `prefix` that reaches outside the OS and
    the prefix itself, as (file relative to prefix, offending path, reason)."""
    prefix = prefix.resolve()
    found = []
    for image in sorted(p for p in prefix.rglob('*') if is_macho(p)):
        relative = str(image.relative_to(prefix))
        image_rpaths = rpaths(image)
        for entry in image_rpaths:
            target = _expand(entry, image, executable).resolve()
            if not entry.startswith(('@loader_path', '@executable_path')) or not target.is_relative_to(prefix):
                found.append((relative, entry, 'rpath outside the toolchain'))
        # dyld also searches the rpaths of the main executable for a library's @rpath
        search = image_rpaths + ([] if image == executable else rpaths(executable))
        for dep in dependencies(image):
            if dep.startswith(SYSTEM):
                continue
            if dep.startswith('@rpath/'):
                hits = [_expand(r, image, executable) / dep[len('@rpath/'):] for r in search]
                if not any(h.resolve().is_relative_to(prefix) and h.is_file() for h in hits):
                    found.append((relative, dep, 'no file inside the toolchain'))
            elif dep.startswith(('@loader_path', '@executable_path')):
                target = _expand(dep, image, executable).resolve()
                if not (target.is_relative_to(prefix) and target.is_file()):
                    found.append((relative, dep, 'no file inside the toolchain'))
            else:
                found.append((relative, dep, 'library outside /usr/lib, /System and the toolchain'))
    return found


def describe(found):
    return '; '.join(f'{binary} loads {path} ({why})' for binary, path, why in found)


def _notices(real):
    """License files at the install prefix the library came from, e.g. a
    Homebrew keg: <prefix>/lib/libfoo.dylib -> <prefix>/COPYING."""
    keg = real.parent.parent
    return keg, sorted(p for p in keg.iterdir() if p.is_file() and p.name.upper().startswith(NOTICE_PREFIXES))


def _sign(path):
    subprocess.run(['codesign', '--force', '--sign', '-', path], check=True, capture_output=True, text=True)


def bundle(sdk, executable):
    """Copy the non-system library closure of `executable` into sdk/lib and make
    every reference @rpath-relative. Returns what was bundled, for toolchain.json."""
    lib = sdk / 'lib'
    queue, seen, bundled = [executable], {}, []
    while queue:
        image = queue.pop()
        for dep in dependencies(image):
            if dep.startswith(SYSTEM) or dep in seen:
                continue
            if dep.startswith('@'):
                raise ValueError(f'{image.name} loads {dep}; build with absolute install names so the stage can bundle them')
            source = Path(dep)
            if not source.is_file():
                raise ValueError(f'{image.name} loads {dep}, which does not exist on this machine')
            real = source.resolve()
            name = source.name
            same = next((b for b in bundled if b['source'] == str(real)), None)
            if same:  # one file reached by two install names (opt/ and Cellar/ paths)
                seen[dep] = sdk / same['file']
                continue
            if any(b['file'] == f'lib/{name}' for b in bundled):
                raise ValueError(f'two bundled libraries share the name {name}')
            keg, notices = _notices(real)
            if not notices:
                raise ValueError(f'no license notice beside {real} (looked in {keg}); cannot bundle it')
            lib.mkdir(exist_ok=True)
            copy = lib / name
            shutil.copy2(real, copy)
            copy.chmod(0o755)
            noticedir = lib / 'licenses' / f'{keg.parent.name}-{keg.name}'
            noticedir.mkdir(parents=True, exist_ok=True)
            for notice in notices:
                shutil.copy2(notice, noticedir / notice.name)
                (noticedir / notice.name).chmod(0o644)
            seen[dep] = copy
            bundled.append(dict(installName=dep, file=f'lib/{name}', source=str(real),
                                package=keg.parent.name, packageVersion=keg.name,
                                notices=[str((noticedir / n.name).relative_to(sdk)) for n in notices]))
            queue.append(copy)
    for image in [executable] + list(dict.fromkeys(seen.values())):
        args = []
        if image != executable:
            args += ['-id', f'@rpath/{image.name}']
        for dep in dependencies(image):
            if dep in seen:
                args += ['-change', dep, f'@rpath/{seen[dep].name}']
        want = '@executable_path/lib' if image == executable else '@loader_path'
        if seen and want not in rpaths(image):
            args += ['-add_rpath', want]
        if args:
            subprocess.run(['install_name_tool', *args, image], check=True, capture_output=True, text=True)
            _sign(image)
    return bundled
