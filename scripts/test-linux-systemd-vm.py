#!/usr/bin/env python3
"""Run recovery tests in a disposable, NIC-less QEMU VM; never use host systemd."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--image',required=True,type=Path,help='Verified Debian 13 genericcloud qcow2 (kept unchanged)')
p.add_argument('--core',required=True,type=Path,help='Statically built pinned FD core')
p.add_argument('--daemon',required=True,type=Path,help='Statically built Linux daemon')
p.add_argument('--log',required=True,type=Path)
a=p.parse_args()
assert os.geteuid()!=0,'Run wrapper as ordinary user, no sudo fallback'
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='velum-f2-systemd-vm-') as tmp:
    work=Path(tmp)
    seed=work/'seed';seed.mkdir()
    for source,name in [(a.core,'sing-box'),(a.daemon,'velumd'),(root/'scripts/install-linux-service.sh','install-linux-service.sh'),(root/'scripts/testdata/linux-systemd-recovery.py','recovery.py')]:
        shutil.copyfile(source.resolve(strict=True),seed/name)
    (seed/'meta-data').write_text('instance-id: velum-f2-systemd\nlocal-hostname: velum-f2-disposable\n')
    (seed/'network-config').write_text('version: 2\nethernets: {}\n')
    (seed/'user-data').write_text('''#cloud-config
runcmd:
  - mkdir -p /mnt/velum-f2 /usr/local/lib/velum
  - mount -o ro /dev/sr0 /mnt/velum-f2
  - install -m 0755 /mnt/velum-f2/velumd /mnt/velum-f2/sing-box /usr/local/lib/velum/
  - echo no-host-network > /run/velum-f2-disposable
  - systemctl mask --runtime --now serial-getty@ttyS0.service
  - sh -c 'env VELUM_DISPOSABLE_VM=1 python3 /mnt/velum-f2/recovery.py > /dev/ttyS0 2>&1; echo GUEST_EXIT:$? > /dev/ttyS0'
  - systemctl poweroff
''')
    subprocess.run(['genisoimage','-quiet','-output',str(work/'seed.iso'),'-volid','cidata','-joliet','-rock',str(seed)],check=True)
    subprocess.run(['qemu-img','create','-q','-f','qcow2','-F','qcow2','-b',str(a.image.resolve(strict=True)),str(work/'disk.qcow2')],check=True)
    a.log.parent.mkdir(parents=True,exist_ok=True)
    # No TAP, host forwarding, bridge, shared host filesystem, or external NIC.
    with a.log.open('w') as log:
        subprocess.run(['qemu-system-x86_64','-accel','kvm','-cpu','host','-m','1024','-smp','2',
            '-display','none','-serial','stdio','-monitor','none','-no-reboot','-nic','none',
            '-drive',f'file={work}/disk.qcow2,if=virtio,format=qcow2',
            '-drive',f'file={work}/seed.iso,media=cdrom,readonly=on'],stdout=log,stderr=subprocess.STDOUT,timeout=240,check=True)
    lines=[s for s in a.log.read_text(errors='replace').splitlines() if s.startswith('VELUM_SYSTEMD_RESULT:')]
    if not lines:raise SystemExit(f'No VM test result: inspect {a.log}')
    result=json.loads(lines[-1].split(':',1)[1]);print(json.dumps(result,indent=2))
    if not result['success']:raise SystemExit(1)
