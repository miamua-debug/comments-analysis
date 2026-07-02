# fetch-xhs.py - Extract Xiaohongshu notes via Apify (replaces opencli for Railway deployment)
import sys, json, argparse

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--keyword', help='Search keyword')
    parser.add_argument('--token', help='Apify API token')
    parser.add_argument('--limit', type=int, default=20, help='Max notes')
    parser.add_argument('--file', help='JSON config file {keyword, apifyToken, limit}')
    args = parser.parse_args()

    if args.file:
        with open(args.file, 'r', encoding='utf-8-sig') as f:
            config = json.load(f)
        keyword = config.get('keyword', '')
        token = config.get('apifyToken', '')
        limit = int(config.get('limit', 20))
    else:
        keyword = args.keyword or ''
        token = args.token or ''
        limit = args.limit

    if not keyword or not token:
        print(json.dumps({"error": "keyword and apifyToken required"})); sys.exit(1)

    def status(phase, message, **kw):
        d = {"phase": phase, "message": message}; d.update(kw)
        print("STATUS:" + json.dumps(d, ensure_ascii=False), flush=True)

    status("init", "Initializing XHS scraper via Apify...")
    try:
        from apify_client import ApifyClient
        client = ApifyClient(token)
        ACTOR = 'easyapi/rednote-xiaohongshu-search-scraper'

        status("search", f"Searching XHS for: {keyword}")
        run = client.actor(ACTOR).call(run_input={
            'keywords': [keyword],
            'maxItems': max(limit, 100),
            'sortType': 'general',
            'noteType': 'all',
        })

        items = list(client.dataset(run.dict()["default_dataset_id"]).iterate_items())
        if not items:
            result = {"totalNotes": 0, "notes": [], "keyword": keyword}
            print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)
            return

        notes = []
        for i, item in enumerate(items):
            d = item if isinstance(item, dict) else item.__dict__
            inner = d.get('item', {}) or {}
            card = inner.get('note_card', {}) or {}
            user = card.get('user', {}) or {}
            interact = card.get('interact_info', {}) or {}
            cover = card.get('cover', {}) or {}

            notes.append({
                'index': i + 1,
                'noteId': inner.get('id', d.get('id', '')),
                'url': d.get('link', ''),
                'title': card.get('display_title', ''),
                'content': '',  # not provided by this actor
                'likes': str(interact.get('liked_count', 0) or 0),
                'comments': '0',   # not provided
                'collects': '0',   # not provided
                'publishedAt': d.get('scrapedAt', ''),
                'author': user.get('nick_name', user.get('nickname', '')),
                'authorUrl': user.get('user_id', ''),
                'tags': '',
            })

            if (i + 1) % 5 == 0 or i == len(items) - 1:
                status("detail", f"Parsed {i+1}/{len(items)} notes", current=i+1, total=len(items))

        result = {'keyword': keyword, 'totalNotes': len(notes), 'notes': notes}
        status("complete", f"Total: {len(notes)} notes", totalNotes=len(notes))
        print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)

    except ImportError:
        print("DATA:" + json.dumps({"error": "apify-client not installed", "totalNotes": 0, "notes": []}, ensure_ascii=False), flush=True)
    except Exception as e:
        status("error", str(e)[:200])
        print("DATA:" + json.dumps({"error": str(e)[:200], "totalNotes": 0, "notes": []}, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
