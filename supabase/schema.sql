-- ═══════════════════════════════════════════════════════════════
--  Area Manager Performance Dashboard — Supabase schema
--  วิธีใช้: Supabase → SQL Editor → วางทั้งไฟล์ → Run
--  รันซ้ำได้ ไม่ลบข้อมูลเดิม
--
--  ⚠️ โปรเจกต์นี้ใช้กับแดชบอร์ด AM เท่านั้น
--     ห้ามใช้ฐานร่วมกับ FAB Operations Hub หรือ Training Record
--
--  ═══ วิธีคุมสิทธิ์: ใช้ "รหัสเข้าใช้งาน" ช่องเดียวเหมือนเดิม ═══
--  หน้าเว็บแตะตารางตรง ๆ ไม่ได้เลย — ต้องเรียกผ่านฟังก์ชันข้างล่างนี้
--  และทุกฟังก์ชันจะเอารหัสไปตรวจกับฐานก่อนเสมอ
--    รหัส Admin — เห็นทุกโซน · แก้ผังโซน/สาขา · เปลี่ยนรหัส
--    รหัส VP    — เห็นและกรอกได้ทุกโซน
--    รหัสโซน    — เห็นและกรอกได้เฉพาะสาขาในโซนนั้น (บังคับที่ฐาน ไม่ใช่แค่ซ่อนบนหน้าจอ)
--  ไม่มีรหัส = ต่อให้มี key ของหน้าเว็บก็อ่านอะไรไม่ได้สักแถว
-- ═══════════════════════════════════════════════════════════════

-- ───────────── ตาราง ─────────────

-- ผังโซน/สาขา/รหัสเข้าใช้งาน เก็บเป็น jsonb ก้อนเดียว (key = 'main')
create table if not exists public.am_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- สาขา → โซน : สำเนาแบนจากผังข้างบน ไว้ให้ฟังก์ชันใช้ตัดสินสิทธิ์รายแถว
-- อัปเดตให้เองทุกครั้งที่แอดมินบันทึกผัง
create table if not exists public.am_branches (
  branch_id  text primary key,
  zone_id    text not null,
  name       text,
  updated_at timestamptz not null default now()
);
create index if not exists am_branches_zone_idx on public.am_branches (zone_id);

-- ข้อมูลผลงาน : 1 แถว = 1 สาขา 1 เดือน
-- แยกรายแถวแบบนี้เพื่อให้แต่ละโซนกรอกพร้อมกันได้โดยไม่เขียนทับกัน
create table if not exists public.am_entries (
  year       int  not null,
  month      int  not null check (month between 0 and 11),   -- 0 = มกราคม
  branch_id  text not null,
  fields     jsonb not null default '{}'::jsonb,             -- {s25,s26,e25,e26,...,ot,osc,cp,note}
  updated_at timestamptz not null default now(),
  primary key (year, month, branch_id)
);
create index if not exists am_entries_ym_idx on public.am_entries (year, month);

-- ───────────── ล้างของเก่า (เวอร์ชันที่ใช้บัญชีอีเมล) ─────────────
-- ถ้าเคยรันสคีมารุ่นก่อนไว้ ส่วนนี้จะเก็บกวาดให้เอง · ไม่เคยรันก็ข้ามไปเฉย ๆ
drop trigger if exists am_on_auth_user_created on auth.users;
drop function if exists public.am_handle_new_user() cascade;

do $$
declare t text; p record;
begin
  foreach t in array array['am_config','am_branches','am_entries','am_profiles'] loop
    if to_regclass('public.' || t) is not null then
      for p in select policyname from pg_policies where schemaname='public' and tablename=t loop
        execute format('drop policy if exists %I on public.%I', p.policyname, t);
      end loop;
    end if;
  end loop;
end $$;

drop function if exists public.am_branch_allowed(text) cascade;
drop function if exists public.am_role() cascade;
drop function if exists public.am_zone() cascade;
drop table    if exists public.am_profiles cascade;

-- คอลัมน์ updated_by ของรุ่นก่อนไม่ได้ใช้แล้ว (ผูกกับบัญชีผู้ใช้ที่เลิกใช้ไป)
alter table public.am_config  drop column if exists updated_by;
alter table public.am_entries drop column if exists updated_by;

