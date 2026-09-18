#!/usr/bin/env python3
"""Refresh the private sidebar lab snapshot with local OpenCode metadata.
No transcripts, credentials, source databases, or provider organization are changed.
"""
import json
import os
from pathlib import Path
import shlex
import sqlite3
import tempfile


def refresh(snapshot, database):
    source = snapshot.read_text()
    start = source.index('const history = ') + len('const history = ')
    history, length = json.JSONDecoder().raw_decode(source[start:])
    history = [r for r in history if r['provider'] != 'OpenCode']
    if database.exists():
        db = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=1)
        try:
            rows = db.execute('''SELECT id,directory,title,time_updated FROM session
                WHERE parent_id IS NULL AND time_archived IS NULL
                ORDER BY time_updated DESC LIMIT 200''').fetchall()
            for sid, directory, title, updated in rows:
                if not Path(directory).is_absolute():
                    continue
                history.append(dict(provider='OpenCode', id=sid, cwd=directory,
                    title=title or 'Untitled conversation', updated=updated/1000,
                    pinned=False, group=directory,
                    command=shlex.join(['opencode', '--session', sid])))
        finally:
            db.close()
    for row in history:
        cwd = row.get('cwd', '')
        # Full local directory identity; never merge merely matching basenames.
        row['canonical_folder'] = str(Path(cwd).resolve()) if Path(cwd).is_absolute() else ''
    encoded = json.dumps(history, ensure_ascii=False)
    fd, temporary = tempfile.mkstemp(dir=snapshot.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(source[:start] + encoded + source[start+length:])
        os.replace(temporary, snapshot)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return sum(r['provider'] == 'OpenCode' for r in history)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('--database', type=Path, default=Path.home()/'.local/share/opencode/opencode.db')
    args = parser.parse_args()
    print(f'Refreshed {refresh(args.snapshot, args.database)} OpenCode sessions')
