#!/usr/bin/env python3
"""Read-only evidence inventory, NOT a firmware validator. No GPIO/serial/network access."""
import argparse
import json
import os
import re
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('root',type=Path,help='Local root containing Core/ESP32 sources')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=args.root.resolve()
patterns={
    'head_command':r'\b(PAN|TILT|HEAD_CENTER)\b',
    'pan_telemetry':r'\bpan_deg\b',
    'tilt_telemetry':r'\btilt_deg\b',
    'timestamp':r'\b(timestamp|millis|micros|monotonic)\b',
    'stop':r'\b(ESTOP|STOP|emergency_stop)\b',
    'watchdog':r'\b(watchdog|heartbeat|timeout|WDT)\b',
    'odometry':r'\b(odometry|encoder|wheel_ticks)\b',
}
files=[]
if root.is_dir():
    for folder,dirs,names in os.walk(root,followlinks=False):
        dirs[:]=[d for d in dirs if not d.startswith('.') and d not in {'node_modules','build','DerivedData','venv','__pycache__'} and not (Path(folder)/d).is_symlink()]
        for name in sorted(names):
            p=Path(folder)/name
            if p.resolve()==Path(__file__).resolve(): continue
            if p.is_symlink() or p.suffix.lower() not in {'.ino','.cpp','.c','.h','.hpp','.py','.swift'}: continue
            if len(files)>=2000: break
            if p.stat().st_size>1_000_000: continue
            rel=str(p.relative_to(root))
            firmware=p.suffix.lower() in {'.ino','.cpp','.c','.h','.hpp'}
            if not firmware and not any(term in rel.lower() for term in ('esp32','firmware','protocol','telemetry','body','transport')): continue
            source=p.read_text(errors='replace')
            if firmware and not any(term in (rel+'\n'+source).lower() for term in ('esp32','arduino','bts7960','pan_deg','head_center')): continue
            matches={key:[i for i,line in enumerate(source.splitlines(),1) if re.search(pattern,line,re.I)] for key,pattern in patterns.items()}
            if firmware or any(matches.values()):
                files.append({'path':rel,'firmware_candidate':firmware,'evidence_line_numbers':matches})
report={
    'schema':1,'root_found':root.is_dir(),'read_only':True,'physical_transport_validated':False,
    'firmware_candidates':sum(f['firmware_candidate'] for f in files),'files':files,
    'limitations':['Keyword evidence does not prove behavior, protocol compatibility or measured servo feedback.',
                   'No serial, GPIO, network, hardware, credentials or personal memory access.',
                   'Head/body calibration, clock synchronization, odometry, watchdog and existing safety require review and bench verification.',
                   'No actuator command generated. A report cannot authorize movement.'],
}
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print(f"Read-only audit: {len(files)} source files, {report['firmware_candidates']} firmware candidates. Physical integration remains unvalidated.")
print(f'Report: {args.output}')
