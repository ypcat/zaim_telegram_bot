"""Parser and reconcile tests on masked fixtures.

    .venv/bin/python -m unittest discover tests
"""

import datetime
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import bills
import zaim_db

FIXTURES = os.path.join(os.path.dirname(__file__), 'fixtures')

def fixture(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return f.read()

class SinopacCard(unittest.TestCase):
    def setUp(self):
        self.doc = bills.sinopac_card(fixture('sinopac_card.txt'))

    def test_lines(self):
        d = self.doc
        self.assertEqual(d.title, '永豐信用卡 2026-10 帳單')
        spend = [(l.date.isoformat(), l.amount) for l in d.lines
                 if l.kind == 'spend']
        self.assertEqual(spend, [
            ('2026-09-13', 46), ('2026-09-14', 10), ('2026-09-15', 501),
            ('2026-09-16', 38), ('2026-09-18', 99), ('2026-09-23', 5),
            ('2026-09-24', 13), ('2026-09-25', 1452), ('2026-10-03', 11)])
        self.assertEqual(
            [l.amount for l in d.lines if l.kind == 'not_spending'],
            [-8046, 0, 0, 0])
        self.assertEqual([l.amount for l in d.lines if l.kind == 'foreign'],
                         [1829, 27])
        self.assertIn('(TWD 373)', d.lines[-2].desc)

    def test_totals(self):
        self.assertEqual(self.doc.totals, [
            ('TWD total 2,175 = sum of lines ✓', True),
            ('JPY total 1,856 = sum of lines ✓', True)])

    def test_skipped_line_breaks_total(self):
        broken = [l for l in fixture('sinopac_card.txt').splitlines()
                  if '紅粟' not in l]
        doc = bills.sinopac_card('\n'.join(broken))
        self.assertFalse(doc.ok())
        self.assertIn(('TWD total 2,175 ≠ sum of lines 723 ✗', False),
                      doc.totals)

class Reconcile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, 'zaim.db')
        book = zaim_db.Api(self.path)
        for date, amount in [('2026-09-13', 46), ('2026-09-17', 10),
                             ('2026-09-18', 99), ('2026-09-28', 1452),
                             ('2026-10-03', 11)]:
            book.payment(category_id=101, amount=amount, date=date)
        cancelled = book.payment(category_id=101, amount=13, date='2026-09-24')
        book.delete('payment', cancelled['money']['id'])
        self.db = sqlite3.connect(self.path)

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def line(self, date, amount):
        return bills.Line(datetime.date.fromisoformat(date), '', amount,
                          'spend')

    def test_window_and_one_to_one(self):
        doc = bills.Doc('t', [
            self.line('2026-09-13', 46),    # same day
            self.line('2026-09-14', 10),    # book +3 days
            self.line('2026-09-18', 99),    # one row ...
            self.line('2026-09-19', 99),    # ... cannot match twice
            self.line('2026-09-24', 1452),  # book +4 days: outside
            self.line('2026-09-24', 13),    # cancelled in the book
            self.line('2026-10-03', 12),    # other amount
        ], (3, 3))
        bills.reconcile(self.db, doc)
        self.assertEqual([l.match is not None for l in doc.lines],
                         [True, True, True, False, False, False, False])
        self.assertFalse(doc.ok())

if __name__ == '__main__':
    unittest.main()