-- ถอนออกจาก Realtime — ตารางปิดตายแล้ว ส่งอัปเดตสดไม่ได้อยู่ดี
do $$ begin alter publication supabase_realtime drop table public.am_entries;
exception when others then null; end $$;
do $$ begin alter publication supabase_realtime drop table public.am_config;
exception when others then null; end $$;

-- ───────────── ปิดตายทุกตาราง ─────────────
-- เปิด RLS โดยไม่สร้าง policy ใด ๆ = ไม่มีใครอ่าน/เขียนตรง ๆ ได้เลย
-- ทางเข้าเดียวคือฟังก์ชัน security definer ข้างล่าง ซึ่งตรวจรหัสก่อนทุกครั้ง
alter table public.am_config   enable row level security;
alter table public.am_branches enable row level security;
alter table public.am_entries  enable row level security;

revoke all on public.am_config, public.am_branches, public.am_entries from anon, authenticated;

-- ───────────── ตรวจรหัส ─────────────

-- คืนสิทธิ์ของรหัสนี้ · รหัสผิดหรือไม่มี = ไม่คืนอะไรเลย
create or replace function public.am_auth(p_code text)
returns table(role text, zone_id text, zone_name text)
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; z jsonb; c text;
begin
  c := lower(btrim(coalesce(p_code, '')));
  if c = '' then return; end if;
  select value into v from public.am_config where key = 'main';
  if v is null then return; end if;

  if c = lower(btrim(coalesce(v->>'adminCode',''))) then
    return query select 'admin'::text, null::text, null::text; return;
  end if;
  if c = lower(btrim(coalesce(v->>'vpCode',''))) then
    return query select 'vp'::text, null::text, null::text; return;
  end if;
  for z in select * from jsonb_array_elements(coalesce(v->'zones','[]'::jsonb)) loop
    if c = lower(btrim(coalesce(z->>'code',''))) then
      return query select 'am'::text, z->>'id', z->>'name'; return;
    end if;
  end loop;
  return;
end $$;

-- ตัวช่วยภายใน: รหัสนี้เป็น role อะไร / ดูแลโซนไหน
create or replace function public.am_role_of(p_code text) returns text
  language sql stable security definer set search_path = public as $$
  select role from public.am_auth(p_code) limit 1
$$;

create or replace function public.am_zone_of(p_code text) returns text
  language sql stable security definer set search_path = public as $$
  select zone_id from public.am_auth(p_code) limit 1
$$;

-- ───────────── อ่านข้อมูล ─────────────

