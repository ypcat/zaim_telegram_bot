# -*- coding: utf-8 -*-
"""The account book, kept locally in SQLite.

Stands in for the Zaim API, which blocked the bot's host in October 2026.
Method names, parameters and response shapes follow Zaim API v2
(dev.zaim.net) for the calls the bot makes, so bot.py reads the same either
way. Single user: no OAuth, no user ids.

Rows have the columns of Zaim's GET /v2/home/money, so a Zaim export
(*_zaim.jsonl, one money object per line) imports as is: see import_zaim.py.
Cancelled entries are kept with active=0, as Zaim does.
"""

import contextlib
import datetime
import json
import os
import sqlite3
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, 'zaim.db')

COLUMNS = ('id', 'user_id', 'date', 'mode', 'category_id', 'genre_id',
           'from_account_id', 'to_account_id', 'amount', 'comment', 'active',
           'created', 'currency_code', 'name', 'receipt_id', 'place_uid',
           'place')

SCHEMA = '''
CREATE TABLE IF NOT EXISTS money (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL DEFAULT 0,
    date TEXT NOT NULL,
    mode TEXT NOT NULL,
    category_id INTEGER NOT NULL,
    genre_id INTEGER NOT NULL DEFAULT 0,
    from_account_id INTEGER NOT NULL DEFAULT 0,
    to_account_id INTEGER NOT NULL DEFAULT 0,
    amount INTEGER NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 1,
    created TEXT NOT NULL,
    currency_code TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    receipt_id INTEGER NOT NULL DEFAULT 0,
    place_uid TEXT NOT NULL DEFAULT '',
    place TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS money_date ON money (date);
'''


def now():
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')


class Api:
    def __init__(self, path=DB_PATH):
        self.path = path
        with self._db() as db:
            db.executescript(SCHEMA)

    @contextlib.contextmanager
    def _db(self):
        # A connection per call: the bot calls from worker threads.
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def import_jsonl(self, path):
        """Add the entries of a Zaim export (*_zaim.jsonl) to the book.

        Idempotent: entries are keyed by Zaim's id and an id already in the
        book is skipped, so a dump can be imported any number of times and
        overlapping dumps merge. Cancelled entries keep their row (active=0),
        so importing never brings them back. Returns (added, skipped).
        """
        with open(path, encoding='utf-8') as f:
            rows = [json.loads(line) for line in f if line.strip()]
        with self._db() as db:
            before = db.total_changes
            db.executemany(
                'INSERT OR IGNORE INTO money (%s) VALUES (%s)'
                % (', '.join(COLUMNS), ', '.join('?' * len(COLUMNS))),
                [[r.get(c) for c in COLUMNS] for r in rows])
            added = db.total_changes - before
        return added, len(rows) - added

    def _input(self, mode, **fields):
        fields = {k: v for k, v in fields.items() if v is not None}
        # Zaim stored text fields trimmed; the bot's parser leaves a trailing
        # space on the place.
        for k in ('place', 'comment', 'name'):
            if k in fields:
                fields[k] = fields[k].strip()
        fields.setdefault('date', datetime.date.today().isoformat())
        fields['mode'] = mode
        fields['created'] = now()
        with self._db() as db:
            # New entries carry the currency of the last one, as Zaim uses the
            # account's default currency.
            last = db.execute('SELECT user_id, currency_code FROM money '
                              'ORDER BY id DESC LIMIT 1').fetchone()
            if last:
                fields.setdefault('user_id', last['user_id'])
                fields.setdefault('currency_code', last['currency_code'])
            cur = db.execute('INSERT INTO money (%s) VALUES (%s)'
                             % (', '.join(fields), ', '.join('?' * len(fields))),
                             list(fields.values()))
            count = db.execute('SELECT COUNT(*) FROM money').fetchone()[0]
        return {'stamps': None, 'banners': [],
                'money': {'id': cur.lastrowid, 'modified': fields['created']},
                'user': {'input_count': count},
                'requested': int(time.time())}

    def money(self, mapping=1, category_id=None, genre_id=None, mode=None,
              order=None, start_date=None, end_date=None, page=None,
              limit=None, group_by=None):
        # As the live API does, despite the doc (default 20, max 100): every
        # match is returned unless both limit and page are given.
        where, args = ['active = 1'], []
        for column, op, value in (('category_id', '=', category_id),
                                  ('genre_id', '=', genre_id),
                                  ('mode', '=', mode),
                                  ('date', '>=', start_date),
                                  ('date', '<=', end_date)):
            if value is not None:
                where.append('%s %s ?' % (column, op))
                args.append(value)
        sql = ('SELECT * FROM money WHERE %s ORDER BY %s'
               % (' AND '.join(where),
                  'id DESC' if order == 'id' else 'date DESC, id DESC'))
        if limit and page:
            sql += ' LIMIT %d OFFSET %d' % (int(limit),
                                            (int(page) - 1) * int(limit))
        with self._db() as db:
            rows = db.execute(sql, args).fetchall()
        return {'money': [dict(r) for r in rows], 'requested': int(time.time())}

    def payment(self, mapping=1, category_id=None, genre_id=None, amount=None,
                date=None, from_account_id=None, comment=None, name=None,
                place=None):
        return self._input('payment', category_id=category_id,
                           genre_id=genre_id, amount=amount, date=date,
                           from_account_id=from_account_id, comment=comment,
                           name=name, place=place)

    def income(self, mapping=1, category_id=None, amount=None, date=None,
               to_account_id=None, comment=None, place=None):
        return self._input('income', category_id=category_id, amount=amount,
                           date=date, to_account_id=to_account_id,
                           comment=comment, place=place)

    def delete(self, mode, money_id):
        with self._db() as db:
            cur = db.execute('UPDATE money SET active = 0 WHERE id = ? AND '
                             'mode = ? AND active = 1', (money_id, mode))
            count = db.execute('SELECT COUNT(*) FROM money').fetchone()[0]
        if not cur.rowcount:
            return {'error': True,
                    'message': 'no %s with id %s' % (mode, money_id)}
        return {'money': {'id': money_id, 'modified': now()},
                'user': {'input_count': count},
                'requested': int(time.time())}
