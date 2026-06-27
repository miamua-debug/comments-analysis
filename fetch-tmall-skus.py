# fetch-tmall-skus.py - Extract Tmall store SKUs via Apify
# Usage: python fetch-tmall-skus.py --file <config.json>
import sys, json, argparse, time
from datetime import datetime

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('keyword', nargs='?')
    parser.add_argument('token', nargs='?')
    parser.add_argument('maxPages', nargs='?', type=int, default=3)
    parser.add_argument('--file', help='JSON config file')
    args = parser.parse_args()

    if args.file:
        with open(args.file, 'r', encoding='utf-8-sig') as f:
            config = json.load(f)
        keyword = config.get('keyword', '')
        token = config.get('apifyToken', '')
        max_pages = int(config.get('maxPages', 3))
    else:
        keyword = args.keyword or ''; token = args.token or ''; max_pages = args.maxPages or 3

    if not keyword or not token:
        print(json.dumps({"error":"keyword and apifyToken required"})); sys.exit(1)

    def status(phase, message, **kw):
        d = {"phase": phase, "message": message}; d.update(kw)
        print("STATUS:" + json.dumps(d, ensure_ascii=False), flush=True)

    try:
        from apify_client import ApifyClient
        client = ApifyClient(token)
        ACTOR = 'sian.agency/taobao-tmall-product-scraper'

        status("search", f"Searching Tmall for: {keyword} (this takes 30-90s, please wait...)")
        run = client.actor(ACTOR).call(run_input={
            'operation': 'keywordSearch', 'keyword': keyword, 'tmallOnly': True, 'maxPages': 2
        })
        items = list(client.dataset(run.dict()["default_dataset_id"]).iterate_items())
        if not items:
            print("DATA:" + json.dumps({"totalSkus":0,"skus":[],"shopName":"","keyword":keyword}, ensure_ascii=False), flush=True)
            return

        shops = {}
        for item in items:
            d = item if isinstance(item, dict) else item.__dict__
            sid = d.get('shopId', '?'); sn = d.get('shopName', '?')
            if sid not in shops: shops[sid] = {'name': sn, 'count': 0}
            shops[sid]['count'] += 1
        target_id = max(shops.items(), key=lambda x: x[1]['count'])[0]
        target_name = shops[target_id]['name']
        status("search", f"Target shop: {target_name}")

        status("catalog", f"Fetching catalog for {target_name} (this takes 30-60s, please wait...)")
        run2 = client.actor(ACTOR).call(run_input={
            'operation': 'shopCatalog', 'catalogVersion': 'v1', 'userId': target_id, 'maxPages': max_pages
        })
        catalog = list(client.dataset(run2.dict()["default_dataset_id"]).iterate_items())
        products = [item if isinstance(item, dict) else item.__dict__ for item in catalog]
        status("catalog", f"Got {len(products)} products", total=len(products))

        skus = []
        for p in products:
            sales = str(p.get('tkTotalSalesFuzzyString', '') or p.get('biz365DayFuzzyString', ''))
            skus.append({
                "skuId": str(p.get('itemId','')), "name": p.get('itemName', p.get('title','')),
                "color": p.get('shortTitle',''), "price": float(p.get('zkFinalPrice', p.get('price',0)) or 0),
                "commentCount": sales, "avgScore": 0,
                "goodRate": str(round(float(p.get('goodRate',0))/100,1)) if p.get('goodRate') else '',
                "model": "", "cpu": "", "cpuModel": "", "ram": "", "disk": "",
                "screenCount": "", "screenType": "", "system": "", "systemDetail": "",
                "accessoryType": p.get('categoryName',''), "productType": p.get('categoryName',''),
                "ai": "", "baseName": p.get('itemName',''), "attrs": str(p.get('algoTags','')),
                "extName": ""
            })

        result = {"shopName": target_name, "shopId": str(target_id), "keyword": keyword,
                  "totalSkus": len(skus), "familyCount": len(set(s['baseName'] for s in skus)),
                  "platform": "tmall", "skus": skus}
        status("complete", f"Total: {len(skus)} SKUs", totalSkus=len(skus))
        print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)

    except ImportError:
        print("DATA:" + json.dumps({"error":"apify-client not installed","totalSkus":0,"skus":[]}, ensure_ascii=False), flush=True)
    except Exception as e:
        status("error", str(e)[:200])
        print("DATA:" + json.dumps({"error":str(e)[:200],"totalSkus":0,"skus":[]}, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
