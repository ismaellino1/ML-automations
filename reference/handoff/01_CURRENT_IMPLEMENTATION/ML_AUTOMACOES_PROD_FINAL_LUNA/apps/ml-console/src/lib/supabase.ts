import { createClient } from "@supabase/supabase-js";
export const supabase=createClient(import.meta.env.VITE_SUPABASE_URL,import.meta.env.VITE_SUPABASE_ANON_KEY);
export async function control(business_id:string,action:string,args:Record<string,unknown>={}){
 const {data:{session}}=await supabase.auth.getSession(); if(!session) throw new Error("UNAUTHENTICATED");
 const r=await fetch(import.meta.env.VITE_ML_CONTROL_API_URL,{method:"POST",headers:{"content-type":"application/json",authorization:`Bearer ${session.access_token}`},
 body:JSON.stringify({business_id,action,arguments:args,idempotency_key:crypto.randomUUID(),request_id:crypto.randomUUID()})});
 const j=await r.json(); if(!r.ok||j?.ok===false) throw new Error(j?.code??"CONTROL_API_ERROR"); return j;
}
