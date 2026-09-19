import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"access-control-allow-origin":"*","access-control-allow-headers":"authorization,content-type","access-control-allow-methods":"POST,OPTIONS"};
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"content-type":"application/json"}});

serve(async(req)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  if(req.method!=="POST") return out({ok:false,code:"METHOD_NOT_ALLOWED"},405);
  const url=Deno.env.get("SUPABASE_URL")!, anon=Deno.env.get("SUPABASE_ANON_KEY")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=req.headers.get("authorization")??"";
  const userClient=createClient(url,anon,{global:{headers:{authorization:auth}}});
  const {data:{user},error}=await userClient.auth.getUser();
  if(error||!user) return out({ok:false,code:"UNAUTHENTICATED"},401);
  const admin=createClient(url,service,{auth:{persistSession:false}});
  const body=await req.json();
  const {data,error:rpcError}=await admin.schema("core").rpc("execute_control_plane_action_v2",{
    p_actor_user_id:user.id,p_business_id:body.business_id,p_action:body.action,
    p_arguments:body.arguments??{},p_idempotency_key:body.idempotency_key??crypto.randomUUID(),
    p_execution_ref:body.request_id??crypto.randomUUID()
  });
  if(rpcError) return out({ok:false,code:"RPC_FAILED",message:rpcError.message},400);
  return out(data,200);
});
