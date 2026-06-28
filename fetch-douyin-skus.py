# fetch-douyin-skus.py - Extract Douyin store SKUs via Apify
# Usage: python fetch-douyin-skus.py "品牌关键词" <ApifyToken> [maxPages]
import sys, json, os, argparse
from datetime import datetime
# Import shared spec parser
_sys_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _sys_path not in sys.path: sys.path.insert(0, _sys_path)
from shared.parse_specs import parse_specs

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('keyword', nargs='?', help='Search keyword')
    parser.add_argument('token', nargs='?', help='Apify API token')
    parser.add_argument('maxPages', nargs='?', type=int, default=10, help='Max pages')
    parser.add_argument('--file', help='JSON file with {keyword, apifyToken, maxPages}')
    args = parser.parse_args()

    # Read from file if provided (avoids encoding issues with CLI args)
    if args.file:
        with open(args.file, 'r', encoding='utf-8-sig') as f:
            config = json.load(f)
        keyword = config.get('keyword', '')
        token = config.get('apifyToken', '')
        max_pages = int(config.get('maxPages', 10))
    else:
        keyword = args.keyword or ''
        token = args.token or ''
        max_pages = args.maxPages or 10

    if not keyword or not token:
        print(json.dumps({"error": "keyword and apifyToken are required"}))
        sys.exit(1)

    # Status output helper
    def status(phase, message, **kwargs):
        d = {"phase": phase, "message": message}
        d.update(kwargs)
        print("STATUS:" + json.dumps(d, ensure_ascii=False), flush=True)

    status("search", f"Searching Douyin for: {keyword}")

    try:
        from apify_client import ApifyClient
        client = ApifyClient(token)

        # Step 1: Search
        run = client.actor("sian.agency/douyin-shop-scraper").call(run_input={
            "operation": "searchItem",
            "keyword": keyword,
            "maxPages": max_pages
        })
        items = list(client.dataset(run.dict()["default_dataset_id"]).iterate_items())

        if not items:
            status("search", "No results found")
            print("DATA:" + json.dumps({"totalSkus": 0, "skus": [], "shopName": "", "keyword": keyword}, ensure_ascii=False), flush=True)
            return

        # Step 2: Parse items
        plain_items = []
        shops = {}
        for item in items:
            d = item if isinstance(item, dict) else item.__dict__
            plain_items.append(d)
            si = d.get('shop_info', {}) if isinstance(d.get('shop_info'), dict) else {}
            sid = si.get('shop_id', '?')
            sn = si.get('shop_name', '?')
            if sid not in shops:
                shops[sid] = {'name': sn, 'count': 0}
            shops[sid]['count'] += 1

        status("search", f"Found {len(items)} items across {len(shops)} shops")

        # Step 3: Pick dominant shop
        target_id = max(shops.items(), key=lambda x: x[1]['count'])[0]
        target_name = shops[target_id]['name']

        # Step 4: Filter + deduplicate
        seen = set()
        store_items = []
        for d in plain_items:
            si = d.get('shop_info', {}) if isinstance(d.get('shop_info'), dict) else {}
            sid = si.get('shop_id', '?')
            pid = d.get('product_id', '')
            if sid == target_id and pid not in seen:
                seen.add(pid)
                store_items.append(d)

        status("filter", f"Filtered: {len(store_items)} SKUs from {target_name}")

        # Step 5: Build output
        skus = []
        for item in store_items:
            p = item.get('price', {}) if isinstance(item.get('price'), dict) else {}
            s = item.get('sales_info', {}) if isinstance(item.get('sales_info'), dict) else {}
            si = item.get('shop_info', {}) if isinstance(item.get('shop_info'), dict) else {}
            cat = f"{item.get('categoryFirst','')}/{item.get('categorySecond','')}".strip('/')

            name = item.get('product_title', '')
            sp = parse_specs(name, '', '')  # Douyin: no structured attrs or color, only name parsing
            skus.append({
                "skuId": str(item.get('product_id', '')),
                "name": name,
                "color": "",
                "price": p.get('price', 0) or 0,
                "commentCount": str(s.get('sales', 0)),
                "avgScore": 0,
                "goodRate": "",
                "model": sp['Model'],
                "cpu": sp['CPU'], "cpuModel": sp['CPUModel'], "ram": sp['RAM'], "disk": sp['Disk'],
                "screenCount": sp['ScreenCount'], "screenType": sp['ScreenType'],
                "system": sp['System'], "systemDetail": sp['SystemDetail'],
                "accessoryType": sp['AccessoryType'] or cat,
                "productType": sp['ProductType'] or cat,
                "ai": sp['AI'],
                "baseName": name,
                "attrs": "",
                "extName": ""
            })

        result = {
            "shopName": target_name,
            "shopId": str(target_id),
            "keyword": keyword,
            "totalSkus": len(skus),
            "familyCount": len(set(s.get('baseName','') for s in skus)),
            "platform": "douyin",
            "skus": skus
        }

        status("complete", f"Total: {len(skus)} SKUs", totalSkus=len(skus))
        print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)

    except ImportError:
        status("error", "apify-client not installed. Run: pip install apify-client")
        print("DATA:" + json.dumps({"error": "apify-client not installed", "totalSkus": 0, "skus": []}, ensure_ascii=False), flush=True)
    except Exception as e:
        status("error", str(e))
        print("DATA:" + json.dumps({"error": str(e), "totalSkus": 0, "skus": []}, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
