"""
Baixa imagens dos produtos da LISTA DE NOMES.txt
e salva como WebP (400x400) para o frontend PWA.

Pipeline de busca (ordem de prioridade):
  1. Wikipedia PT (artigo → thumbnail oficial — contexto semantico)
  2. Wikipedia PT + categoria (ex: "cacau fruta" desambigua)
  3. Wikimedia Commons + categoria (fallback contextual)
  4. Wikimedia Commons puro (fallback generico)
  5. Placeholder colorido com inicial

Idempotencia: arquivos > 2.5 KB sao considerados reais e pulados.
Uso:
  python utilities/fetch_product_images.py
  python utilities/fetch_product_images.py --force
"""

import io
import os
import sys
import re
import hashlib
import argparse
import unicodedata
import requests
from PIL import Image, ImageDraw, ImageFont

WIKIPEDIA_API = "https://pt.wikipedia.org/w/api.php"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
PLACEHOLDER_THRESHOLD = 2500

HEADERS = {"User-Agent": "QueroComprarPWA/1.0 (contato@quero-comprar.app)"}
OFF_CIRCUIT = False
_off_warned = False

PALETTE = [
    "#4ade80", "#facc15", "#f87171", "#60a5fa", "#a78bfa",
    "#34d399", "#fbbf24", "#f472b6", "#2dd4bf", "#c084fc",
    "#22d3ee", "#fb923c", "#e879f9", "#38bdf8", "#86efac",
]

CATEGORY_KEYWORDS = {
    "FRUTA": (
        r"^(abacate|abacaxi|abiu|acerola|ameixa|amora|atemoia|banana"
        r"|cacau|caju|caqui|carambola|cereja|coco|cupuacu|damasco|figo"
        r"|framboesa|goiaba|granadilla|grapefruit|graviola|jabuticaba"
        r"|jaca|jambo|jenipapo|kiwi|laranja|lima|lichia|longan|maca"
        r"|mamao|manga|mangostim|maracuja|melancia|melao|mexerica"
        r"|mirtilo|morango|nectarina|nespera|nozes|pera|pessego|pinha"
        r"|pitaia|pitanga|roma|seriguela|tamarillo|tangerina|uva"
        r"|physalis|limao|grape)"
    ),
    "LEGUME": (
        r"^(abobora|abobrinha|batata|berinjela|beterraba|cenoura|chuchu"
        r"|ervilha|inhame|mandioca|mandioquinha|milho|maxixe|nabo"
        r"|palmito|pepino|pimenta|pimentao|quiabo|rabanete|repolho"
        r"|tomate|vagem|cara|jilo|alcachofra|aspargo|broto|cogumelo)"
    ),
    "VERDURA": (
        r"^(acelga|alface|almeirao|agriao|brocolis|cebolinha|chicoria"
        r"|coentro|couve|endivia|escarola|espinafre|hortela|manjericao"
        r"|mostarda|rucula|salsa|salsao)"
    ),
    "FLOR": (
        r"^(rosa|orquidea|crisantemo|girassol|lirio|tulipa|violeta"
        r"|begonia|azaleia|bromelia|kalanchoe|petunia|hortensia"
        r"|heliconia|estrelicia|estatice|gypsofila|dalia"
        r"|ciclamen|calendula|boca_de_leao|iris|tango|goivo"
        r"|agapanto|alstromeria|anglica|avenca?|azaleia)"
    ),
    "PEIXE": (
        r"^(atum|anchova|bacalhau|badejo|bagre|bonito|cacao|cangulo"
        r"|carapau|carapeba|cascudo|cavala|cavalinha|congrio|corvina"
        r"|dourado|garoupa|linguado|lula|meca|merluza|moreia|olhete"
        r"|ostra|pacu|pargo|pescada|pintado|pirarucu|polvo|robalo"
        r"|salmao|sardinha|siri|tainha|tambaqui|tilapia|truta"
        r"|tucunare|namorado|branguinha|anchova)"
    ),
    "PROTEINA": (
        r"^(carne|frango|bovina|suina|caprina|ovina|linguiça|leite"
        r"|queijo|manteiga|ovo|ovos|pao)"
    ),
    "CEREAL": (
        r"^(arroz|feijao|farinha|trigo|aveia|soja|fuba|polvilho"
        r"|macarrao|flocos)"
    ),
    "BEBIDA": r"^(cafe|suco|cerveja|vinho|cachaca|cha)",
    "OLEO": r"^(oleo|azeite)",
    "TEMPERO": (
        r"^(alecrim|cebola|alho|gengibre|louro|tomilho|hortela"
        r"|manjerona|estragao|endro|erva_doce|capim_cidreira|acucar|sal"
        r"|salsa|salsao|coentro|cebolinha|cebolete)"
    ),
    "FLOR_VASO": r"^.*(vaso|pct|muda|palmeira|ficus|dracena|avenca|suculenta|mini_rosa|tuia)",
    "OUTRO": r"",
}

