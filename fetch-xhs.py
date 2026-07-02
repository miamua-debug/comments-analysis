# fetch-xhs.py - Extract Xiaohongshu notes via Apify (zen-studio, no cookies needed)
import sys, json, argparse, time as _time, os

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

    status("init", "Initializing XHS scraper (zen-studio, no cookies)...")
    try:
        from apify_client import ApifyClient
        client = ApifyClient(token)
        ACTOR = 'zen-studio/rednote-search-scraper'

        status("search", f"Searching XHS for: {keyword}")
        run = client.actor(ACTOR).call(run_input={
            'keywords': [keyword],
            'maxResults': max(limit, 1),
            'sortType': 'general',
        })

        # Handle Pydantic v2
        run_dict = run.model_dump() if hasattr(run, 'model_dump') else run.dict()
        dataset_id = run_dict.get("default_dataset_id", run_dict.get("defaultDatasetId", ""))
        if not dataset_id:
            status("error", "No dataset ID in run result")
            print("DATA:" + json.dumps({"totalNotes": 0, "notes": [], "keyword": keyword}, ensure_ascii=False), flush=True)
            return

        # Retry dataset read
        items = []
        for attempt in range(3):
            try:
                items = list(client.dataset(dataset_id).iterate_items())
                break
            except Exception as e2:
                if attempt < 2:
                    status("detail", f"Dataset retry {attempt+1}/3...")
                    _time.sleep(5)

        if not items:
            result = {"totalNotes": 0, "notes": [], "keyword": keyword}
            print("DATA:" + json.dumps(result, ensure_ascii=False), flush=True)
            return

        notes = []
        for i, item in enumerate(items):
            d = item if isinstance(item, dict) else item.__dict__
            eng = d.get('engagement', {}) or {}
            author = d.get('author', {}) or {}

            notes.append({
                'index': i + 1,
                'noteId': d.get('id', ''),
                'url': d.get('url', ''),
                'title': d.get('title', ''),
                'content': (d.get('desc', '') or '').replace('\n', ' ').strip(),
                'likes': str(eng.get('liked_count', 0) or 0),
                'comments': str(eng.get('comments_count', 0) or 0),
                'collects': str(eng.get('collected_count', 0) or 0),
                'publishedAt': d.get('timestamp', ''),
                'author': author.get('nickname', ''),
                'authorUrl': author.get('userid', author.get('red_id', '')),
                'tags': '',
            })

            if (i + 1) % 10 == 0 or i == len(items) - 1:
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
