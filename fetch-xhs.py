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
            'searchKeyword': keyword,
            'maxItems': limit,
            'sortType': 'general',
        })

        items = list(client.dataset(run.dict()["default_dataset_id"]).iterate_items())
        if not items:
            result = {"totalNotes": 0, "notes": [], "keyword": keyword}
            print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)
            return

        notes = []
        for i, item in enumerate(items):
            d = item if isinstance(item, dict) else item.__dict__
            notes.append({
                'index': i + 1,
                'noteId': d.get('noteId', d.get('id', '')),
                'url': d.get('noteUrl', d.get('url', '')),
                'title': d.get('title', d.get('noteTitle', '')),
                'content': (d.get('desc', d.get('content', '')) or '').replace('\n', ' ').strip(),
                'likes': str(d.get('likes', d.get('likedCount', 0)) or 0),
                'comments': str(d.get('comments', d.get('commentsCount', 0)) or 0),
                'collects': str(d.get('collects', d.get('collectedCount', 0)) or 0),
                'publishedAt': d.get('publishTime', d.get('time', '')),
                'author': d.get('author', d.get('nickname', d.get('user', {}).get('nickname', '')) if isinstance(d.get('user'), dict) else ''),
                'authorUrl': d.get('authorUrl', d.get('user', {}).get('userId', '') if isinstance(d.get('user'), dict) else ''),
                'tags': ', '.join(d.get('tags', d.get('tagList', []))) if isinstance(d.get('tags', []), list) else '',
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
