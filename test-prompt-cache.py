#!/usr/bin/env python3
import argparse,json,time,urllib.request
from pathlib import Path

def post(port,path,body,timeout=2400):
 req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
 t=time.monotonic(); res=json.load(urllib.request.urlopen(req,timeout=timeout)); return res,time.monotonic()-t

def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--port',type=int,required=True); ap.add_argument('--source',required=True); ap.add_argument('--output',required=True); a=ap.parse_args()
 text=Path(a.source).read_text(errors='replace'); tok,_=post(a.port,'/tokenize',{'content':text}); ids=tok['tokens'][:100000]
 body={'prompt':ids,'n_predict':1,'temperature':0,'cache_prompt':True}
 first,t1=post(a.port,'/completion',body)
 _,td=post(a.port,'/completion',{'prompt':'Completely divergent cache checkpoint.','n_predict':1,'temperature':0,'cache_prompt':True})
 restored,t2=post(a.port,'/completion',body)
 out={'first_seconds':t1,'divergent_seconds':td,'restore_seconds':t2,'first_timings':first.get('timings'),'restore_timings':restored.get('timings'),'restore_cached_tokens':restored.get('tokens_cached')}
 Path(a.output).write_text(json.dumps(out,indent=2))
if __name__=='__main__': main()
