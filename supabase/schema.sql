-- ═══════════════════════════════════════════════════════════════
--  Area Manager Performance Dashboard — Supabase schema
--  วิธีใช้: Supabase → SQL Editor → วางทั้งไฟล์ → Run
--  รันซ้ำได้ ไม่ลบข้อมูลเดิม (ใช้ if not exists / drop policy if exists)
--
--  ⚠️ โปรเจกต์นี้ใช้กับแดชบอร์ด AM เท่านั้น
--     ห้ามใช้ฐานร่วมกับ FAB Operations Hub หรือ Training Record
--
--  หลักการคุมสิทธิ์: ล็อกอินด้วย Supabase Auth (อีเมล+รหัสผ่าน)
--    admin — เห็นทุกโซน · แก้ผังโซน/สาขา · แก้สิทธิ์คนอื่น
--    vp    — เห็นและกรอกได้ทุกโซน
--    am    — เห็นและกรอกได้เฉพาะสาขาในโซนตัวเอง (บังคับที่ฐาน ไม่ใช่แค่ที่หน้าจอ)
--  anon (คนที่ยังไม่ล็อกอิน) อ่านไม่ได้เลยแม้จะมี key อยู่ในหน้าเว็บ
-- ═══════════════════════════════════════════════════════════════

-- ───────────── ตาราง ─────────────

-- โปรไฟล์ + สิทธิ์ ผูกกับผู้ใช้ใน Supabase Auth
create table if not exists public.am_profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  display_name text,
  role         text not null default 'am' check (role in ('admin','vp','am')),
  zone_id      text,                       -- ต้องตรงกับ id ของโซนใน am_config (เช่น gus, dao, fern, aoy, eve)
  created_at   timestamptz not null default now()
);

-- สาขา → โซน : สำเนาแบนจากผังใน am_config ไว้ให้ RLS ใช้ตัดสินสิทธิ์รายแถว
-- หน้าเว็บจะอัปเดตให้เองทุกครั้งที่แอดมินแก้ผังในแท็บ "จัดการโซน"
create table if not exists public.am_branches (
  branch_id  text primary key,
  zone_id    text not null,
  name       text,
  updated_at timestamptz not null default now()
);
create index if not exists am_branches_zone_idx on public.am_branches (zone_id);

-- ผังโซน/สาขา/ชื่อผู้ดูแล เก็บเป็น jsonb ก้อนเดียว (key = 'main')
create table if not exists public.am_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- ข้อมูลผลงาน : 1 แถว = 1 สาขา 1 เดือน
-- แยกรายแถวแบบนี้เพื่อให้แต่ละโซนกรอกพร้อมกันได้โดยไม่เขียนทับกัน
create table if not exists public.am_entries (
  year       int  not null,
  month      int  not null check (month between 0 and 11),   -- 0 = มกราคม
  branch_id  text not null,
  fields     jsonb not null default '{}'::jsonb,             -- {s25,s26,e25,e26,...,ot,osc,cp,note}
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (year, month, branch_id)
);
create index if not exists am_entries_ym_idx on public.am_entries (year, month);

-- ───────────── ตัวช่วยอ่านสิทธิ์ ─────────────
-- security definer เพื่อไม่ให้ policy ที่อ่าน am_profiles วนเรียกตัวเอง
create or replace function public.am_role() returns text
  language sql stable security definer set search_path = public as $$
  select role from public.am_profiles where id = auth.uid()
$$;

create or replace function public.am_zone() returns text
  language sql stable security definer set search_path = public as $$
  select zone_id from public.am_profiles where id = auth.uid()
$$;

-- สาขานี้อยู่ในความรับผิดชอบของคนที่ล็อกอินอยู่ไหม
create or replace function public.am_branch_allowed(b text) returns boolean
  language sql stable security definer set search_path = public as $$
  select case
    when public.am_role() in ('admin','vp') then true
    when public.am_role() = 'am' then exists (
      select 1 from public.am_branches x
      where x.branch_id = b and x.zone_id = public.am_zone())
    else false
  end
$$;

-- สร้างโปรไฟล์ให้อัตโนมัติเมื่อมีผู้ใช้ใหม่ (เริ่มต้นเป็น role 'am' ยังไม่ผูกโซน)
create or replace function public.am_handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into public.am_profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists am_on_auth_user_created on auth.users;
create trigger am_on_auth_user_created
  after insert on auth.users
  for each row execute function public.am_handle_new_user();

-- ───────────── RLS ─────────────
alter table public.am_profiles enable row level security;
alter table public.am_branches enable row level security;
alter table public.am_config   enable row level security;
alter table public.am_entries  enable row level security;