CATEGORY_QUERY = {
    "FRUTA": "fruta",
    "LEGUME": "legume",
    "VERDURA": "hortalica",
    "FLOR": "flor",
    "PEIXE": "peixe",
    "PROTEINA": "carne",
    "CEREAL": "grao",
    "BEBIDA": "bebida",
    "OLEO": "oleo",
    "TEMPERO": "tempero",
    "FLOR_VASO": "planta ornamental",
    "OUTRO": "",
}

CATEGORY_QUERY = {
    "FRUTA": "fruta",
    "LEGUME": "legume",
    "VERDURA": "hortalica",
    "FLOR": "flor",
    "PEIXE": "peixe",
    "PROTEINA": "carne",
    "CEREAL": "grao",
    "BEBIDA": "bebida",
    "OLEO": "oleo",
    "TEMPERO": "tempero",
    "FLOR_VASO": "planta ornamental",
    "OUTRO": "",
}


def slug(name: str) -> str:
    s = name.lower()
    s = unicodedata.normalize("NFKD", s)
    s = s.encode("ascii", "ignore").decode("ascii")
    s = s.replace(" ", "_").replace("/", "_").replace("\\", "_")
    s = re.sub(r"[()´`'\"\u2013\u2014,.:]", "", s)
    s = re.sub(r"_+", "_", s)
    s = s.strip("_")
    return s


def pick_color(name: str) -> str:
    idx = int(hashlib.md5(name.encode()).hexdigest(), 16) % len(PALETTE)
    return PALETTE[idx]


def categorize(name: str) -> tuple[str, str]:
    clean = unicodedata.normalize("NFKD", name)
    clean = clean.encode("ascii", "ignore").decode("ascii").strip().lower()
    for cat, pattern in CATEGORY_KEYWORDS.items():
        if pattern and re.search(pattern, clean, re.IGNORECASE):
            return cat, CATEGORY_QUERY[cat]
    return "OUTRO", ""


def base_name(name: str) -> str:
    s = re.sub(r"\s*[-–—/].*$", "", name).strip()
    s = re.sub(r"\s*[-,].*$", "", s).strip()
    return s


def _should_fetch(path: str) -> bool:
    if not os.path.exists(path):
        return True
    return os.path.getsize(path) <= PLACEHOLDER_THRESHOLD


def _wp_search(query: str) -> str | None:
    params = {
        "action": "query",
        "generator": "search",
        "gsrsearch": query,
        "gsrlimit": 3,
        "prop": "pageimages|pageprops",
        "piprop": "thumbnail",
        "pithumbsize": 400,
        "format": "json",
    }
    try:
        r = requests.get(WIKIPEDIA_API, params=params, headers=HEADERS, timeout=8)
        if r.status_code != 200:
            return None
        pages = r.json().get("query", {}).get("pages", {})
        for pid in sorted(pages, key=int):
            thumb = pages[pid].get("thumbnail", {}).get("source")
            if thumb:
                return thumb
    except Exception:
        return None
    return None


def _commons_search(query: str) -> str | None:
    params = {
        "action": "query",
        "generator": "search",
        "gsrsearch": query,
        "gsrnamespace": 6,
        "gsrlimit": 3,
        "prop": "imageinfo",
        "iiprop": "url",
        "iiurlwidth": 400,
        "format": "json",
    }
    try:
        r = requests.get(COMMONS_API, params=params, headers=HEADERS, timeout=8)
        if r.status_code != 200:
            return None
        pages = r.json().get("query", {}).get("pages", {})
        for pid in sorted(pages, key=int):
            info = pages[pid].get("imageinfo", [])
            if info:
                url = info[0].get("thumburl") or info[0].get("url")
                if url:
                    return url
    except Exception:
        return None
    return None


