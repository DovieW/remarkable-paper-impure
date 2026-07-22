import { createHash, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";

type Action = { id:string; kind:string; session_key:string; agent_id?:string; title?:string; message_id?:string; text?:string; value?:boolean };
type Receipt = { id:string; status:"completed"|"failed"; detail:string };
type Logger = { info:(message:string)=>void; warn:(message:string)=>void; error:(message:string)=>void };
type Api = { config:any; runtime:any; registerService:(service:any)=>void; logger:Logger };
type BridgeState = { version:1; owned_sessions:Record<string,string> };

let controller:AbortController|undefined;
const activeRuns=new Map<string,AbortController>();
const jobs=new Map<string,Promise<void>>();
const receipts=new Map<string,Receipt>();
const historyVersions=new Map<string,string>();
const derivedTitles=new Map<string,string>();
const ownedSessions=new Map<string,string>();
const workerId=`paperchat-${randomUUID()}`;
const leaseSeconds=45;
const sleep=(ms:number,signal:AbortSignal)=>new Promise<void>((resolve)=>{const timer=setTimeout(resolve,ms);signal.addEventListener("abort",()=>{clearTimeout(timer);resolve();},{once:true});});
const stableId=(...parts:string[])=>createHash("sha256").update(parts.join("\0")).digest("hex").slice(0,40);

function configuration(){
  const relay=process.env.PAPERCHAT_RELAY_URL?.replace(/\/+$/,"");
  const device=process.env.PAPERCHAT_DEVICE_ID;
  const token=process.env.PAPERCHAT_RELAY_TOKEN;
  const statePath=process.env.PAPERCHAT_STATE_PATH||join(homedir(),".openclaw","paperchat-bridge-state.json");
  if(!relay?.startsWith("https://")||!device||!token)throw new Error("PaperChat bridge environment is incomplete");
  return{relay,device,token,statePath};
}

async function relay(path:string,init:RequestInit={}){
  const cfg=configuration();
  const response=await fetch(`${cfg.relay}${path}`,{...init,headers:{authorization:`Bearer ${cfg.token}`,"content-type":"application/json",...(init.headers||{})},signal:init.signal});
  if(!response.ok)throw new Error(`relay ${response.status}`);
  return response.status===204?{}:response.json();
}

async function loadState(){
  const {statePath}=configuration();
  ownedSessions.clear();
  try{
    const parsed=JSON.parse(await readFile(statePath,"utf8")) as BridgeState;
    for(const [key,since] of Object.entries(parsed.owned_sessions||{}))ownedSessions.set(key,since);
  }catch(error:any){if(error?.code!=="ENOENT")throw error;}
}

async function saveState(){
  const {statePath}=configuration();
  await mkdir(dirname(statePath),{recursive:true,mode:0o700});
  const temporary=`${statePath}.tmp.${process.pid}`;
  await writeFile(temporary,JSON.stringify({version:1,owned_sessions:Object.fromEntries(ownedSessions)},null,2)+"\n",{mode:0o600});
  await rename(temporary,statePath);
}

async function ownSession(key:string){
  if(ownedSessions.has(key))return;
  ownedSessions.set(key,new Date().toISOString());
  await saveState();
}

function textContent(content:unknown){
  if(Array.isArray(content))return content.map((part)=>part&&typeof part==="object"&&"text" in part?String((part as any).text):"").filter(Boolean).join("\n");
  return typeof content==="string"?content:"";
}

async function history(sessionKey:string,entry:any){
  if(!entry?.sessionFile)return[];
  try{
    const lines=(await readFile(entry.sessionFile,"utf8")).split("\n");
    const messages:any[]=[];
    for(const line of lines){
      if(!line.trim())continue;
      const row=JSON.parse(line),message=row.message??(row.type==="message"?row:undefined);
      if(!message||!["user","assistant"].includes(message.role))continue;
      const body=textContent(message.content??message.text);if(!body)continue;
      const created=new Date(message.timestamp??row.timestamp??Date.now()).toISOString();
      const previous=messages.at(-1);
      if(message.role==="assistant"&&previous?.role==="assistant"&&previous.body===body)continue;
      messages.push({id:String(message.id??row.id??stableId(sessionKey,message.role,created,body)),session_key:sessionKey,role:message.role,status:"complete",body,asset_id:null,run_id:null,created_at:created});
    }
    return messages.slice(-500);
  }catch{return[];}
}

function derivedTitle(messages:any[],channel:string,updatedAt:unknown){
  const firstUser=messages.find((message)=>message.role==="user")?.body;
  if(firstUser){
    const compact=String(firstUser).replace(/[`*_>#\[\]()]/g," ").replace(/\s+/g," ").trim();
    if(compact.length)return compact.length<=72?compact:`${compact.slice(0,69).trimEnd()}…`;
  }
  const name=(channel||"web").replace(/[-_]+/g," ").replace(/\b\w/g,(value)=>value.toUpperCase());
  const date=new Date(Number(updatedAt)||Date.now()).toISOString().slice(0,10);
  return `${name} chat · ${date}`;
}

function agentIds(api:Api){
  const rows=Array.isArray(api.config?.agents?.list)?api.config.agents.list:[];
  return[...new Set(["main",...rows.map((row:any)=>String(row.id||"")).filter(Boolean)])];
}

function entries(api:Api){
  const seen=new Map<string,{agentId:string;entry:any}>();
  for(const agentId of agentIds(api))for(const row of api.runtime.agent.session.listSessionEntries({agentId})??[]){
    if(row?.sessionKey&&!seen.has(row.sessionKey))seen.set(row.sessionKey,{agentId,entry:row.entry});
  }
  return seen;
}

async function inventory(api:Api,owned:Map<string,string>=ownedSessions){
  const selected=[...entries(api)].filter(([key])=>![":global:",":unknown:",":system:"].some((part)=>key.includes(part)))
    .sort((left,right)=>Number(right[1].entry?.updatedAt||0)-Number(left[1].entry?.updatedAt||0)).slice(0,100);
  const messages:any[]=[];
  const replaceSessionMessages:string[]=[];
  for(const [key,{entry}] of selected){
    if(owned.has(key))continue;
    const version=String(entry?.updatedAt||"");if(historyVersions.get(key)===version)continue;
    const imported=await history(key,entry);
    messages.push(...imported);replaceSessionMessages.push(key);historyVersions.set(key,version);
    const channel=String(entry.lastChannel||entry.origin?.surface||entry.origin?.provider||"web");
    derivedTitles.set(key,derivedTitle(imported,channel,entry.updatedAt));
  }
  const sessions=selected.map(([key,{agentId,entry}])=>{
    const channel=String(entry.lastChannel||entry.origin?.surface||entry.origin?.provider||"web");
    const explicit=String(entry.label||entry.displayName||"").trim();
    const title=explicit&&explicit.toLowerCase()!=="conversation"?explicit:derivedTitles.get(key)||derivedTitle([],channel,entry.updatedAt);
    return{session_key:key,agent_id:agentId,channel,title,updated_at:new Date(entry.updatedAt||Date.now()).toISOString(),archived:Boolean(entry.archivedAt),run_status:activeRuns.has(key)?"working":"idle",run_id:null};
  });
  return{agents:agentIds(api).map((id)=>({id,name:id})),sessions,messages,replace_session_messages:replaceSessionMessages};
}

async function sync(payload:Record<string,unknown>,signal?:AbortSignal){
  const cfg=configuration();
  await relay(`/v2/integrations/openclaw/${encodeURIComponent(cfg.device)}/chat/sync`,{method:"POST",body:JSON.stringify(payload),signal});
}

async function renewLease(actionId:string){
  const cfg=configuration();
  await relay(`/v2/integrations/openclaw/${encodeURIComponent(cfg.device)}/chat/actions/${encodeURIComponent(actionId)}/lease`,{method:"POST",body:JSON.stringify({worker_id:workerId,lease_seconds:leaseSeconds}),signal:controller?.signal});
}

async function claimAction():Promise<Action|null>{
  const cfg=configuration();
  const response=await relay(`/v2/integrations/openclaw/${encodeURIComponent(cfg.device)}/chat/actions/claim`,{method:"POST",body:JSON.stringify({worker_id:workerId,lease_seconds:leaseSeconds}),signal:controller?.signal}) as any;
  return response?.action??null;
}

async function executeSend(api:Api,action:Action,logger:Logger,run:AbortController):Promise<Receipt>{
  try{
    const known=entries(api).get(action.session_key),agentId=action.agent_id||known?.agentId||"main",sessionId=known?.entry?.sessionId||action.session_key.replace(/^paperchat:/,"")||randomUUID();
    let partial="",lastText="",lastStatus="";
    const created=new Date().toISOString(),messageId=stableId(action.session_key,"assistant",action.id);
    const workspaceDir=api.runtime.agent.resolveAgentWorkspaceDir(api.config,agentId);
    const publish=async(text:string,status:"streaming"|"complete")=>{
      if(!text||(text===lastText&&status===lastStatus))return;
      lastText=text;lastStatus=status;
      await sync({messages:[{id:messageId,session_key:action.session_key,role:"assistant",status,body:text,asset_id:null,run_id:action.id,created_at:created}]},controller?.signal)
        .catch((error)=>logger.warn(`paperchat stream sync: ${error instanceof Error?error.message:"failed"}`));
    };
    const result=await api.runtime.agent.runEmbeddedAgent({sessionId,sessionKey:action.session_key,agentId,workspaceDir,config:api.config,prompt:action.text||"",trigger:"user",messageChannel:"paperchat",messageProvider:"paperchat",chatType:"direct",senderIsOwner:true,disableMessageTool:true,timeoutMs:300_000,runId:action.id,abortSignal:run.signal,onPartialReply:async(payload:any)=>{const next=String(payload?.text||"");partial=next.length>=partial.length?next:partial+next;if(partial.endsWith("\n\n")||partial.length-lastText.length>=700)await publish(partial,"streaming");}});
    const final=(result?.payloads??[]).map((item:any)=>String(item?.text||"")).filter(Boolean).join("\n\n")||partial;
    await publish(final,"complete");
    return{id:action.id,status:"completed",detail:""};
  }catch(error){return{id:action.id,status:"failed",detail:run.signal.aborted?"Stopped by user.":error instanceof Error?error.message.slice(0,300):"run failed"};}
  finally{activeRuns.delete(action.session_key);}
}

async function immediateAction(api:Api,action:Action):Promise<Receipt>{
  try{
    const known=entries(api).get(action.session_key),agentId=action.agent_id||known?.agentId||"main";
    if(action.kind==="abort")activeRuns.get(action.session_key)?.abort();
    else if(action.kind==="rename")await api.runtime.agent.session.patchSessionEntry({sessionKey:action.session_key,agentId,update:()=>({label:action.title})});
    else if(action.kind==="archive")await api.runtime.agent.session.patchSessionEntry({sessionKey:action.session_key,agentId,update:()=>({archivedAt:action.value===false?undefined:Date.now()})});
    return{id:action.id,status:"completed",detail:""};
  }catch(error){return{id:action.id,status:"failed",detail:error instanceof Error?error.message.slice(0,300):"action failed"};}
}

function startAction(api:Api,action:Action,logger:Logger){
  if(jobs.has(action.id))return;
  const job=(async()=>{
    if(["create","send","retry","regenerate"].includes(action.kind))await ownSession(action.session_key);
    let leaseLost=false;
    const leaseTimer=setInterval(()=>{void renewLease(action.id).catch((error)=>{leaseLost=true;activeRuns.get(action.session_key)?.abort();logger.warn(`paperchat lease: ${error instanceof Error?error.message:"lost"}`);});},10_000);
    try{
      let receipt:Receipt;
      if(["send","retry","regenerate"].includes(action.kind)){const run=new AbortController();activeRuns.set(action.session_key,run);receipt=await executeSend(api,action,logger,run);}
      else receipt=await immediateAction(api,action);
      if(leaseLost)receipt={id:action.id,status:"failed",detail:"Bridge lost ownership of this action."};
      receipts.set(receipt.id,receipt);
    }finally{clearInterval(leaseTimer);}
  })().catch((error)=>{receipts.set(action.id,{id:action.id,status:"failed",detail:error instanceof Error?error.message.slice(0,300):"bridge failed"});}).finally(()=>jobs.delete(action.id));
  jobs.set(action.id,job);
}

async function flushSync(api:Api,inventoryDue:boolean,signal:AbortSignal){
  const base=inventoryDue?await inventory(api):{agents:[],sessions:[],messages:[],replace_session_messages:[]};
  const done=[...receipts.values()];
  if(!inventoryDue&&!done.length)return;
  await sync({...base,receipts:done,error:null},signal);
  for(const receipt of done)receipts.delete(receipt.id);
}

async function run(api:Api,logger:Logger,signal:AbortSignal){
  let nextInventory=0;
  while(!signal.aborted){
    try{
      while(jobs.size<4){const action=await claimAction();if(!action)break;startAction(api,action,logger);}
      const inventoryDue=Date.now()>=nextInventory;
      await flushSync(api,inventoryDue,signal);
      if(inventoryDue)nextInventory=Date.now()+15_000;
    }catch(error){if(!signal.aborted)logger.warn(`paperchat bridge: ${error instanceof Error?error.message:"poll failed"}`);}
    await sleep(1500,signal);
  }
}

export const __testing={inventory,textContent,stableId,derivedTitle,history};
export default{id:"paperchat",name:"Paperboard Chat",description:"Private Paper Pure chat bridge",register(api:Api){api.registerService({id:"paperchat-bridge",start:async()=>{controller=new AbortController();await loadState();api.logger.info("paperchat bridge starting");void run(api,api.logger,controller.signal);},stop:async()=>{controller?.abort();for(const run of activeRuns.values())run.abort();await Promise.allSettled(jobs.values());controller=undefined;}});}};
