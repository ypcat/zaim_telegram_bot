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
        self.assertEqual(d.lines[-2].desc,
                         'tenso Hong Kong Limite Admiralty HK (TWD 373)')
        self.assertEqual(d.lines[-2].currency, 'JPY')

    def test_totals(self):
        self.assertEqual(self.doc.totals, [
            ('TWD total 2,175 = sum ✓', True),
            ('JPY total 1,856 = sum ✓', True)])

    def test_skipped_line_breaks_total(self):
        broken = [l for l in fixture('sinopac_card.txt').splitlines()
                  if '紅粟' not in l]
        doc = bills.sinopac_card('\n'.join(broken))
        self.assertFalse(doc.ok())
        self.assertIn(('TWD total 2,175 ≠ sum 723 ✗', False),
                      doc.totals)

# Each fixture parsed, as show() prints it before reconcile: every line,
# its kind, and the total checks. (fixture, parser, window, output)
PARSED = [
    ('sinopac_notice', 'sinopac_notice', (3, 3), [
        '⚠️ 永豐消費通知 10/03',
        '✗ 1 not booked, 11',
        '10/03 11 card 6603 18:37 TW',
    ]),
    ('cathay_card', 'cathay_card', (3, 3), [
        '⚠️ 國泰信用卡 2026-09 帳單',
        '✗ 4 not booked, 973',
        '09/12    7 國外交易手續費 -NETFLI',
        '09/12  480 NETFLIX.COM',
        '09/17    7 國外交易手續費 -Google',
        '09/17  479 Google YouTubePremium',
        '- 1 other',
        '09/09 -973 台北富邦銀行自動扣繳',
        'TWD total 973 = sum ✓',
    ]),
    ('cht_bill', 'cht_bill', (27, 7), [
        '⚠️ 中華電信 台北 2026-10',
        '✗ 1 not booked, 513',
        '10/27 513 台北 電信費 09/01-09/30',
        'total 513 = 499 + 14 ✓',
    ]),
    ('cht_bill_project', 'cht_bill', (25, 7), [
        '⚠️ 中華電信 台北 2026-09',
        '✗ 1 not booked, 926',
        '10/05 926 台北 電信費 08/11-09/10',
        'total 926 = 926 ✓',
    ]),
    ('cht_invoice', 'cht_invoice', (14, 3), [
        '⚠️ 中華電信發票 2026-10-06',
        '✗ 1 not booked, 926',
        '10/06 926 〔專案總額〕',
        'total 926 = 926 ✓',
    ]),
    ('gas_notice', 'gas_bill', (12, 7), [
        '⚠️ 瓦斯 2026-10 扣款通知',
        '✗ 1 not booked, 508',
        '10/14 508 瓦斯費',
        'total 508 = 200 + 308 ✓',
    ]),
    ('gas_receipt', 'gas_bill', (9, 7), [
        '⚠️ 瓦斯 2026-08 繳費憑證',
        '✗ 1 not booked, 455',
        '08/13 455 瓦斯費',
        'total 455 = 200 + 255 ✓',
    ]),
    ('water_notice', 'water_bill', (13, 7), [
        '⚠️ 水費 2026-09 通知單',
        '✗ 1 not booked, 644',
        '10/12 644 水費',
        'total 644 = 380 + 264 ✓',
    ]),
    ('water_receipt', 'water_bill', (7, 7), [
        '⚠️ 水費 2026-07 繳費憑證',
        '✗ 1 not booked, 566',
        '08/11 566 水費',
        'total 566 = 340 + 226 ✓',
    ]),
    ('youtube_invoice', 'google_invoice', (3, 3), [
        '⚠️ Google 發票 2026-08-17',
        '✗ 1 not booked, 479',
        '08/17 479 YouTube',
        'total 479 = 456 + 5% tax ✓',
    ]),
    ('anthropic_receipt', 'anthropic_receipt', (3, 3), [
        '✅ Anthropic receipt 2026-08-12',
        '- 1 other',
        '08/12 $20 Claude Pro',
        'USD total 20 = sum ✓',
    ]),
    ('fubon_bank', 'fubon_bank', (7, 3), [
        '⚠️ 富邦對帳單 2026-08',
        '✗ 6 not booked, 3,165',
        '08/05     999 電信費 <CODE>',
        '08/05      75 電信費 <NUMBER>',
        '08/11     566 市水水費 <NUMBER>',
        '08/17     455 瓦斯費 <NUMBER>',
        '08/25     530 電信費 <NUMBER>',
        '08/25     540 電信費 <NUMBER>',
        '- 11 other',
        '08/01  30,000 行動自轉 <CARD>',
        '08/03    -170 CD轉收 <NUMBER>',
        '08/04  -1,100 行動自轉 好市多',
        '08/06  36,332 信用卡轉 台北富邦信用卡款',
        '08/06    -500 發票獎金 11506',
        '08/11     953 委代扣 國泰世華信用卡',
        '08/11   5,000 無卡提款 <NUMBER>',
        '08/15   5,005 無卡提款 <NUMBER>',
        '08/18 -12,000 行動自轉 <NUMBER>',
        '08/21  10,000 無卡提款 <NUMBER>',
        '08/27 -60,000 匯入款 現代財富科技股份',
        'balances follow every line ✓',
        'TWD end balance 293,547 ✓',
    ]),
    ('sinopac_bank', 'sinopac_bank', (7, 3), [
        '✅ 永豐對帳單 2026-07',
        '- 5 other',
        '07/01     -422 大戶回饋 大戶回饋',
        '07/21     -360 利息存入',
        '07/27   11,669 永豐卡費 <CARD>',
        '07/21     -¥81 利息存入',
        '07/27 ¥209,619 永豐卡費 <CARD>',
        'balances follow every line ✓ (first line of each account unchecked)',
    ]),
]

