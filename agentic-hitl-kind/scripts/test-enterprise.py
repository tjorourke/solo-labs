#!/usr/bin/env python3
"""Exercise STS then MCP on the dedicated Enterprise cluster. Never print tokens."""
import concurrent.futures, json, os, pathlib, subprocess, time
PART = "part1"
NS = "ops-tools"
EXTNS = 'hitl'
CTX = "kind-" + os.environ.get("CLUSTER", "hitl-sts-" + PART)
GW = "http://hitl-gateway.agentgateway-system.svc.cluster.local:80"
PATH = "/privileged/mcp"
TOOL = "run_migration"
ARGS = {'version': 'v3'}

def k(*args, data=None):
    return subprocess.run(["kubectl", "--context", CTX, *args], input=data, text=True, capture_output=True, check=True).stdout

def curl(url, body=None, token=None, session=None):
    config = ["silent", "show-error", "max-time = 90", "url = " + json.dumps(url)]
    headers = {"accept":"application/json, text/event-stream"}
    if body is not None:
        headers["content-type"] = "application/json" if isinstance(body, dict) else "application/x-www-form-urlencoded"
        config.append("data = " + json.dumps(json.dumps(body) if isinstance(body, dict) else body))
    if token: headers["authorization"] = "Bearer " + token
    if session: headers["mcp-session-id"] = session
    config += ["header = " + json.dumps(key + ": " + value) for key, value in headers.items()]
    raw = k("-n", NS, "exec", "-i", "dba-agent", "--", "curl", "-D", "-", "-K", "-", data="\n".join(config)+"\n")
    head, _, response = raw.replace("\r\n", "\n").partition("\n\n")
    status = int(head.splitlines()[0].split()[1])
    result_headers = dict(line.lower().split(": ", 1) for line in head.splitlines()[1:] if ": " in line)
    return status, result_headers, response

def rpc(method, params=None, token=None, session=None, ident=1):
    body={"jsonrpc":"2.0","id":ident,"method":method}
    if params is not None: body["params"]=params
    return curl(GW+PATH, body, token, session)

def admin(path, body=None):
    status, _, body = curl("http://hitl-extauth-admin."+EXTNS+".svc.cluster.local:8081"+path, body)
    assert status in (200,204), "admin status " + str(status)
    return json.loads(body) if body else None

