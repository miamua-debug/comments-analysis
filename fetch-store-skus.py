# fetch-store-skus.py - Extract all SKUs from a JD store
import sys, json, re, time, os, argparse, tempfile, shutil
from urllib.parse import quote
import requests
# Import shared spec parser (JD + Tmall unified)
import os as _os
_sys_path = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
if _sys_path not in sys.path: sys.path.insert(0, _sys_path)
from shared.parse_specs import parse_specs

def status(msg):
    print("STATUS:" + json.dumps(msg, ensure_ascii=False), flush=True)

def get_base_name(name):
    base = re.sub(r'\s+', ' ', name)
    base = re.sub(r'\s*\([^)]*\)\s*$', '', base)
    base = re.sub(r'\s*（[^）]*）\s*$', '', base)
    base = re.sub(r'\s*\[[^\]]*\]\s*$', '', base)
    return base.strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--shopId', required=True)
    parser.add_argument('--keyword', required=True)
    parser.add_argument('--targetShop', default='')
    parser.add_argument('--maxPages', type=int, default=50)
    args = parser.parse_args()

    shop_id, keyword, max_pages = args.shopId, args.keyword, args.maxPages
    headers = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"}
    comment_headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", "Referer": "https://item.jd.com/"}
    encoded = quote(keyword)
    temp_dir = tempfile.mkdtemp(prefix=f"jd_sku_{shop_id}_")

    try:
        # Phase 1: Find last page
        status({"phase": "search", "message": "Finding total pages..."})
        low, high, last_page = 1, 100, 1
        while low < high:
            mid = (low + high) // 2
            try:
                r = requests.get(f"https://so.m.jd.com/ware/search.action?keyword={encoded}&shopId={shop_id}&page={mid}", headers=headers, timeout=15)
                count = len(re.findall(r'<div class="search_prolist_item"\s+skuid="(\d+)"', r.text))
                if count > 0: last_page = mid; low = mid + 1
                else: high = mid
            except: high = mid
        last_page = min(last_page, max_pages)
        status({"phase": "search", "message": f"Found {last_page} pages"})

        # Phase 2: Download pages
        status({"phase": "download", "message": f"Downloading {last_page} pages...", "total": last_page})
        for page in range(1, last_page + 1):
            try:
                r = requests.get(f"https://so.m.jd.com/ware/search.action?keyword={encoded}&shopId={shop_id}&page={page}", headers=headers, timeout=15)
                with open(f"{temp_dir}/p{page}.html", 'w', encoding='utf-8') as f: f.write(r.text)
                if page % 5 == 0 or page == last_page:
                    status({"phase": "download", "message": f"Downloaded {page}/{last_page}", "current": page, "total": last_page})
            except: pass
            time.sleep(0.1)

        # Phase 3: Extract SKUs
        status({"phase": "extract", "message": "Extracting SKU data..."})
        all_skus = {}
        for page in range(1, last_page + 1):
            fn = f"{temp_dir}/p{page}.html"
            if not os.path.exists(fn): continue
            with open(fn, 'r', encoding='utf-8') as f: content = f.read()
            blocks = re.split(r'<div class="search_prolist_item"\s+skuid="', content)
            for block in blocks:
                m = re.match(r'^(\d+)"', block)
                if not m: continue
                sid = m.group(1)
                if sid in all_skus: continue
                name = re.search(r'class="search_prolist_title"[^>]*>([^<]+)<', block)
                price = re.search(r'pri="([^"]+)"', block)
                rate = re.search(rf'id="rate_{sid}"[^>]*>(\d+)<', block)
                shop = re.search(r'class="shop_name"[^>]*>([^<]+)<', block)
                if name:
                    all_skus[sid] = {
                        'Name': name.group(1).strip(), 'Price': float(price.group(1)) if price else 0,
                        'Rate': rate.group(1) if rate else '', 'Shop': shop.group(1).strip() if shop else '',
                        'Color': '', 'Attrs': '', 'ExtName': '', 'CommentCount': '', 'AvgScore': 0, 'GoodRate': 0
                    }
                # Extract JSON variant data
                for jm in re.finditer(r'\{[^}]*"warename"[^}]*"CustomAttrListNew":"([^"]*)"[^}]*"extname":"([^"]*)"[^}]*\}', block):
                    if jm.group(1) and not all_skus[sid]['Attrs']: all_skus[sid]['Attrs'] = jm.group(1)
                    if jm.group(2) and not all_skus[sid]['ExtName']: all_skus[sid]['ExtName'] = jm.group(2)
                for cm in re.finditer(r'\{[^}]*"color":"([^"]+)"[^}]*\}', block):
                    if cm.group(1) and not all_skus[sid]['Color']: all_skus[sid]['Color'] = cm.group(1)

        status({"phase": "extract", "message": f"Extracted {len(all_skus)} candidate SKUs"})

        # Phase 3.5: Early filter by shop
        shop_counts = {}
        for sid, s in all_skus.items():
            sn = s['Shop'] or '(none)'; shop_counts[sn] = shop_counts.get(sn, 0) + 1
        # Filter by shop: substring match if user-specified, else auto-pick largest
        if args.targetShop:
            target_shop = args.targetShop
            filtered = {sid: s for sid, s in all_skus.items() if target_shop in s['Shop']}
            if filtered:
                all_skus = filtered
            else:
                # No match found — keep all SKUs and warn
                status({"phase": "filter", "message": f"Shop '{target_shop}' not found in results, keeping all {len(all_skus)} SKUs"})
                for sn, cnt in sorted(shop_counts.items(), key=lambda x: -x[1])[:5]:
                    status({"phase": "filter", "message": f"  Available: {sn} ({cnt} SKUs)"})
                target_shop = max(shop_counts, key=shop_counts.get) or target_shop
        else:
            target_shop = max(shop_counts, key=shop_counts.get)
            all_skus = {sid: s for sid, s in all_skus.items() if s['Shop'] == target_shop}
        status({"phase": "filter", "message": f"After shop filter: {len(all_skus)} SKUs from {target_shop}"})

        # Phase 4: Fetch review data
        status({"phase": "reviews", "message": f"Fetching reviews for {len(all_skus)} SKUs...", "total": len(all_skus)})
        processed = 0
        for sid, s in all_skus.items():
            try:
                r = requests.get(f"https://club.jd.com/comment/skuProductPageComments.action?productId={sid}&score=0&sortType=5&page=1&pageSize=10", headers=comment_headers, timeout=8)
                data = r.json()
                ss = data.get('productCommentSummary', {})
                s['CommentCount'] = ss.get('commentCountStr', '')
                s['AvgScore'] = ss.get('averageScore', 0)
                s['GoodRate'] = ss.get('goodRateShow', 0)
                if data.get('comments') and data['comments'][0].get('productColor') and not s['Color']:
                    s['Color'] = data['comments'][0]['productColor']
                if data.get('comments') and data['comments'][0].get('referenceName'):
                    s['FullName'] = data['comments'][0]['referenceName']
            except: pass
            processed += 1
            if processed % 30 == 0 or processed == len(all_skus):
                status({"phase": "reviews", "message": f"Fetched reviews: {processed}/{len(all_skus)}", "current": processed, "total": len(all_skus)})
            time.sleep(0.2)

        # Phase 5: Parse specs
        status({"phase": "parse", "message": "Parsing specs..."})
        for sid, s in all_skus.items():
            pname = s.get('FullName', s['Name'])
            sp = parse_specs(pname, s['Color'], s['Attrs'])
            for k in sp: s[k] = sp[k]
        status({"phase": "parse", "message": f"Parsed specs for {len(all_skus)} SKUs"})

        # Phase 6: Family grouping
        status({"phase": "family", "message": "Grouping product families..."})
        families = {}
        for sid, s in all_skus.items():
            base = get_base_name(s['Name']); s['BaseName'] = base
            families.setdefault(base, []).append(sid)

        propagate_keys = ['RAM','Disk','CPU','CPUModel','Model','ScreenCount','ScreenType','System','SystemDetail','AI']
        for idx, (base, members) in enumerate(families.items()):
            best = {k: next((all_skus[sid].get(k, '') for sid in members if all_skus[sid].get(k, '')), '') for k in propagate_keys}
            for sid in members:
                for k in propagate_keys:
                    if not all_skus[sid].get(k, ''): all_skus[sid][k] = best[k]
            if idx % 5 == 0 or idx == len(families) - 1:
                status({"phase": "family", "message": f"Processing families: {idx+1}/{len(families)}", "current": idx+1, "total": len(families)})

        # Phase 7: Output
        skus = []
        for sid, s in all_skus.items():
            skus.append({
                'skuId': sid, 'name': s['Name'], 'color': s['Color'], 'price': s['Price'],
                'commentCount': s['CommentCount'], 'avgScore': s['AvgScore'], 'goodRate': s['GoodRate'],
                'model': s['Model'], 'cpu': s['CPU'], 'cpuModel': s['CPUModel'], 'ram': s['RAM'], 'disk': s['Disk'],
                'screenCount': s['ScreenCount'], 'screenType': s['ScreenType'],
                'system': s['System'], 'systemDetail': s['SystemDetail'],
                'accessoryType': s['AccessoryType'], 'productType': s['ProductType'], 'ai': s['AI'],
                'baseName': s['BaseName'], 'attrs': s['Attrs'], 'extName': s['ExtName']
            })

        result = {'shopName': target_shop, 'shopId': shop_id, 'keyword': keyword,
                  'totalSkus': len(skus), 'familyCount': len(families), 'skus': skus,
                  'platform': 'jd'}
        status({"phase": "complete", "totalSkus": len(skus), "familyCount": len(families)})
        print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

if __name__ == '__main__':
    main()
