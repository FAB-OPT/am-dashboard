/* config.js — ตั้งค่าเชื่อม Supabase
   ═══════════════════════════════════════════════════════════════
   หาค่า 2 ตัวนี้ได้ที่: Supabase → โปรเจกต์ของแดชบอร์ดนี้ → Settings → API
     url = Project URL          เช่น https://abcdefgh.supabase.co
     key = Publishable / anon key (ตัวที่ขึ้นต้น sb_publishable_ หรือ eyJ...)

   ⚠️ ใช้โปรเจกต์ Supabase ของแดชบอร์ดนี้เท่านั้น ห้ามใช้ฐานร่วมกับ
      FAB Operations Hub / Training Record

   key ตัวนี้เปิดเผยได้ (ติดไปกับหน้าเว็บอยู่แล้ว) — สิ่งที่กันข้อมูลจริง
   คือ Supabase Auth + RLS ใน supabase/schema.sql ไม่ใช่การซ่อน key
   ห้ามเอา service_role key มาใส่ที่นี่เด็ดขาด

   ปล่อยว่างไว้ = หน้าเว็บทำงานโหมดออฟไลน์ (เก็บใน localStorage + ล็อกอินด้วยรหัสเดิม)
   ═══════════════════════════════════════════════════════════════ */
window.AM_CONFIG = {
  url: 'https://prkoyrorasldnqekhhtv.supabase.co',
  key: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBya295cm9yYXNsZG5xZWtoaHR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg2MjY0MTIsImV4cCI6MjEwNDIwMjQxMn0.EXorrudWaQcLxXqemx0q_YalZ-xM02TKBWmJ5eRXdNQ'
};
