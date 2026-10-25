#!/usr/bin/env python3
"""Run every independent course deck through a fresh build of real ngspice."""
from pathlib import Path
import concurrent.futures
import json
import platform
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve()
out.mkdir(parents=True,exist_ok=True)
node=shutil.which('node') or str(Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node')
subprocess.run([node,str(root/'scripts/verify_independent_courses.mjs'),str(out)],check=True)
spice=root/'Vendor/ngspice/NgSpice.xcframework/macos-arm64_x86_64'
binary=out/'course-verify'
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-target',platform.machine()+'-apple-macos26.0','-I',str(spice/'Headers'),
                *map(str,(root/'Sources/CircuitCore').glob('*.swift')),str(root/'scripts/verify_course_cad.swift'),str(spice/'libngspice.a'),'-lc++','-o',str(binary)],check=True)
cases=json.loads((out/'cases.json').read_text());(out/'native').mkdir(exist_ok=True)
def solve(case):
    result=out/'native'/(case['id']+'.json')
    try:
        process=subprocess.run([str(binary),str(out/'cases.json'),str(root/'Engineering/PDK'),case['id'],str(result)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=160)
        if process.returncode:
            return {'id':case['id'],'passed':False,'error':process.stdout.decode(errors='replace')[-1500:]}
        return json.loads(result.read_text())
    except Exception as error:
        return {'id':case['id'],'passed':False,'error':str(error)}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(solve,cases))
summary={'cases':len(results),'passedCases':sum(r['passed'] for r in results),
         'analyses':sum(len(r.get('checks',[])) for r in results),'failed':[r for r in results if not r['passed']]}
(out/'native-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
(out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print(json.dumps(summary,ensure_ascii=False))
if summary['failed']:
    raise SystemExit(1)
