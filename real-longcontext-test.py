#!/usr/bin/env python3
"""Real OpenAI-compatible 100K agent-shaped prefill and retrieval test."""
import argparse, json, urllib.request
from pathlib import Path


def post(port,path,body,timeout=2400):
    req=urllib.request.Request(f"http://127.0.0.1:{port}{path}",data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(req,timeout=timeout))


def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--port",type=int,required=True); ap.add_argument("--source",required=True); ap.add_argument("--output",required=True); ap.add_argument("--tokens",type=int,default=100000); a=ap.parse_args()
    text=Path(a.source).read_text(errors="replace")
    ids=post(a.port,"/tokenize",{"content":text})["tokens"]
    if len(ids)<a.tokens: ids=(ids*((a.tokens//max(len(ids),1))+1))[:a.tokens]
    else: ids=ids[:a.tokens]
    marks=[
      post(a.port,"/tokenize",{"content":"\nANCHOR_ALPHA=R9700-731-ALPHA\n"})["tokens"],
      post(a.port,"/tokenize",{"content":"\nANCHOR_BETA=X299-262144-BETA\n"})["tokens"],
      post(a.port,"/tokenize",{"content":"\nANCHOR_GAMMA=SDMA-MTP-GAMMA\n"})["tokens"],
    ]
    for pos,mark in sorted(zip((5000,50000,95000),marks),reverse=True): ids[pos:pos]=mark
    query=post(a.port,"/tokenize",{"content":"\nReturn exactly one line: ALPHA=R9700-731-ALPHA; BETA=X299-262144-BETA; GAMMA=SDMA-MTP-GAMMA\n"})["tokens"]
    ids.extend(query)
    content=post(a.port,"/detokenize",{"tokens":ids})["content"]
    res=post(a.port,"/v1/chat/completions",{
      "model":"real100k","messages":[{"role":"user","content":content}],"max_tokens":128,"temperature":0,
      "chat_template_kwargs":{"enable_thinking":False}
    })
    expected="ALPHA=R9700-731-ALPHA; BETA=X299-262144-BETA; GAMMA=SDMA-MTP-GAMMA"
    msg=res["choices"][0]["message"]
    out={"requested_tokens":a.tokens,"actual_prompt_tokens":res["usage"]["prompt_tokens"],"content":msg.get("content"),"reasoning_content":msg.get("reasoning_content"),"exact":msg.get("content","").strip()==expected,"usage":res.get("usage"),"timings":res.get("timings")}
    Path(a.output).write_text(json.dumps(out,indent=2))

if __name__=="__main__": main()
