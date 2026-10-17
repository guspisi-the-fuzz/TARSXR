#!/usr/bin/env python3
"""Exercise the read-only inventory on temporary synthetic sources, not user's firmware."""
import json
import subprocess
import tempfile
from pathlib import Path
script=Path(__file__).resolve().parents[1]/'scripts/audit-spatial-body.py'
with tempfile.TemporaryDirectory(prefix='tars-audit-checks-') as temp:
    root=Path(temp)/'source'; root.mkdir()
    source=root/'esp32.ino'
    original=b'// ESP32 fixture\nvoid PAN() {}\nfloat pan_deg;\nvoid watchdog() {}\n// SECRET_SENTINEL_NEVER_PRINT\n'
    source.write_bytes(original)
    outside=Path(temp)/'outside.ino'; outside.write_text('// ESP32\nfloat tilt_deg;')
    (root/'symlink.ino').symlink_to(outside)
    ignored=root/'build'; ignored.mkdir(); (ignored/'esp32.ino').write_text('// ESP32\nESTOP;')
    report=Path(temp)/'report.json'
    result=subprocess.run(['python3',str(script),str(root),'--output',str(report)],check=True,capture_output=True,text=True)
    data=json.loads(report.read_text())
    assert data['read_only'] and not data['physical_transport_validated']
    assert data['firmware_candidates']==1 and len(data['files'])==1
    assert data['files'][0]['path']=='esp32.ino'
    assert data['files'][0]['evidence_line_numbers']['pan_telemetry']==[3]
    assert data['files'][0]['evidence_line_numbers']['tilt_telemetry']==[]
    assert 'SECRET_SENTINEL' not in report.read_text()+result.stdout+result.stderr
    assert source.read_bytes()==original
    assert outside.read_text()=='// ESP32\nfloat tilt_deg;'
    subprocess.run(['python3',str(script),str(root/'missing'),'--output',str(report)],check=True,capture_output=True)
    assert not json.loads(report.read_text())['root_found']
print('PASS: read-only body inventory with synthetic firmware, missing roots, excluded build/symlink files, no source mutation or source-content disclosure; no hardware validation.')
