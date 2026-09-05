# Area Manager Performance Dashboard — ส้มตำเจ๊แดง

แดชบอร์ดผลงาน Area Manager รายสาขา เทียบ YoY / MoM · หน้าเดียวจบ ใช้ได้ทั้งคอมและมือถือ

- **เว็บ:** GitHub Pages (ไฟล์ HTML ล้วน ไม่ต้อง build)
- **ข้อมูล:** Supabase (Postgres + Auth + Realtime) — โปรเจกต์แยกของแดชบอร์ดนี้เอง ไม่ใช้ร่วมกับระบบอื่น
- **กราฟ:** Chart.js 4.4.1 (ฝังในไฟล์ ไม่ต้องต่อเน็ตโหลดเพิ่ม)

---

## ไฟล์ในโปรเจกต์

| ไฟล์ | หน้าที่ |
|---|---|
| `index.html` | ตัวแดชบอร์ดทั้งหมด (HTML + CSS + JS + Chart.js) |
| `config.js` | URL และ key ของ Supabase — **ไฟล์เดียวที่ต้องแก้ตอนติดตั้ง** |
| `supabase/schema.sql` | ตาราง สิทธิ์ (RLS) และ Realtime — วางใน SQL Editor แล้ว Run |
| `.nojekyll` | บอก GitHub Pages ไม่ต้องประมวลผลด้วย Jekyll |

---

## ติดตั้งครั้งแรก

### 1. สร้างโปรเจกต์ Supabase
สร้างโปรเจกต์ใหม่ที่ [supabase.com](https://supabase.com) — **ห้ามใช้ฐานร่วมกับ FAB Operations Hub หรือ Training Record**

### 2. สร้างตาราง
Supabase → **SQL Editor** → วางทั้งไฟล์ [`supabase/schema.sql`](supabase/schema.sql) → **Run**

### 3. ใส่ค่าเชื่อมต่อ
Supabase → **Settings → API** คัดลอก *Project URL* กับ *Publishable (anon) key* มาใส่ใน `config.js`

```js
window.AM_CONFIG = {
  url: 'https://xxxxxxxx.supabase.co',
  key: 'sb_publishable_xxxxxxxx'
};
```

> key ตัวนี้เปิดเผยได้ตามปกติ สิ่งที่กันข้อมูลจริงคือ Auth + RLS
> **ห้ามใส่ `service_role` key เด็ดขาด**

### 4. สร้างผู้ใช้
Supabase → **Authentication → Users → Add user** ใส่อีเมล + รหัสผ่าน และติ๊ก **Auto Confirm User**

ตั้งคนแรกให้เป็นแอดมิน (SQL Editor):

```sql
update public.am_profiles set role = 'admin' where email = 'อีเมลของคุณ';
```

### 5. เปิดเว็บครั้งแรกด้วยบัญชีแอดมิน
หน้าเว็บจะอัปโหลดผังโซน/สาขาขึ้นฐานให้เองอัตโนมัติ

### 6. ตั้งสิทธิ์คนอื่น

```sql
-- ดู id โซนที่มีอยู่
select jsonb_array_elements(value->'zones')->>'id'   as zone_id,
       jsonb_array_elements(value->'zones')->>'name' as name
from public.am_config where key = 'main';

update public.am_profiles set role='am', zone_id='gus' where email='am1@example.com';
update public.am_profiles set role='vp'                where email='vp@example.com';
```

---

## สิทธิ์การใช้งาน

| role | เห็นข้อมูล | กรอกข้อมูล | จัดการโซน/สาขา |
|---|---|---|---|
| `admin` | ทุกโซน | ทุกโซน | ได้ |
| `vp` | ทุกโซน | ทุกโซน | ไม่ได้ |
| `am` | เฉพาะโซนตัวเอง | เฉพาะโซนตัวเอง | ไม่ได้ |

ขอบเขตของ `am` บังคับที่ฐานข้อมูลด้วย RLS ไม่ใช่แค่ซ่อนบนหน้าจอ — ต่อให้เรียก API ตรง ๆ ก็อ่านหรือแก้ข้ามโซนไม่ได้

---

## วิธีเก็บข้อมูล

| ตาราง | เก็บอะไร |
|---|---|
| `am_entries` | 1 แถว = 1 สาขา 1 เดือน (`year, month, branch_id, fields`) — แยกรายแถวเพื่อให้หลายโซนกรอกพร้อมกันได้ไม่ทับกัน |
| `am_config` | ผังโซน/สาขา/ชื่อผู้ดูแล เก็บเป็น jsonb ก้อนเดียว (`key = 'main'`) |
| `am_branches` | สำเนาแบน สาขา → โซน ไว้ให้ RLS ใช้ตัดสินสิทธิ์ (หน้าเว็บอัปเดตให้เองเมื่อแอดมินแก้ผัง) |
| `am_profiles` | สิทธิ์ของผู้ใช้แต่ละคน ผูกกับ Supabase Auth |

- บันทึกแบบหน่วง 0.7 วินาที ไม่ยิงฐานทุกตัวอักษร
- เน็ตหลุดจะเก็บคิวไว้แล้วลองใหม่ให้เอง
- ใครกรอกที่ไหน คนอื่นเห็นทันทีผ่าน Realtime โดยไม่ต้องรีเฟรช
- `localStorage` ยังทำงานเป็นสำเนาสำรอง และถ้า `config.js` ว่าง หน้าเว็บจะกลับไปโหมดออฟไลน์ (ล็อกอินด้วยรหัสเดิม) ให้ใช้งานต่อได้

---

## แก้ไขและอัปเดตเว็บ

แก้ `index.html` แล้ว push — GitHub Pages อัปเดตให้เองภายในไม่กี่นาที

```bash
git add -A && git commit -m "อธิบายสิ่งที่แก้" && git push
```