def main():
    # Form values are encoded before transport. Tokens stay in memory and curl stdin.
    from urllib.parse import urlencode
    kc="http://keycloak.keycloak.svc.cluster.local:8080/realms/hitl-"+PART+"/protocol/openid-connect/token"
    status,_,response=curl(kc,urlencode({"grant_type":"password","client_id":"dba-client","username":"bob","password":"bob"}))
    assert status==200,"Keycloak failed " + str(status)
    user=json.loads(response)["access_token"]
    actor=k("-n",NS,"create","token","dba-agent","--duration=10m").strip()
    sts="http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token"
    def exchange(actor_token):
        return curl(sts,urlencode({"grant_type":"urn:ietf:params:oauth:grant-type:token-exchange","subject_token_type":"urn:ietf:params:oauth:token-type:jwt","subject_token":user,"actor_token_type":"urn:ietf:params:oauth:token-type:jwt","actor_token":actor_token,"audience":"hitl-mcp"}))
    status,_,response=exchange(actor)
    assert status==200,"STS exchange failed " + str(status)
    delegated=json.loads(response)["access_token"]
    import base64
    claims=json.loads(base64.urlsafe_b64decode(delegated.split('.')[1]+'==='))
    assert claims['preferred_username']=='bob' and claims['act']['sub']=='system:serviceaccount:'+NS+':dba-agent'
    print('PASS Bob token -> STS exchange as dba-agent')
    k("-n",NS,"apply","-f","-",data=json.dumps({"apiVersion":"v1","kind":"ServiceAccount","metadata":{"name":"rogue-agent","namespace":NS}}))
    rogue=k("-n",NS,"create","token","rogue-agent","--duration=10m").strip()
    denied,_,result=exchange(rogue)
    assert denied>=400 and json.loads(result).get('error')=='unauthorized_client','may_act did not reject rogue actor'
    print('PASS may_act rejects an unlisted actor')
    status,_,_=rpc("initialize",{})
    assert status==401,"unauthenticated initialize was not rejected: "+str(status)
    status,_,_=rpc("initialize",{},token="invalid")
    assert status==401,"invalid token was not rejected"
    status,_,_=rpc("initialize",{},token=user)
    assert status==401,"Keycloak token was accepted without STS delegation"
    print('PASS Strict JWT rejects missing, invalid and non-STS tokens')
    status,headers,response=rpc("initialize",{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dba-agent","version":"1"}},token=delegated)
    assert status==200,"authenticated initialize failed: "+str(status)
    sid=headers.get("mcp-session-id")
    status,_,_=curl(GW+PATH,{"jsonrpc":"2.0","method":"notifications/initialized"},delegated,sid)
    assert status in (200,202,204),"initialised notification failed"
    status,_,response=rpc("tools/list",token=delegated,session=sid)
    assert status==200 and TOOL in response,"tools/list failed"
    assert not admin('/pending')['pending'],"handshake parked"
    print('PASS authenticated initialize and tools/list do not park')
    if PART=='part2':
        status,_,response=rpc('tools/call',{'name':'get_users','arguments':{}},delegated,sid)
        assert status==200 and 'u-2' in response,'safe read failed'
        status,_,response=rpc('tools/call',{'name':'wipe_users','arguments':{}},delegated,sid)
        assert status==403 and 'default deny' in response,'unlisted tool was not denied'
        print('PASS ConfigMap allow and default deny')
    for approved in (True, False):
        args=ARGS.copy()
        if not approved:
            args={'version': 'v4'}
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future=pool.submit(rpc,'tools/call',{'name':TOOL,'arguments':args},delegated,sid,2 if approved else 3)
            end=time.monotonic()+25
            pending=None
            while time.monotonic()<end:
                data=admin('/pending')
                if data['pending']:
                    pending=data['pending'][0]; break
                if future.done(): raise AssertionError('tool call returned before parking, HTTP '+str(future.result()[0]))
                time.sleep(.25)
            assert pending,'no pending tool call'
            assert pending['user']=='bob' and pending['agent']=='dba-agent', 'identity missing'
            assert pending['toolName']==TOOL and pending['toolArgs']==args,'tool arguments changed'
            raw=json.dumps(data)
            assert all(secret not in raw for secret in [user,actor,delegated,'Bearer ','authorization']), 'credential leak'
            assert not future.done(),'tool call not blocked'
            if approved:
                evidence=pathlib.Path(__file__).resolve().parents[1]/'evidence'
                evidence.mkdir(exist_ok=True)
                (evidence/'pending-enterprise.json').write_text(json.dumps(data,indent=2)+'\n')
                print(json.dumps(data,separators=(',',':')))
            admin('/decide/'+pending['id'],{'approved':approved,'reason':'platform reviewer test'})
            status,_,result=future.result(timeout=20)
            assert status==(200 if approved else 403), 'unexpected decision response '+str(status)
            assert ('isError":true' not in result.replace(' ','')), 'MCP tool returned an error'
            print('PASS '+('approve releases' if approved else 'reject blocks')+' '+TOOL)
    assert not admin('/pending')['pending'],'queue not empty'
    if PART=='part2':
        _,_,response=rpc('tools/call',{'name':'get_users','arguments':{}},delegated,sid)
        assert 'u-2' not in response and 'u-3' in response,'approval/rejection backend state mismatch'
        print('PASS u-2 deleted, rejected u-3 retained')
    status,_,response=curl('http://ops-tools.ops-tools.svc.cluster.local:8080/state')
    assert status==200 and json.loads(response)['schema_version']=='v3','rejected migration changed backend state'
    status,_,response=curl(GW+'/public/mcp',{'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'cluster_db_query','arguments':{'sql':'SELECT * FROM orders'}}},delegated)
    assert status==200 and 'acme' in response,'public path read failed'
    assert not admin('/pending')['pending'],'public path parked'
    print('PASS approved v3 persisted; rejected v4 absent; public read unparked')
    print('PASS queue empty; no raw credentials retained; cluster left running')

if __name__=='__main__': main()