class Parsers(unittest.TestCase):
    def test_parsed(self):
        for name, parser, window, expected in PARSED:
            with self.subTest(name):
                doc = getattr(bills, parser)(fixture(name + '.txt'))
                self.assertEqual(doc.window, window)
                self.assertEqual(bills.show([doc], {}).splitlines(), expected)

class Reconcile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, 'zaim.db')
        book = zaim_db.Api(self.path)
        for date, amount, place in [
                ('2026-09-13', 46, 'P'), ('2026-09-17', 10, 'P'),
                ('2026-09-18', 99, 'P'), ('2026-09-28', 1452, 'P'),
                ('2026-10-03', 11, '')]:
            book.payment(category_id=101, genre_id=10101, amount=amount,
                         date=date, place=place)
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

    def test_show(self):
        doc = bills.sinopac_card(fixture('sinopac_card.txt'))
        bills.reconcile(self.db, doc)
        self.assertEqual(bills.show([doc], {10101: '食物'}).splitlines(), [
            '⚠️ 永豐信用卡 2026-10 帳單',
            '✗ 4 not booked, 557',
            '09/15    501 A- IKEA宜家家居-內湖店',
            '09/16     38 Go Share 服務費',
            '09/23      5 微笑單車股份有限公司',
            '09/24     13 Go Share 服務費',
            '✓ 5 booked, 1,618',
            '09/13     46 Go Share 服務費 ← 食物 P',
            '09/14     10 微笑單車股份有限公司 ← 09/17 食物 P',
            '09/18     99 A- 好農市 ← 食物 P',
            '09/25  1,452 紅粟 ← 09/28 食物 P',
            '10/03     11 Go Share 服務費 ← 食物',
            '- 6 other',
            '09/29 -8,046 永豐自扣已入帳,謝謝!',
            '10/01      0 大戶消費回饋入帳戶_任務 178 元',
            '10/01      0 大戶消費回饋入帳戶_國內 71 元',
            '10/01      0 大戶消費回饋入帳戶_通路 15 元',
            '09/18 ¥1,829 tenso Hong Kong Limite Admiralty HK (TWD 373)',
            '09/18    ¥27 tenso Hong Kong Limite A 國外交易服務費',
            'TWD total 2,175 = sum ✓',
            'JPY total 1,856 = sum ✓',
        ])

if __name__ == '__main__':
    unittest.main()
