"""Summarize only the isolated simulator fixture; never print message or grant contents."""
from pathlib import Path
import sqlite3
import sys

for path in sorted(Path(sys.argv[1]).glob("Library/Application Support/ReplySyncFixtures/*/chat.sqlite")):
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        print("fixture", path.parent.name, "jobs", db.execute("SELECT count(*) FROM backgroundReplies").fetchone()[0])
        for row in db.execute("SELECT role,status,length(content),length(reasoning) FROM messages ORDER BY rowid"):
            print("  message", *row)
    for job in (path.parent / "ReplyTransfers").glob("*"):
        print("  transfer", {f.name: f.stat().st_size for f in job.iterdir() if f.is_file()})
