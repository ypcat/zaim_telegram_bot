#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///
"""Import Zaim exports (*_zaim.jsonl) into the account book, zaim.db.

    ./import_zaim.py                       # the newest *_zaim.jsonl here
    ./import_zaim.py 20261004_zaim.jsonl   # or the files named

Safe to run any number of times, with the bot running or not: entries already
in the book (same Zaim id) are skipped, cancelled ones included.
"""

import glob
import os
import sys

import zaim_db

def main():
    paths = sys.argv[1:] or sorted(glob.glob(os.path.join(zaim_db.HERE,
                                                          '*_zaim.jsonl')))[-1:]
    if not paths:
        sys.exit('No *_zaim.jsonl in %s; name the file to import.' % zaim_db.HERE)
    book = zaim_db.Api()
    for path in paths:
        added, skipped = book.import_jsonl(path)
        print('%s: added %d, skipped %d already in the book' % (path, added, skipped))

if __name__ == '__main__':
    main()
