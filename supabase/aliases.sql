-- ═══════════════════════════════════════════════════════════════
--  จำการจับคู่ชื่อสาขาในไฟล์ Excel ไว้ในฐานกลาง ใช้ร่วมกันทุกคน ทุกเครื่อง
--  วิธีใช้: Supabase > SQL Editor > วางทั้งไฟล์ > Run  (รันซ้ำได้ ไม่กระทบข้อมูลเดิม)
--
--  เก็บแยกเป็นแถว key = 'aliases' ในตาราง am_config ไม่ปนกับผังโซน (key = 'main')
--  การแก้ผังโซนในแท็บจัดการโซนจึงไม่ไปทับการจับคู่ที่จำไว้
--  ผู้ดูแลพื้นที่บันทึกได้เฉพาะการจับคู่ที่ชี้ไปสาขาในโซนตัวเอง
-- ═══════════════════════════════════════════════════════════════

create or replace function public.am_get_aliases(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.am_role_of(p_code) is null then
    raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000';
  end if;
  return coalesce((select value from public.am_config where key = 'aliases'), '{}'::jsonb);
end $$;

create or replace function public.am_save_aliases(p_code text, p_aliases jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text; z text; k text; v text; keep jsonb := '{}'::jsonb; cur jsonb;
begin
  r := public.am_role_of(p_code);
  if r is null then raise exception 'รหัสไม่ถูกต้อง' using errcode = '28000'; end if;
  z := public.am_zone_of(p_code);

  for k, v in select e.key, e.value #>> '{}' from jsonb_each(coalesce(p_aliases, '{}'::jsonb)) e loop
    if k is null or k = '' or v is null then continue; end if;
    -- ต้องชี้ไปสาขาที่มีจริง และผู้ดูแลพื้นที่ชี้ได้เฉพาะสาขาในโซนตัวเอง
    if not exists (select 1 from public.am_branches b
                   where b.branch_id = v and (r in ('admin','vp') or b.zone_id = z)) then
      continue;
    end if;
    keep := keep || jsonb_build_object(k, v);
  end loop;

  select value into cur from public.am_config where key = 'aliases';
  cur := coalesce(cur, '{}'::jsonb) || keep;
  insert into public.am_config (key, value, updated_at) values ('aliases', cur, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return cur;
end $$;

grant execute on function public.am_get_aliases(text), public.am_save_aliases(text, jsonb) to anon;