-- โปรไฟล์: เห็นของตัวเอง · แอดมินเห็นและแก้ได้ทุกคน
drop policy if exists am_profiles_read on public.am_profiles;
create policy am_profiles_read on public.am_profiles for select to authenticated
  using (id = auth.uid() or public.am_role() = 'admin');

drop policy if exists am_profiles_admin on public.am_profiles;
create policy am_profiles_admin on public.am_profiles for all to authenticated
  using (public.am_role() = 'admin') with check (public.am_role() = 'admin');

-- ผังสาขา: ทุกคนที่ล็อกอินอ่านได้ · แก้ได้เฉพาะแอดมิน
drop policy if exists am_branches_read on public.am_branches;
create policy am_branches_read on public.am_branches for select to authenticated using (true);

drop policy if exists am_branches_admin on public.am_branches;
create policy am_branches_admin on public.am_branches for all to authenticated
  using (public.am_role() = 'admin') with check (public.am_role() = 'admin');

-- ผังโซน/รหัส: ทุกคนที่ล็อกอินอ่านได้ · แก้ได้เฉพาะแอดมิน
drop policy if exists am_config_read on public.am_config;
create policy am_config_read on public.am_config for select to authenticated using (true);

drop policy if exists am_config_admin on public.am_config;
create policy am_config_admin on public.am_config for all to authenticated
  using (public.am_role() = 'admin') with check (public.am_role() = 'admin');

-- ข้อมูลผลงาน: อ่านและเขียนได้เฉพาะสาขาที่ตัวเองรับผิดชอบ
drop policy if exists am_entries_read on public.am_entries;
create policy am_entries_read on public.am_entries for select to authenticated
  using (public.am_branch_allowed(branch_id));

drop policy if exists am_entries_insert on public.am_entries;
create policy am_entries_insert on public.am_entries for insert to authenticated
  with check (public.am_branch_allowed(branch_id));

drop policy if exists am_entries_update on public.am_entries;
create policy am_entries_update on public.am_entries for update to authenticated
  using (public.am_branch_allowed(branch_id)) with check (public.am_branch_allowed(branch_id));

drop policy if exists am_entries_delete on public.am_entries;
create policy am_entries_delete on public.am_entries for delete to authenticated
  using (public.am_branch_allowed(branch_id));

-- ───────────── สิทธิ์ระดับตาราง ─────────────
grant usage on schema public to authenticated;
grant select, insert, update, delete
  on public.am_profiles, public.am_branches, public.am_config, public.am_entries
  to authenticated;
-- คนที่ยังไม่ล็อกอินแตะอะไรไม่ได้เลย
revoke all on public.am_profiles, public.am_branches, public.am_config, public.am_entries from anon;

-- ───────────── Realtime (ให้หน้าเว็บอัปเดตทันทีเมื่อมีคนกรอก) ─────────────
do $$ begin
  alter publication supabase_realtime add table public.am_entries;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.am_config;
exception when duplicate_object then null; end $$;

-- ═══════════════════════════════════════════════════════════════
--  ขั้นตอนหลังรันไฟล์นี้
-- ═══════════════════════════════════════════════════════════════
-- 1) สร้างผู้ใช้ใน Authentication → Users → Add user (ใส่อีเมล + รหัสผ่าน,
--    ติ๊ก Auto Confirm User เพื่อไม่ต้องยืนยันอีเมล)
--
-- 2) ตั้งคนแรกให้เป็นแอดมิน (รันใน SQL Editor — ที่นี่ข้าม RLS ได้):
--      update public.am_profiles set role = 'admin', display_name = 'แอดมิน'
--      where email = 'อีเมลของคุณ';
--
-- 3) เข้าเว็บด้วยบัญชีแอดมิน หน้าเว็บจะอัปโหลดผังโซน/สาขาขึ้นฐานให้เอง
--    (หรือกดปุ่ม "อัปโหลดข้อมูลในเครื่องนี้ขึ้นข้อมูลกลาง" ในแท็บกรอกข้อมูล)
--
-- 4) ตั้งสิทธิ์คนอื่น — zone_id ต้องตรงกับ id โซนในผัง (ดูได้จาก:
--      select jsonb_array_elements(value->'zones')->>'id'  as zone_id,
--             jsonb_array_elements(value->'zones')->>'name' as name
--      from public.am_config where key = 'main';)
--
--      update public.am_profiles set role='am', zone_id='gus'  where email='am1@example.com';
--      update public.am_profiles set role='vp'                 where email='vp@example.com';
--
-- 5) ตรวจสิทธิ์ทั้งหมด:
--      select email, role, zone_id from public.am_profiles order by role, email;
