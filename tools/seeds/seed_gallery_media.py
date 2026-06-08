import sys, base64, json
sys.path.insert(0, "/home/dlesieur/Documents/ft_transcendence/temp")
import seed_arch as A  # importing re-emits seed_arch.sql (harmless; we don't apply it)
t = {"title": "Block Component Showcase", "sub": "Component Gallery", "arch": "gallery",
     "related": ["Layout & Color Playground", "Load Balancing", "CAP Theorem"], "tldr": "(gallery)"}
content = A.component_gallery(t)
b64 = lambda o: base64.b64encode(json.dumps(o).encode()).decode()
jcol = lambda o: f"convert_from(decode('{b64(o)}','base64'),'utf8')::jsonb"
sql = (f"UPDATE public.osionos_pages SET content={jcol(content)}, updated_at=now() "
       f"WHERE workspace_id='{A.WS}' AND title='Block Component Showcase' AND surface IS NULL;")
open("/home/dlesieur/Documents/ft_transcendence/temp/seed_gallery_media.sql", "w").write("BEGIN;\n"+sql+"\nCOMMIT;\n")
print("media blocks in showcase:", sum(1 for b in content if b.get("type") in ("image","video","file")))