def find_image(product_name: str) -> tuple[str | None, str]:
    """
    Returns (url, source_tag) where source_tag is one of:
      WP, WP_CAT, COMMONS_CAT, COMMONS, None
    """
    base = base_name(product_name)
    cat, cat_q = categorize(product_name)

    # 1. Wikipedia on base name
    url = _wp_search(base)
    if url:
        return url, "WP"

    # 2. Wikipedia on base + category
    if cat_q:
        url = _wp_search(f"{base} {cat_q}")
        if url:
            return url, "WP_CAT"

    # 3. Wikipedia on full name truncated
    short = product_name.split()[0].strip().lower() if product_name.split() else ""
    if short and short != base:
        url = _wp_search(short)
        if url:
            return url, "WP"

    # 4. Commons on base + category
    if cat_q:
        url = _commons_search(f"{base} {cat_q}")
        if url:
            return url, "COMMONS_CAT"

    # 5. Commons on base
    url = _commons_search(base)
    if url:
        return url, "COMMONS"

    return None, None


def download_image(url: str, path: str) -> bool:
    try:
        r = requests.get(url, headers=HEADERS, timeout=10)
        if r.status_code != 200:
            return False
        img = Image.open(io.BytesIO(r.content)).convert("RGB")
        img.thumbnail((400, 400))
        img.save(path, "webp", quality=80)
        return True
    except Exception:
        return False


def make_placeholder(name: str, path: str) -> None:
    size = 400
    bg = pick_color(name)
    img = Image.new("RGB", (size, size), color=bg)
    draw = ImageDraw.Draw(img)
    first = name.strip()[0].upper() if name.strip() else "?"
    try:
        font = ImageFont.truetype("arial.ttf", 180)
    except Exception:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), first, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (size - tw) // 2 - bbox[0]
    y = (size - th) // 2 - bbox[1]
    draw.text((x, y), first, fill="white", font=font)
    img.save(path, "webp", quality=75)


def fetch_image(product_name: str, out_dir: str, force: bool) -> bool:
    fname = f"{slug(product_name)}.webp"
    path = os.path.join(out_dir, fname)

    should = force or _should_fetch(path)
    if not should:
        kb = os.path.getsize(path) / 1024
        print(f"  [SKIP] {fname} ({kb:.0f} KB)")
        return True

    label = " [FORCE]" if force and os.path.exists(path) else ""
    print(f"  [BUSCA{label}] {product_name}...")
    sys.stdout.flush()

    url, src = find_image(product_name)
    if url and download_image(url, path):
        kb = os.path.getsize(path) / 1024
        print(f"  [{src}] ({kb:.0f} KB): {fname}")
        return True

    make_placeholder(product_name, path)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="LISTA DE NOMES.txt")
    parser.add_argument("--output", default="frontend/public/assets/images/produtos")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    inp = args.input
    out = args.output

    if not os.path.isabs(inp):
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        inp = os.path.join(root, inp)
        out = os.path.join(root, out)

    if not os.path.exists(inp):
        print(f"[ERRO] Arquivo nao encontrado: {inp}")
        sys.exit(1)

    os.makedirs(out, exist_ok=True)

    with open(inp, "r", encoding="utf-8") as f:
        produtos = [line.strip() for line in f if line.strip()]

    print(f"[PRODUTOS] {len(produtos)} produtos para processar")
    print(f"[SAIDA] {out}")
    if args.force:
        print("[FORCE] Re-baixando todos")
    print()

    ok = fail = 0
    for prod in produtos:
        try:
            if fetch_image(prod, out, args.force):
                ok += 1
        except Exception as e:
            print(f"  [ERRO] {e}")
            fail += 1
        print()

    print(f"[OK] {ok}/{len(produtos)} | {fail} falhas")


if __name__ == "__main__":
    main()
