# fetch-tmall-skus.py - Extract Tmall store SKUs via Apify
import sys, json, argparse, time, os
# Import shared spec parser (JD + Tmall unified)
_sys_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _sys_path not in sys.path: sys.path.insert(0, _sys_path)
from shared.parse_specs import parse_specs

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

    status("init", "Initializing Tmall scraper...")
    try:
        from apify_client import ApifyClient
        client = ApifyClient(token)
        SEARCH_ACTOR = 'sian.agency/taobao-tmall-product-scraper'
        DETAIL_ACTOR = 'zen-studio/taobao-detail-scraper'

        # Step 1: keywordSearch
        status("search", f"Searching Tmall for: {keyword}")
        run = client.actor(SEARCH_ACTOR).call(run_input={
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

        # Step 2: shopCatalog
        status("catalog", f"Fetching catalog for {target_name}...")
        run2 = client.actor(SEARCH_ACTOR).call(run_input={
            'operation': 'shopCatalog', 'catalogVersion': 'v1', 'userId': target_id, 'maxPages': max_pages
        })
        catalog = list(client.dataset(run2.dict()["default_dataset_id"]).iterate_items())
        products = [item if isinstance(item, dict) else item.__dict__ for item in catalog]
        status("catalog", f"Got {len(products)} products", total=len(products))

        # Build title lookup from keywordSearch items (shopCatalog lacks itemName!)
        title_lookup = {}
        for item in items:
            d = item if isinstance(item, dict) else item.__dict__
            iid = d.get('itemId', '')
            i_name = d.get('itemName', d.get('title', ''))
            if iid and i_name:
                title_lookup[iid] = i_name

        # Step 3: Get SKU variants via zen-studio detail scraper
        total_products = len(products)
        max_detail = min(total_products, 50)  # cap at 50 for Apify cost control
        status("detail", f"Getting SKU variants for {max_detail}/{total_products} products...")
        all_skus = []

        for idx, p in enumerate(products):
            pid = p.get('itemId', '')
            if not pid: continue

            # Products beyond max: SPU only (no detail scraper)
            if idx >= max_detail:
                all_skus.append(make_spu(p, pid, detail_title=title_lookup.get(pid, '')))
                continue

            # Skip accessories/cheap to save Apify cost
            cat = str(p.get('categoryName', '')).lower()
            is_acc = any(kw in cat for kw in ['纸','配件','耗材','标签','差价','墨','碳带','色带'])
            is_cheap = float(p.get('zkFinalPrice', p.get('price', 0)) or 0) < 100
            has_detail = False

            if not (is_acc or is_cheap):
                try:
                    url = f'https://detail.tmall.com/item.htm?id={pid}'
                    rd = client.actor(DETAIL_ACTOR).call(run_input={'items': [url]})
                    did = rd['defaultDatasetId'] if isinstance(rd, dict) else rd.default_dataset_id
                    detail_items = list(client.dataset(did).iterate_items())
                    if detail_items:
                        d = detail_items[0].__dict__ if hasattr(detail_items[0], '__dict__') else dict(detail_items[0])
                        # Get product title from detail (shopCatalog items lack itemName!)
                        detail_title = d.get('titleOriginal', '') or d.get('title', '')
                        attr_map = {}
                        # Build JD-compatible attrs string from ALL attributes
                        # IMPORTANT: Tmall detail scraper uses originalName/originalValue for Chinese
                        # (name/value are English translations — useless for Chinese regex matching)
                        attrs_parts = []
                        seen_attr_names = set()
                        for a in d.get('attributes', []):
                            vid = a.get('vid', '')
                            val = a.get('originalValue', '') or a.get('value', '')
                            # Use Chinese name (originalName) with English fallback (name)
                            attr_name = a.get('originalName', '') or a.get('name', '') or a.get('label', '')
                            if a.get('isConfigurator'):
                                attr_map[vid] = val
                            # Collect ALL attributes as key:value for specs parsing
                            if attr_name and val and attr_name not in seen_attr_names:
                                seen_attr_names.add(attr_name)
                                attrs_parts.append(f"{attr_name}:{val}")
                        attrs_str = '^'.join(attrs_parts) if attrs_parts else ''
                        # Extract comment count from detail's featuredValues
                        fv = d.get('featuredValues', {}) or {}
                        detail_comment = str(fv.get('reviews', '') or fv.get('TotalSales', '') or '')
                        detail_sales = str(fv.get('SalesInLast30Days', '') or fv.get('TotalSales', '') or '')
                        # Also try to get goodRate from search result if available
                        detail_good_rate = str(fv.get('goodRate', '') or '')

                        for sku in d.get('skus', []):
                            names = []
                            for cfg in sku.get('configurators', []):
                                vid = cfg.get('vid', '')
                                if vid in attr_map: names.append(attr_map[vid])
                            pinfo = sku.get('price', {})
                            price = float(pinfo.get('originalPrice', 0)) if isinstance(pinfo, dict) else 0
                            sku_sales = str(sku.get('salesCount', '') or '')
                            all_skus.append(make_spu(p, pid,
                                spec=' / '.join(names) if names else '',
                                sku_id=str(sku.get('skuId', pid)), price=price,
                                attrs_str=attrs_str, detail_comment=detail_comment,
                                detail_sales=detail_sales, detail_good_rate=detail_good_rate,
                                sku_sales=sku_sales, detail_title=detail_title))
                        has_detail = (len(d.get('skus', [])) > 0)
                except Exception as e:
                    status("detail", f"Product {pid} detail error: {str(e)[:60]}")

            if not has_detail:
                all_skus.append(make_spu(p, pid, detail_title=title_lookup.get(pid, '')))

            if (idx+1) % 3 == 0:
                status("detail", f"Progress: {idx+1}/{total_products}, {len(all_skus)} SKUs", current=idx+1, total=total_products)
            time.sleep(0.5)

        result = {"shopName": target_name, "shopId": str(target_id), "keyword": keyword,
                  "totalSkus": len(all_skus), "familyCount": len(set(s.get('baseName','') for s in all_skus)),
                  "platform": "tmall", "skus": all_skus}
        status("complete", f"Total: {len(all_skus)} SKUs", totalSkus=len(all_skus))
        print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)

    except ImportError:
        print("DATA:" + json.dumps({"error":"apify-client not installed","totalSkus":0,"skus":[]}, ensure_ascii=False), flush=True)
    except Exception as e:
        status("error", str(e)[:200])
        print("DATA:" + json.dumps({"error":str(e)[:200],"totalSkus":0,"skus":[]}, ensure_ascii=False), flush=True)


def make_spu(p, pid, spec=None, sku_id=None, price=None, attrs_str=None, detail_comment=None, detail_sales=None, detail_good_rate=None, sku_sales=None, detail_title=None):
    """Build a SKU dict from search result + optional detail scraper data

    Args:
        p: search result dict (from keywordSearch/shopCatalog — NOTE: shopCatalog lacks itemName!)
        detail_title: product title from detail scraper (essential: shopCatalog has no itemName)
        pid: product/item ID
        spec: SKU variant spec string (e.g. '4G+64G / 白色')
        sku_id: specific SKU ID from detail scraper (overrides pid)
        price: specific SKU price from detail scraper (overrides search price)
        attrs_str: JD-compatible '^'-separated attrs from detail scraper (overrides algoTags)
        detail_comment: SPU-level reviews count from detail featuredValues.reviews
        detail_sales: SPU-level sales from detail featuredValues
        detail_good_rate: good rate from detail if available
        sku_sales: per-SKU sales count from detail sku.salesCount
    """
    # IMPORTANT: shopCatalog has NO itemName/title — detail_title is essential
    name = detail_title or p.get('itemName', p.get('title', ''))
    color = spec or p.get('shortTitle', '')

    # Use structured attrs from detail scraper when available (Bug 2+3 fix)
    effective_attrs = attrs_str if attrs_str else ''
    sp = parse_specs(name, color, effective_attrs)

    # Comment count: SPU-level reviews (featuredValues.reviews) + optional per-SKU sales
    # Tmall's review count is at product (SPU) level, NOT per-SKU — all variants share it
    comment_parts = []
    if detail_comment:
        comment_parts.append(detail_comment)  # SPU reviews (e.g. '7839')
    if sku_sales and sku_sales != '0':
        comment_parts.append(f"(SKU销量:{sku_sales})")
    if detail_sales and not comment_parts:
        comment_parts.append(detail_sales + ' (SPU销量)')
    if comment_parts:
        comment_display = ' '.join(comment_parts)
    else:
        # Fallback: shopCatalog has tkTotalSalesFuzzyString, keywordSearch has orderPayUV
        comment_display = str(p.get('tkTotalSalesFuzzyString', '') or p.get('orderPayUV', '') or '')

    # Good rate: shopCatalog has goodRateAvg, keywordSearch has itemGradeAvg
    item_grade = p.get('itemGradeAvg', p.get('goodRateAvg', 0))
    shop_good_rate = p.get('goodRate', 0)  # shopCatalog: 10000=100%
    if detail_good_rate:
        good_rate_str = detail_good_rate
    elif shop_good_rate and float(shop_good_rate) > 0:
        good_rate_str = str(round(float(shop_good_rate) / 100, 1))  # e.g. 10000 → 100.0
    elif item_grade and float(item_grade) > 0:
        good_rate_str = str(round(float(item_grade) / 5 * 100, 1))  # itemGradeAvg is 0-5
    else:
        good_rate_str = ''

    # Price: detail SKU price > search price (shopCatalog vs keywordSearch use different fields)
    if price is not None:
        final_price = price
    elif 'minTrdPrice' in p:  # shopCatalog
        final_price = float(p.get('minTrdPrice', p.get('price', 0)) or 0)
    else:  # keywordSearch
        final_price = float(p.get('priceZKYuanDouble', p.get('zkFinalPrice', p.get('priceYuanDouble', p.get('price', 0)))) or 0)

    return {
        "skuId": sku_id or str(pid),
        "name": name, "color": color,
        "price": final_price,
        "commentCount": comment_display,
        "avgScore": round(float(item_grade), 1) if item_grade and float(item_grade) > 0 else 0,
        "goodRate": good_rate_str,
        "model": sp['Model'], "cpu": sp['CPU'], "cpuModel": sp['CPUModel'],
        "ram": sp['RAM'], "disk": sp['Disk'],
        "screenCount": sp['ScreenCount'], "screenType": sp['ScreenType'],
        "system": sp['System'], "systemDetail": sp['SystemDetail'],
        "accessoryType": sp['AccessoryType'] or p.get('categoryName', ''),
        "productType": sp['ProductType'] or p.get('categoryName', ''),
        "ai": sp['AI'],
        "baseName": p.get('itemName', ''),
        "attrs": effective_attrs, "extName": ""
    }

if __name__ == '__main__':
    main()
