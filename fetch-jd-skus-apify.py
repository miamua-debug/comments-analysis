# fetch-jd-skus-apify.py - Extract JD store SKUs via Apify (for Railway/online deployment)
import sys, json, argparse, time as _time, os

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--keyword', help='Search keyword')
    parser.add_argument('--token', help='Apify API token')
    parser.add_argument('--shopId', help='JD shop ID (for reference)')
    parser.add_argument('--targetShop', help='Target shop name substring')
    parser.add_argument('--maxPages', type=int, default=3)
    parser.add_argument('--file', help='JSON config file')
    args = parser.parse_args()

    if args.file:
        with open(args.file, 'r', encoding='utf-8-sig') as f:
            config = json.load(f)
        keyword = config.get('keyword', '')
        token = config.get('apifyToken', '')
        shop_id = config.get('shopId', '')
        target_shop = config.get('targetShop', '')
    else:
        keyword = args.keyword or ''
        token = args.token or ''
        shop_id = args.shopId or ''
        target_shop = args.targetShop or ''

    if not keyword or not token:
        print(json.dumps({"error": "keyword and apifyToken required"})); sys.exit(1)

    def status(phase, message, **kw):
        d = {"phase": phase, "message": message}; d.update(kw)
        print("STATUS:" + json.dumps(d, ensure_ascii=False), flush=True)

    status("init", "Initializing JD scraper via Apify...")
    try:
        from apify_client import ApifyClient
        client = ApifyClient(token)
        ACTOR = 'sian.agency/jd-com-product-scraper'
        DETAIL_ACTOR = 'zen-studio/jd-com-search-scraper'

        # Step 1: keywordSearch to find target shop
        status("search", f"Searching JD for: {keyword}")
        run = client.actor(ACTOR).call(run_input={
            'operation': 'keywordSearch',
            'keyword': keyword,
            'maxPages': 1,
        })
        run_dict = run.model_dump() if hasattr(run, 'model_dump') else run.dict()
        items = list(client.dataset(run_dict["default_dataset_id"]).iterate_items())
        items = [i if isinstance(i, dict) else i.__dict__ for i in items]

        if not items:
            print("DATA:" + json.dumps({"totalSkus": 0, "skus": [], "shopName": "", "keyword": keyword, "platform": "jd"}, ensure_ascii=False), flush=True)
            return

        # Find target shop
        shops = {}
        for d in items:
            sid = str(d.get('shopId', d.get('shop_id', '?')))
            sn = d.get('shopName', d.get('shop_name', '?'))
            if sid not in shops: shops[sid] = {'name': sn, 'count': 0}
            shops[sid]['count'] += 1

        if target_shop:
            # User-specified: find matching shop
            matching = [(sid, info) for sid, info in shops.items() if target_shop in info['name']]
            if matching:
                matching.sort(key=lambda x: -x[1]['count'])
                target_id, target_info = matching[0]
            else:
                target_id = max(shops, key=lambda x: shops[x]['count'])
                target_info = shops[target_id]
        else:
            # Auto-detect: prefer shop with keyword in name, then largest
            kw_match = {sid: info for sid, info in shops.items() if keyword[:2] in info['name']}
            if kw_match:
                target_id = max(kw_match, key=lambda x: kw_match[x]['count'])
            else:
                target_id = max(shops, key=lambda x: shops[x]['count'])
            target_info = shops[target_id]

        target_name = target_info['name']
        status("search", f"Target shop: {target_name} (ID: {target_id})")

        # Step 2: shopCatalog — get ALL products from target shop
        status("catalog", f"Fetching catalog for {target_name}...")
        run2 = client.actor(ACTOR).call(run_input={
            'operation': 'shopCatalog',
            'shopId': target_id,
            'maxPages': args.maxPages or 3,
        })
        run2_dict = run2.model_dump() if hasattr(run2, 'model_dump') else run2.dict()
        catalog = list(client.dataset(run2_dict["default_dataset_id"]).iterate_items())
        catalog = [i if isinstance(i, dict) else i.__dict__ for i in catalog]
        status("catalog", f"Got {len(catalog)} products", total=len(catalog))

        # Build SKU list from catalog
        skus = []
        for item in catalog:
            skus.append({
                'skuId': str(item.get('itemId', item.get('skuId', ''))),
                'name': item.get('itemName', item.get('title', '')),
                'color': item.get('color', item.get('shortTitle', '')),
                'price': float(item.get('zkFinalPrice', item.get('price', 0)) or 0),
                'commentCount': str(item.get('commentCount', item.get('commentCountStr', '')) or ''),
                'avgScore': item.get('avgScore', item.get('averageScore', 0)) or 0,
                'goodRate': str(item.get('goodRate', item.get('goodRateShow', '')) or ''),
                'model': '', 'cpu': '', 'cpuModel': '', 'ram': '', 'disk': '',
                'screenCount': '', 'screenType': '',
                'system': '', 'systemDetail': '',
                'accessoryType': '', 'productType': '',
                'ai': '', 'baseName': item.get('itemName', item.get('title', '')),
                'attrs': '', 'extName': '',
            })

        # Step 3: Parse specs from product names (no detail scraper for JD to save cost)
        status("parse", "Parsing specs from product names...")
        # Import shared parse_specs
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'shared'))
        from parse_specs import parse_specs

        for s in skus:
            sp = parse_specs(s['name'], s['color'], s.get('attrs', ''))
            for k in sp:
                if s.get(k, '') == '':
                    s[k] = sp[k]

        result = {
            'shopName': target_name, 'shopId': str(target_id), 'keyword': keyword,
            'totalSkus': len(skus), 'familyCount': len(set(s['baseName'] for s in skus)),
            'platform': 'jd', 'skus': skus,
        }
        status("complete", f"Total: {len(skus)} SKUs", totalSkus=len(skus))
        print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)

    except ImportError:
        print("DATA:" + json.dumps({"error": "apify-client not installed", "totalSkus": 0, "skus": []}, ensure_ascii=False), flush=True)
    except Exception as e:
        status("error", str(e)[:200])
        print("DATA:" + json.dumps({"error": str(e)[:200], "totalSkus": 0, "skus": []}, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
