
-- 044_catalog_knowledge_media.sql
CREATE TABLE IF NOT EXISTS core.product_categories(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,name TEXT NOT NULL,slug TEXT NOT NULL,
 description TEXT,active BOOLEAN NOT NULL DEFAULT true,display_order INTEGER NOT NULL DEFAULT 0,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,slug));
CREATE TABLE IF NOT EXISTS core.products(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,category_id UUID REFERENCES core.product_categories(id) ON DELETE SET NULL,
 sku TEXT,name TEXT NOT NULL,description TEXT,price NUMERIC(12,2),currency CHAR(3) NOT NULL DEFAULT 'BRL',
 stock_status TEXT NOT NULL DEFAULT 'UNKNOWN' CHECK(stock_status IN('IN_STOCK','LOW_STOCK','OUT_OF_STOCK','UNKNOWN')),
 active BOOLEAN NOT NULL DEFAULT true,tags TEXT[] NOT NULL DEFAULT '{}',attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,sku));
CREATE INDEX IF NOT EXISTS idx_products_business_active ON core.products(business_id,active,name);

CREATE TABLE IF NOT EXISTS core.knowledge_documents(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,external_key TEXT NOT NULL,title TEXT NOT NULL,
 content TEXT NOT NULL,metadata JSONB NOT NULL DEFAULT '{}'::jsonb,active BOOLEAN NOT NULL DEFAULT true,
 search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple',coalesce(title,'')||' '||coalesce(content,''))) STORED,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,external_key));
CREATE INDEX IF NOT EXISTS idx_knowledge_fts ON core.knowledge_documents USING GIN(search_vector);

CREATE TABLE IF NOT EXISTS core.media_assets(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),business_id UUID NOT NULL,message_id UUID,
 provider TEXT NOT NULL DEFAULT 'META',media_id TEXT NOT NULL,mime_type TEXT,filename TEXT,caption TEXT,
 processing_status TEXT NOT NULL DEFAULT 'PENDING' CHECK(processing_status IN('PENDING','PROCESSING','READY','FAILED')),
 transcript TEXT,visual_description TEXT,document_text TEXT,summary TEXT,language TEXT,confidence NUMERIC(5,4),
 safety_notes JSONB NOT NULL DEFAULT '[]'::jsonb,provider_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(business_id,provider,media_id));

CREATE OR REPLACE FUNCTION core.upsert_knowledge_document_v1(
 p_business_id UUID,p_external_key TEXT,p_title TEXT,p_content TEXT,p_metadata JSONB DEFAULT '{}'::jsonb,p_execution_ref TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
 INSERT INTO core.knowledge_documents(business_id,external_key,title,content,metadata)
 VALUES(p_business_id,p_external_key,p_title,p_content,coalesce(p_metadata,'{}'::jsonb))
 ON CONFLICT(business_id,external_key) DO UPDATE SET title=excluded.title,content=excluded.content,
 metadata=excluded.metadata,active=true,updated_at=now()
 RETURNING id INTO v_id;
 RETURN jsonb_build_object('ok',true,'code','KNOWLEDGE_UPSERTED','document_id',v_id);
END $$;

CREATE OR REPLACE FUNCTION core.search_business_knowledge_v1(p_business_id UUID,p_query TEXT,p_limit INTEGER DEFAULT 8)
RETURNS JSONB LANGUAGE sql STABLE AS $$
SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM (
 SELECT id,title,left(content,3000) content,metadata,
        ts_rank(search_vector,plainto_tsquery('simple',coalesce(p_query,''))) rank
 FROM core.knowledge_documents
 WHERE business_id=p_business_id AND active=true
   AND (nullif(btrim(p_query),'') IS NULL OR search_vector @@ plainto_tsquery('simple',p_query))
 ORDER BY rank DESC,updated_at DESC LIMIT greatest(1,least(coalesce(p_limit,8),20))
) x $$;

CREATE OR REPLACE FUNCTION core.get_catalog_context_v1(p_business_id UUID,p_limit INTEGER DEFAULT 50)
RETURNS JSONB LANGUAGE sql STABLE AS $$
SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.name,'description',p.description,
 'price',p.price,'currency',p.currency,'stock_status',p.stock_status,'tags',p.tags,'attributes',p.attributes)
 ORDER BY p.name),'[]'::jsonb)
FROM core.products p WHERE p.business_id=p_business_id AND p.active=true
LIMIT greatest(1,least(coalesce(p_limit,50),100)) $$;

CREATE OR REPLACE FUNCTION core.claim_media_processing_batch(p_limit INTEGER,p_worker_ref TEXT)
RETURNS TABLE(job JSONB) LANGUAGE sql AS $$
SELECT jsonb_build_object(
 'job_id',j.id,'business_id',j.business_id,'media_asset_id',(j.payload->>'media_asset_id')::uuid,
 'media_id',j.payload->>'media_id','media_type',j.payload->>'media_type','mime_type',j.payload->>'mime_type',
 'filename',j.payload->>'filename','caption',j.payload->>'caption','message_id',j.payload->>'message_id',
 'graph_api_version',coalesce(j.payload->>'graph_api_version','v26.0'))
FROM core.claim_integration_jobs_v1('MEDIA_PROCESS',p_limit,p_worker_ref,300) q(job)
JOIN LATERAL jsonb_to_record(q.job) AS j0(id uuid,business_id uuid,payload jsonb) ON true
JOIN core.integration_jobs j ON j.id=j0.id $$;

CREATE OR REPLACE FUNCTION core.complete_media_processing_job(p_job_id UUID,p_result JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE j core.integration_jobs%rowtype; a_id UUID; a core.media_assets%rowtype; conv_payload JSONB;
BEGIN
 SELECT * INTO j FROM core.integration_jobs WHERE id=p_job_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','JOB_NOT_FOUND'); END IF;
 a_id:=(j.payload->>'media_asset_id')::uuid;
 UPDATE core.media_assets SET processing_status='READY',
  transcript=nullif(p_result->>'transcript',''),visual_description=nullif(p_result->>'visual_description',''),
  document_text=nullif(p_result->>'document_text',''),summary=nullif(p_result->>'summary',''),
  language=nullif(p_result->>'language',''),confidence=nullif(p_result->>'confidence','')::numeric,
  safety_notes=coalesce(p_result->'safety_notes','[]'::jsonb),updated_at=now()
 WHERE id=a_id RETURNING * INTO a;
 conv_payload := j.payload->'conversation_payload' ||
   jsonb_build_object('media_context',jsonb_build_object('media_asset_id',a.id,'transcript',a.transcript,
   'visual_description',a.visual_description,'document_text',a.document_text,'summary',a.summary,
   'language',a.language,'confidence',a.confidence,'safety_notes',a.safety_notes));
 PERFORM core.enqueue_integration_job_v1(j.business_id,'CONVERSATION_TURN','PROCESS',conv_payload,
  'CONVERSATION:'||(j.payload->>'message_id'),'MESSAGE',(j.payload->>'message_id')::uuid,50,5,now(),j.correlation_id,j.id);
 PERFORM core.complete_integration_job_v1(p_job_id,p_result);
 RETURN jsonb_build_object('ok',true,'code','MEDIA_READY','media_asset_id',a_id);
END $$;

CREATE OR REPLACE FUNCTION core.fail_media_processing_job(p_job_id UUID,p_error TEXT,p_payload JSONB)
RETURNS JSONB LANGUAGE sql AS $$
SELECT core.fail_integration_job_v1(p_job_id,p_error,p_payload) $$;
