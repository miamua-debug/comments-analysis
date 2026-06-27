# fetch-xhs.py - Extract Xiaohongshu notes via opencli
import sys, json, re, argparse, subprocess, tempfile, os

def status(msg):
    print("STATUS:" + json.dumps(msg, ensure_ascii=False), flush=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--keyword', required=True)
    parser.add_argument('--limit', type=int, default=20)
    parser.add_argument('--profile', default='hkzg2bpx')
    args = parser.parse_args()

    status({"phase": "search", "message": f"Searching XHS for: {args.keyword}"})

    # Step 1: Search
    try:
        result = subprocess.run(
            f'opencli --profile {args.profile} xiaohongshu search "{args.keyword}" --limit {args.limit} -f json',
            shell=True, capture_output=True, text=True, timeout=120, encoding='utf-8', errors='replace'
        )
        output = result.stdout.strip()
        # Extract JSON array from output
        start = output.find('['); end = output.rfind(']')
        if start >= 0 and end > start:
            search_data = json.loads(output[start:end+1])
        else:
            search_data = []
    except Exception as e:
        status({"phase": "error", "message": f"Search failed: {e}"})
        search_data = []

    total = len(search_data) if isinstance(search_data, list) else 0
    if total == 0:
        print("DATA:" + json.dumps({"totalNotes": 0, "notes": []}, ensure_ascii=False), flush=True)
        return

    status({"phase": "search", "message": f"Found {total} notes", "total": total})

    # Step 2: Get details
    notes = []
    for i, item in enumerate(search_data):
        url = item.get('url', '')
        note_id = ''
        if m := re.search(r'search_result/([a-f0-9]+)', url): note_id = m.group(1)

        content, collects, comments, tags = '', '0', '0', ''
        if url:
            try:
                result2 = subprocess.run(
                    f'opencli --profile {args.profile} xiaohongshu note "{url}" -f json',
                    shell=True, capture_output=True, text=True, timeout=30, encoding='utf-8', errors='replace'
                )
                detail_output = result2.stdout.strip()
                ds = detail_output.find('['); de = detail_output.rfind(']')
                if ds >= 0 and de > ds:
                    detail = json.loads(detail_output[ds:de+1])
                    for d in detail:
                        fld = d.get('field', ''); val = d.get('value', '')
                        if fld == 'content': content = val
                        elif fld == 'collects': collects = val
                        elif fld == 'comments': comments = val
                        elif fld == 'tags': tags = val
            except: pass

        notes.append({
            'index': i+1, 'noteId': note_id, 'url': url, 'title': item.get('title',''),
            'content': (content or '').replace('\n',' ').strip(),
            'likes': str(item.get('likes','0')), 'comments': comments, 'collects': collects,
            'publishedAt': item.get('published_at',''), 'author': item.get('author',''),
            'authorUrl': item.get('author_url',''), 'tags': tags
        })

        if (i+1) % 5 == 0 or i == total - 1:
            status({"phase": "detail", "message": f"Fetched {i+1}/{total}", "current": i+1, "total": total})

    status({"phase": "complete", "totalNotes": len(notes)})
    result_data = {'keyword': args.keyword, 'totalNotes': len(notes), 'notes': notes}
    print("DATA:" + json.dumps(result_data, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