-- ผังโซน/สาขา · รหัสโซนของคนอื่นถูกตัดออกให้ (เห็นได้เฉพาะแอดมิน)
create or replace function public.am_get_config(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r text; v jsonb;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  select value into v from public.am_config where key = 'main';
  if v is null then return null; end if;
  if r = 'admin' then return v; end if;
  -- ไม่ใช่แอดมิน: ลบรหัสทั้งหมดออกก่อนส่งกลับ
  v := v - 'adminCode' - 'vpCode';
  v := jsonb_set(v, '{zones}', (
    select coalesce(jsonb_agg(z - 'code'), '[]'::jsonb)
    from jsonb_array_elements(coalesce(v->'zones','[]'::jsonb)) z));
  return v;
end $$;

-- ข้อมูลผลงานของปีนั้น เฉพาะสาขาที่รหัสนี้มีสิทธิ์เห็น
create or replace function public.am_fetch(p_code text, p_year int)
returns table(month int, branch_id text, fields jsonb)
language plpgsql stable security definer set search_path = public as $$
declare r text; z text;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  if r in ('admin','vp') then
    return query select e.month, e.branch_id, e.fields
                 from public.am_entries e where e.year = p_year;
  else
    z := public.am_zone_of(p_code);
    return query select e.month, e.branch_id, e.fields
                 from public.am_entries e
                 join public.am_branches b on b.branch_id = e.branch_id
                 where e.year = p_year and b.zone_id = z;
  end if;
end $$;

-- เวลาที่มีการแก้ล่าสุด — หน้าเว็บใช้เช็คว่ามีคนกรอกเพิ่มไหม โดยไม่ต้องดึงข้อมูลทั้งก้อน
create or replace function public.am_touched(p_code text, p_year int)
returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare r text;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  return greatest(
    (select max(updated_at) from public.am_entries where year = p_year),
    (select max(updated_at) from public.am_config  where key = 'main'));
end $$;

-- ───────────── เขียนข้อมูล ─────────────

-- บันทึกหลายสาขาในครั้งเดียว
-- p_rows = [{"month":6,"branch_id":"b1","fields":{...}}, ...]
create or replace function public.am_upsert(p_code text, p_year int, p_rows jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare r text; z text; n int := 0; row jsonb; bid text; bz text;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  z := public.am_zone_of(p_code);

  for row in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    bid := row->>'branch_id';
    if bid is null or bid = '' then continue; end if;

    -- โซนตัวเองเท่านั้น (แอดมิน/VP ผ่านหมด)
    if r = 'am' then
      select b.zone_id into bz from public.am_branches b where b.branch_id = bid;
      if bz is distinct from z then
        raise exception 'ไม่มีสิทธิ์แก้สาขา %', bid using errcode = '42501';
      end if;
    end if;

    insert into public.am_entries (year, month, branch_id, fields, updated_at)
    values (p_year, (row->>'month')::int, bid, coalesce(row->'fields', '{}'::jsonb), now())
    on conflict (year, month, branch_id)
      do update set fields = excluded.fields, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

-- บันทึกผังโซน/สาขา/รหัส (แอดมินเท่านั้น) พร้อมอัปเดตสำเนา สาขา→โซน ให้อัตโนมัติ
create or replace function public.am_set_config(p_code text, p_value jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare r text;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  if r <> 'admin' then raise exception 'เฉพาะแอดมินเท่านั้น' using errcode = '42501'; end if;
  if p_value->'zones' is null then raise exception 'ผังไม่ถูกต้อง'; end if;

  insert into public.am_config (key, value, updated_at) values ('main', p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  insert into public.am_branches (branch_id, zone_id, name, updated_at)
  select b->>'id', z->>'id', b->>'name', now()
  from jsonb_array_elements(p_value->'zones') z,
       jsonb_array_elements(coalesce(z->'branches','[]'::jsonb)) b
  on conflict (branch_id) do update
    set zone_id = excluded.zone_id, name = excluded.name, updated_at = now();

  -- สาขาที่ถูกลบออกจากผังแล้ว
  delete from public.am_branches x
  where not exists (
    select 1 from jsonb_array_elements(p_value->'zones') z,
                  jsonb_array_elements(coalesce(z->'branches','[]'::jsonb)) b
    where b->>'id' = x.branch_id);
end $$;

-- ───────────── เปิดให้หน้าเว็บเรียกได้เฉพาะฟังก์ชันเหล่านี้ ─────────────
revoke all on function public.am_role_of(text), public.am_zone_of(text) from anon, authenticated;
grant execute on function
  public.am_auth(text),
  public.am_get_config(text),
  public.am_fetch(text, int),
  public.am_touched(text, int),
  public.am_upsert(text, int, jsonb),
  public.am_set_config(text, jsonb)
to anon;

-- ───────────── รหัสตั้งต้น ─────────────
-- ใส่ไว้ให้เข้าครั้งแรกได้เท่านั้น — เข้าเว็บแล้วให้ไปเปลี่ยนที่แท็บ "จัดการโซน" ทันที
-- (รหัสชุดนี้อยู่ในไฟล์สาธารณะบน GitHub ใครก็เห็น)
insert into public.am_config (key, value)
values ('main', jsonb_build_object('adminCode','ADMIN2026','vpCode','VP2026','zones','[]'::jsonb))
on conflict (key) do nothing;

-- ═══════════════════════════════════════════════════════════════
--  เสร็จแล้ว — ไม่ต้องสร้างบัญชีผู้ใช้ ไม่ต้องตั้งค่าอีเมล
--
--  ขั้นต่อไป: เข้า https://fab-opt.github.io/am-dashboard/
--             ใส่รหัส ADMIN2026 → หน้าเว็บจะอัปโหลดผัง 5 โซนขึ้นให้เอง
--             แล้วไปแท็บ "จัดการโซน" เปลี่ยนรหัสทุกตัวให้เป็นของจริง
--
--  ดูรหัสปัจจุบันทั้งหมด (ถ้าลืม):
--    select value->>'adminCode' as admin, value->>'vpCode' as vp,
--           jsonb_path_query_array(value->'zones', '$[*].code') as zone_codes
--    from public.am_config where key = 'main';
-- ═══════════════════════════════════════════════════════════════
