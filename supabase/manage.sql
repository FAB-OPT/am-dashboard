-- ═══════════════════════════════════════════════════════════════
--  ให้ VP จัดการผู้ดูแลและสาขาได้ (นอกจาก Admin)
--  วิธีใช้: Supabase → SQL Editor → วางทั้งไฟล์ → Run · รันซ้ำได้ ไม่ลบข้อมูล
--
--  VP ทำได้:  เพิ่ม/ลบ/ย้ายสาขา · เพิ่ม/ลบผู้ดูแล · แก้ชื่อ
--  VP ทำไม่ได้: เห็นหรือแก้รหัสเข้าใช้ของใคร (ตั้งได้เฉพาะผู้ดูแลที่เพิ่มใหม่ ครั้งเดียว)
--  ลบสาขา = ย้ายไปไว้ใน archived ในผัง ตัวเลขใน am_entries ไม่ถูกลบ กู้คืนได้
-- ═══════════════════════════════════════════════════════════════

-- รหัสนี้ยังว่างไหม · ตอบแค่ใช่/ไม่ใช่ ไม่บอกว่าชนกับของใคร
create or replace function public.am_code_free(p_code text, p_candidate text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r text; v jsonb; c text;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  if r not in ('admin','vp') then raise exception 'ไม่มีสิทธิ์' using errcode = '42501'; end if;

  c := lower(btrim(coalesce(p_candidate, '')));
  if c = '' then return false; end if;

  select value into v from public.am_config where key = 'main';
  if v is null then return true; end if;
  if c = lower(btrim(coalesce(v->>'adminCode',''))) or c = lower(btrim(coalesce(v->>'vpCode',''))) then
    return false;
  end if;
  return not exists (
    select 1 from jsonb_array_elements(coalesce(v->'zones','[]'::jsonb)) z
    where lower(btrim(coalesce(z->>'code',''))) = c);
end $$;

-- บันทึกผังผู้ดูแลและสาขา (ใช้โดย VP · Admin ยังใช้ am_set_config ได้ตามเดิม)
-- p_value = {"zones":[{id,name,full,brand,code?,branches:[{id,name}]}], "archived":[...], "nextId":n}
create or replace function public.am_set_structure(p_code text, p_value jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare r text; cur jsonb; z jsonb; old jsonb; zout jsonb := '[]'::jsonb; c text; dup int;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  if r not in ('admin','vp') then raise exception 'ไม่มีสิทธิ์จัดการสาขา' using errcode = '42501'; end if;
  if p_value is null or jsonb_typeof(p_value->'zones') is distinct from 'array' then
    raise exception 'ผังไม่ถูกต้อง' using errcode = '22023';
  end if;
  if jsonb_array_length(p_value->'zones') = 0 then
    raise exception 'ต้องมีผู้ดูแลอย่างน้อย 1 คน' using errcode = '22023';
  end if;

  select value into cur from public.am_config where key = 'main' for update;
  cur := coalesce(cur, '{}'::jsonb);

  for z in select * from jsonb_array_elements(p_value->'zones') loop
    if coalesce(z->>'id','') = '' then raise exception 'ผังไม่ถูกต้อง' using errcode = '22023'; end if;
    old := null;
    select o into old from jsonb_array_elements(coalesce(cur->'zones','[]'::jsonb)) o
      where o->>'id' = z->>'id' limit 1;
    if old is not null and coalesce(old->>'code','') <> '' then
      z := jsonb_set(z, '{code}', old->'code');             -- ผู้ดูแลเดิม: ใช้รหัสเดิมเสมอ
    else
      c := btrim(coalesce(z->>'code',''));                  -- ผู้ดูแลใหม่: ต้องตั้งรหัสมา
      if c = '' then raise exception 'ผู้ดูแลใหม่ต้องมีรหัสเข้าใช้' using errcode = '22023'; end if;
      z := jsonb_set(z, '{code}', to_jsonb(c));
    end if;
    zout := zout || jsonb_build_array(z);
  end loop;

  -- รหัสห้ามซ้ำกันเอง และห้ามชนรหัส VP / Admin
  select count(*) - count(distinct lower(btrim(x->>'code'))) into dup
  from jsonb_array_elements(zout) x;
  if dup > 0 or exists (
       select 1 from jsonb_array_elements(zout) x
       where lower(btrim(x->>'code')) in (lower(btrim(coalesce(cur->>'adminCode',''))),
                                          lower(btrim(coalesce(cur->>'vpCode',''))))) then
    raise exception 'รหัสเข้าใช้ซ้ำ' using errcode = '23505';
  end if;

  cur := jsonb_set(cur, '{zones}', zout);
  cur := jsonb_set(cur, '{archived}', coalesce(p_value->'archived', '[]'::jsonb));
  cur := jsonb_set(cur, '{nextId}', to_jsonb(greatest(
           coalesce((cur->>'nextId')::numeric, 0),
           coalesce((p_value->>'nextId')::numeric, 0))));

  insert into public.am_config (key, value, updated_at) values ('main', cur, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  -- สำเนาแบน สาขา → ผู้ดูแล ที่ใช้ตัดสินสิทธิ์รายแถว
  insert into public.am_branches (branch_id, zone_id, name, updated_at)
  select b->>'id', zz->>'id', b->>'name', now()
  from jsonb_array_elements(zout) zz,
       jsonb_array_elements(coalesce(zz->'branches','[]'::jsonb)) b
  on conflict (branch_id) do update
    set zone_id = excluded.zone_id, name = excluded.name, updated_at = now();

  -- สาขาที่ไม่อยู่ในผังแล้ว (รวมที่ถูกลบไปไว้ archived) ผู้ดูแลโซนแก้ไม่ได้อีก แต่ตัวเลขยังอยู่
  delete from public.am_branches x
  where not exists (
    select 1 from jsonb_array_elements(zout) zz,
                  jsonb_array_elements(coalesce(zz->'branches','[]'::jsonb)) b
    where b->>'id' = x.branch_id);
end $$;

grant execute on function
  public.am_code_free(text, text),
  public.am_set_structure(text, jsonb)
to anon;

-- ตรวจว่าติดตั้งแล้ว: ควรเห็น 2 แถว
select proname from pg_proc where proname in ('am_code_free','am_set_structure');
