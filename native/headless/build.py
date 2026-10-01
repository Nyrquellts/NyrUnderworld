"""Build an explicit x64 headless DLL and owned test host; no install/download."""
from pathlib import Path
import argparse,json,os,shutil,subprocess

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'out'
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--minhook',type=Path,required=True)
    p.add_argument('--fault-injection',action='store_true',help='build a separate owned-host test DLL that fails after hook activation');a=p.parse_args()
    source=a.minhook.resolve(strict=True);OUT.mkdir(parents=True,exist_ok=True)
    vswhere=Path(os.environ.get('ProgramFiles(x86)','C:/Program Files (x86)'))/'Microsoft Visual Studio/Installer/vswhere.exe'
    vs=subprocess.check_output([str(vswhere),'-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'],text=True).strip()
    vcvars=Path(vs)/'VC/Auxiliary/Build/vcvarsall.bat'
    script=OUT/'capture-env.cmd';script.write_text(f'@echo off\ncall "{vcvars}" x64 >nul || exit /b 90\nset\n',encoding='ascii')
    env=dict(os.environ)
    for line in subprocess.check_output(['cmd.exe','/d','/c',str(script)],text=True).splitlines():
        key,sep,value=line.partition('=')
        if sep and key.upper() in ('PATH','INCLUDE','LIB','LIBPATH'):env[key.upper()]=value
    log=[]
    def run(args):
        args[0]=shutil.which(args[0],path=env['PATH']) or args[0]
        r=subprocess.run(args,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        log.append(subprocess.list2cmdline(args)+'\n'+r.stdout)
        (OUT/'build.log').write_text('\n'.join(log))
        if r.returncode:raise RuntimeError(r.stdout)
    run(['cl','/nologo','/O2','/MT','/TC','/c','/W3','/I'+str(source/'include'),*[str(source/'src'/n) for n in ('buffer.c','hook.c','trampoline.c','hde/hde64.c')]])
    run(['lib','/nologo','/OUT:minhook.lib','buffer.obj','hook.obj','trampoline.obj','hde64.obj'])
    common=['cl','/nologo','/O2','/W4','/WX','/EHsc','/std:c++20','/MT','/DUNICODE','/D_UNICODE','/I'+str(ROOT/'include')]
    library='nyr_headless_fault' if a.fault_injection else 'nyr_headless'
    host='headless_fault_host' if a.fault_injection else 'headless_host'
    flags=['/DNYR_HEADLESS_TEST_APPLY_FAILURE'] if a.fault_injection else []
    run([*common,*flags,'/LD','/I'+str(source/'include'),str(ROOT/'src/headless.cpp'),'/Fe:'+library+'.dll','/link','minhook.lib','dbghelp.lib','user32.lib','kernel32.lib','/DYNAMICBASE','/NXCOMPAT'])
    run([*common,str(ROOT/'test/host.cpp'),'/Fe:'+host+'.exe','/link',library+'.lib','user32.lib','kernel32.lib'])
    print(json.dumps({'architecture':'x64','dll':str(OUT/(library+'.dll')),'deployed':False,'fault_injection':a.fault_injection}))
if __name__=='__main__':main()
