# fetch-jd.py - Fetch all reviews for a JD product (SPU-level, all SKUs)
import sys, json, re, time, argparse
import requests

def status(msg):
    print("STATUS:" + json.dumps(msg, ensure_ascii=False), flush=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sku', required=True)
    args = parser.parse_args()
    sku = args.sku
    headers = {"User-Agent": "Mozilla/5.0", "Referer": f"https://item.jd.com/{sku}.html"}
    mheaders = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"}

    status({"phase": "discover", "message": "Discovering SKUs under same SPU..."})

    # Step 1: Discover SKUs
    all_sku_ids = {}
    try:
        r = requests.get(f"https://item.m.jd.com/product/{sku}.html", headers=mheaders, timeout=15)
        content = r.text
        m = re.search(r'"skuList"\s*:\s*(\[[^\]]+\])', content)
        if m:
            for s in json.loads(m.group(1)):
                all_sku_ids[s['skuId']] = True
        # Only fallback to broad regex if skuList not found (some product pages lack it)
        if not all_sku_ids:
            for m2 in re.finditer(r'"sku\w*"\s*:\s*"?(\d{10,})"?', content):
                all_sku_ids[m2.group(1)] = True
    except: pass
    all_sku_ids[sku] = True
    status({"phase": "discover", "message": f"Found {len(all_sku_ids)} candidate SKUs"})

    # Step 2: Validate SKUs
    status({"phase": "validate", "message": "Validating SKUs..."})
    valid_skus = []
    product_name = ""

    for sid in all_sku_ids:
        try:
            r = requests.get(
                f"https://club.jd.com/comment/skuProductPageComments.action?productId={sid}&score=0&sortType=5&page=1&pageSize=1",
                headers=headers, timeout=10
            )
            data = r.json()
            if data.get('comments') and len(data['comments']) > 0:
                ref = data['comments'][0]['referenceName']
                color = data['comments'][0].get('productColor', '')
                mp = data.get('maxPage', 0) or 1
                s = data.get('productCommentSummary', {})
                if not product_name: product_name = ref
                valid_skus.append({
                    'sku': sid, 'name': ref, 'color': color, 'maxPage': mp,
                    'total': s.get('commentCountStr', '0'), 'avgScore': s.get('averageScore', 0),
                    'goodRate': s.get('goodRateShow', 0)
                })
                status({"phase": "validate", "message": f"SKU {sid} ({color}) - {s.get('commentCountStr','?')} reviews"})
        except: pass
        time.sleep(0.3)

    status({"phase": "validate", "message": f"Valid SKUs: {len(valid_skus)}"})

    # Step 3: Fetch all reviews
    all_comments = []
    total = 0
    for vs in valid_skus:
        sid = vs['sku']
        for page in range(1, vs['maxPage'] + 1):
            try:
                r = requests.get(
                    f"https://club.jd.com/comment/skuProductPageComments.action?productId={sid}&score=0&sortType=5&page={page}&pageSize=10",
                    headers=headers, timeout=15
                )
                data = r.json()
                for c in data.get('comments', []):
                    all_comments.append({
                        'SKU': sid, 'page': page, 'id': c.get('id',''), 'nickname': c.get('nickname',''),
                        'score': c.get('score',0), 'content': (c.get('content','') or '').replace('\n',' ').strip(),
                        'color': c.get('productColor',''), 'location': c.get('location',''),
                        'creationTime': c.get('creationTime',''), 'referenceTime': c.get('referenceTime',''),
                        'imageCount': c.get('imageCount',0), 'usefulVoteCount': c.get('usefulVoteCount',0),
                        'replyCount': c.get('replyCount',0), 'days': c.get('days',0), 'afterDays': c.get('afterDays',0),
                        'anonymous': c.get('anonymousFlag',0), 'userClient': c.get('userClient',0),
                        'plus': c.get('plusAvailable',0)
                    })
                total += len(data.get('comments', []))
                status({"phase": "fetch", "sku": sid, "currentPage": page, "maxPage": vs['maxPage'], "totalFetched": total})
            except: pass
            if page < vs['maxPage']: time.sleep(0.5)

    # Step 4: Output
    result = {
        'productName': product_name, 'skuCount': len(valid_skus), 'totalReviews': len(all_comments),
        'skus': valid_skus, 'reviews': all_comments
    }
    status({"phase": "complete", "productName": product_name, "skuCount": len(valid_skus), "totalReviews": len(all_comments)})
    print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
