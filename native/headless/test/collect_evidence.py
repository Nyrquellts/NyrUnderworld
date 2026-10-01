"""Copy verified host results and hashes into metadata; never copy crash dumps."""
from pathlib import Path
import hashlib,json

ROOT=Path(__file__).resolve().parents[1]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    cases=json.loads((ROOT/'out/test-results.json').read_text())
    report={
        'schema':'nyr.headless-host-evidence/1','scope':'owned hidden x64 hosts',
        'gameplay':'UNKNOWN','deployed':False,
        'binaries':{name:digest(ROOT/'out'/name) for name in ('nyr_headless.dll','headless_host.exe','nyr_headless_fault.dll','headless_fault_host.exe')},
        'sources':{str(path.relative_to(ROOT)).replace('\\','/'):digest(path)
            for folder in ('src','include','test') for path in sorted((ROOT/folder).glob('*')) if path.is_file()},
        'cases':[{k:v for k,v in row.items() if k!='directory'} for row in cases],
        'raw_minidumps_packaged':False,
    }
    (ROOT/'evidence').mkdir(exist_ok=True)
    (ROOT/'evidence/native-host.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'cases':len(cases),'all_passed':all(row['passed'] for row in cases),'raw_minidumps_packaged':False}))
if __name__=='__main__':main()
