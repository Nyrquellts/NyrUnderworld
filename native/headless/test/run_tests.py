"""Run only hidden owned crash hosts; inspect structured reports and real dumps."""
from pathlib import Path
import json,subprocess,tempfile,time,struct
OUT=Path(__file__).resolve().parents[1]/'out'
EXPECTED=0xe04e5952
results=[]
for mode in ('clean','invalid','exception','access_violation','thread_exception','replace_filter','message_w','message_a','apply_failure'):
    folder=Path(tempfile.mkdtemp(prefix='owned-crash-',dir=OUT))
    before=time.monotonic()
    host='headless_fault_host.exe' if mode=='apply_failure' else 'headless_host.exe'
    result=subprocess.run([str(OUT/host),str(folder),mode],cwd=OUT,capture_output=True,text=True,timeout=10,creationflags=subprocess.CREATE_NO_WINDOW)
    elapsed=time.monotonic()-before
    if mode in ('clean','invalid'):
        assert result.returncode==0,(mode,result)
    elif mode=='apply_failure':
        assert result.returncode&0xffffffff==EXPECTED,(mode,result)
        assert elapsed<5,elapsed
    else:
        assert result.returncode&0xffffffff==EXPECTED,(mode,result)
        reports=list(folder.glob('*.json'));dumps=list(folder.glob('*.dmp'))
        assert len(reports)==len(dumps)==1
        report=json.loads(reports[0].read_text())
        assert report['minidump_written'],report
        if mode=='access_violation': assert report['exception_code']==0xc0000005,report
        data=dumps[0].read_bytes()
        assert data[:4]==b'MDMP' and len(data)>32
        streams,directory=struct.unpack_from('<II',data,8)
        stream_types=[struct.unpack_from('<I',data,directory+12*i)[0] for i in range(streams)]
        assert 6 in stream_types,('exception stream missing',stream_types)
        assert report['reason']==('message_box_w' if mode=='message_w' else 'message_box_a' if mode=='message_a' else 'unhandled_exception')
    results.append({'case':mode,'exit_code':result.returncode&0xffffffff,'elapsed_seconds':elapsed,'passed':True,'directory':str(folder)})
(OUT/'test-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps({'cases':len(results),'passed':True,'scope':'owned hidden hosts only; FXServer gameplay UNKNOWN'}))
