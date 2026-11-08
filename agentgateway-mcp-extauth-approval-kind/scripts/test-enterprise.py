#!/usr/bin/env python3
"""Exercise STS then MCP on the dedicated Enterprise cluster. Never print tokens."""
import concurrent.futures, json, os, pathlib, subprocess, time
PART = "part2"
NS = "mcp-extauth-demo"
EXTNS = 'mcp-extauth-demo'
CTX = "kind-" + os.environ.get("CLUSTER", "hitl-sts-" + PART)
GW = "http://extauth-gw.mcp-extauth-demo.svc.cluster.local:3000"
PATH = "/mcp"
TOOL = "delete_user"
ARGS = {'id': 'u-2'}

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
    # Keep header values as sent: agentgateway's MCP session id is case-sensitive.
    result_headers = {key.lower(): value for key, value in (line.split(": ", 1) for line in head.splitlines()[1:] if ": " in line)}
    return status, result_headers, response

def rpc(method, params=None, token=None, session=None, ident=1):
    body={"jsonrpc":"2.0","id":ident,"method":method}
    if params is not None: body["params"]=params
    return curl(GW+PATH, body, token, session)

def admin(path, body=None):
    status, _, body = curl("http://hitl-extauth-admin."+EXTNS+".svc.cluster.local:8081"+path, body)
    assert status in (200,204), "admin status " + str(status)
    return json.loads(body) if body else None

def park_and_capture(token, sid, args, ident, evidence_name, expect_agent):
    """Send delete_user, wait for it to park, save GET /pending, then reject it."""
    with concurrent.futures.ThreadPoolExecutor() as pool:
        future=pool.submit(rpc,'tools/call',{'name':TOOL,'arguments':args},token,sid,ident)
        end=time.monotonic()+25
        data=None
        while time.monotonic()<end:
            data=admin('/pending')
            if data['pending']: break
            if future.done(): raise AssertionError('tool call returned before parking, HTTP '+str(future.result()[0]))
            time.sleep(.25)
        assert data and data['pending'],'no pending tool call'
        pending=data['pending'][0]
        assert pending['user']=='bob','user missing'
        if expect_agent: assert pending.get('agent')==expect_agent,'agent missing'
        else: assert 'agent' not in pending,'direct call recorded an agent'
        assert pending['toolName']==TOOL and pending['toolArgs']==args,'tool arguments changed'
        assert all(x not in json.dumps(data) for x in [token,'Bearer ','authorization']),'credential leak'
        evidence=pathlib.Path(__file__).resolve().parents[1]/'evidence'
        evidence.mkdir(exist_ok=True)
        (evidence/evidence_name).write_text(json.dumps(data,indent=2)+'\n')
        print(json.dumps(data,separators=(',',':')))
        admin('/decide/'+pending['id'],{'approved':False,'reason':'platform reviewer test'})
        status,_,_=future.result(timeout=20)
        assert status==403,'rejected call was not blocked: '+str(status)

def bob_direct(user, kc):
    """Path 1: Bob calls MCP himself with his Keycloak token. No agent, no STS."""
    status,headers,_=rpc("initialize",{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bob-terminal","version":"1"}},token=user)
    assert status==200,"Bob's Keycloak token was not accepted: "+str(status)
    sid=headers.get("mcp-session-id")
    status,_,_=curl(GW+PATH,{"jsonrpc":"2.0","method":"notifications/initialized"},user,sid)
    assert status in (200,202,204),"initialised notification failed"
    park_and_capture(user,sid,ARGS.copy(),5,'pending-bob-direct.json',None)
    print('PASS Bob direct: queue shows user bob and no agent; reviewer rejected it')

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
    print('PASS Strict JWT rejects missing and invalid tokens')
    if PART=='part2':
        bob_direct(user, kc)
    status,headers,response=rpc("initialize",{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dba-agent","version":"1"}},token=delegated)
    assert status==200,"authenticated initialize failed: "+str(status)
    sid=headers.get("mcp-session-id")
    status,_,_=curl(GW+PATH,{"jsonrpc":"2.0","method":"notifications/initialized"},delegated,sid)
    assert status in (200,202,204),"initialised notification failed"
    status,_,response=rpc("tools/list",token=delegated,session=sid)
    assert status==200 and TOOL in response,"tools/list failed"
    names=[t['name'] for t in json.loads(next(l[6:] for l in response.splitlines() if l.startswith('data: ')))['result']['tools']]
    assert names==['get_users','delete_user'],'native MCP authorization did not hide wipe_users: '+str(names)
    print('tools/list', names)
    assert not admin('/pending')['pending'],"handshake parked"
    print('PASS authenticated initialize and tools/list do not park')
    if PART=='part2':
        status,_,response=rpc('tools/call',{'name':'get_users','arguments':{}},delegated,sid)
        assert status==200 and 'u-2' in response,'safe read failed'
        status,_,response=rpc('tools/call',{'name':'wipe_users','arguments':{}},delegated,sid)
        assert status==400 and '-32602' in response,'native MCP authorization did not refuse wipe_users: '+str(status)
        assert not admin('/pending')['pending'],'wipe_users parked'
        print('PASS get_users needs no approval; wipe_users hidden and refused by native MCP authorization')
    for approved in (True, False):
        args=ARGS.copy()
        if not approved:
            args={'id': 'u-3'}
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
    print('PASS queue empty; no raw credentials retained; cluster left running')

if __name__=='__main__': main()
