#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["pdfplumber"]
# ///
"""Check bill mails in the Gmail inbox against the account book, zaim.db.

    ./bills.py auth    # once: authorize Gmail, writes gmail_token.json
    ./bills.py         # every bill, line by line, with the book row matched
    ./bills.py 2       # bill 2 only

The queue is Gmail itself: in:inbox is:unread. Reading a message through the
API does not mark it read, and this never changes mail (gmail.readonly).
Mails no parser accepts are left out. Archive in Gmail when a bill is ✅.
"""

import base64
import dataclasses
import datetime
import html
import http.server
import io
import json
import logging
import os
import re
import sqlite3
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

import pdfplumber
from pdfminer.pdfdocument import PDFPasswordIncorrect
from pdfplumber.utils.exceptions import PdfminerException

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, 'config.json')
CATS = os.path.join(HERE, 'cats.json')
TOKEN = os.path.join(HERE, 'gmail_token.json')
DB = os.path.join(HERE, 'zaim.db')

AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_URL = 'https://oauth2.googleapis.com/token'
GMAIL = 'https://gmail.googleapis.com/gmail/v1/users/me'
SCOPE = 'https://www.googleapis.com/auth/gmail.readonly'
# A "Web application" client accepts only exactly-registered redirect URIs.
PORT = 8130
QUEUE = 'in:inbox is:unread'

# pdfminer warns about font metrics on most bank PDFs.
logging.getLogger('pdfminer').setLevel(logging.ERROR)

class Error(Exception):
    """A failure to show the user; the bot catches it too."""

def config():
    with open(CONFIG) as f:
        return json.load(f)

def post_form(url, fields):
    data = urllib.parse.urlencode(fields).encode()
    try:
        with urllib.request.urlopen(url, data) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # Google's error body names the reason (invalid_grant, ...); no secrets.
        raise Error('Google token endpoint: %s %s' % (e.code, e.read().decode()))

# ── Gmail ──────────────────────────────────────────────────────────────────

def auth():
    g = config()['google']
    redirect = 'http://127.0.0.1:%d' % PORT
    query = urllib.parse.urlencode({
        'client_id': g['client_id'], 'redirect_uri': redirect,
        'response_type': 'code', 'scope': SCOPE,
        'access_type': 'offline', 'prompt': 'consent'})
    print('Open this URL in your browser:\n\n  %s?%s\n' % (AUTH_URL, query))

    params = {}
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.urlparse(self.path).query
            params.update(urllib.parse.parse_qsl(q))
            self.send_response(200)
            self.send_header('content-type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(b'<h3>Done. You can close this tab.</h3>')
        def log_message(self, *args):
            pass  # the request line holds the code
    with http.server.HTTPServer(('127.0.0.1', PORT), Handler) as server:
        while 'code' not in params and 'error' not in params:
            server.handle_request()
    if 'code' not in params:
        raise Error('Authorization failed: %s' % params['error'])

    tok = post_form(TOKEN_URL, {
        'code': params['code'], 'client_id': g['client_id'],
        'client_secret': g['client_secret'], 'redirect_uri': redirect,
        'grant_type': 'authorization_code'})
    if 'refresh_token' not in tok:
        raise Error('Google sent no refresh token.')
    with open(os.open(TOKEN, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600),
              'w') as f:
        json.dump({'refresh_token': tok['refresh_token'],
                   'scope': tok.get('scope', SCOPE)}, f)
    print('Saved %s (scope: %s).' % (TOKEN, tok.get('scope', SCOPE)))

class Gmail:
    def __init__(self):
        g = config()['google']
        try:
            with open(TOKEN) as f:
                refresh = json.load(f)['refresh_token']
        except FileNotFoundError:
            raise Error('No %s. Run: ./bills.py auth' % TOKEN)
        self.token = post_form(TOKEN_URL, {
            'refresh_token': refresh, 'client_id': g['client_id'],
            'client_secret': g['client_secret'],
            'grant_type': 'refresh_token'})['access_token']

    def get(self, path, **params):
        url = GMAIL + path + ('?' + urllib.parse.urlencode(params, doseq=True)
                              if params else '')
        req = urllib.request.Request(
            url, headers={'Authorization': 'Bearer ' + self.token})
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            raise Error('Gmail API: %s %s' % (e.code, e.reason))

    def queue(self):
        """Ids of the messages in the queue, newest first."""
        ids, page = [], None
        while True:
            params = {'q': QUEUE, 'maxResults': 100}
            if page:
                params['pageToken'] = page
            body = self.get('/messages', **params)
            ids += [m['id'] for m in body.get('messages', [])]
            page = body.get('nextPageToken')
            if not page:
                return ids

    def message(self, msg_id):
        return self.get('/messages/' + msg_id, format='full')

    def attachment(self, msg_id, att_id):
        body = self.get('/messages/%s/attachments/%s' % (msg_id, att_id))
        return base64.urlsafe_b64decode(body['data'] + '==')

def header(msg, name):
    for h in msg['payload'].get('headers', []):
        if h['name'].lower() == name.lower():
            return h['value']
    return ''

def parts(part):
    """All MIME parts of a message, depth first."""
    yield part
    for p in part.get('parts', []):
        yield from parts(p)

def files(msg):
    """(filename, mimeType, attachmentId) of each attachment."""
    return [(p['filename'], p['mimeType'], p['body'].get('attachmentId'))
            for p in parts(msg['payload']) if p.get('filename')]

def body_text(msg):
    """The mail body as plain text, HTML tags removed."""
    out = []
    for p in parts(msg['payload']):
        if (p['mimeType'] in ('text/plain', 'text/html') and not p.get('filename')
                and p['body'].get('data')):
            t = base64.urlsafe_b64decode(p['body']['data'] + '==').decode(
                'utf-8', 'replace')
            out.append(html_text(t))
    return '\n'.join(out)

def html_text(t):
    t = re.sub(r'(?is)<(style|script).*?</\1>', '', t)
    return html.unescape(re.sub(r'<[^>]+>', ' ', t))

def fold(text):
    """CJK compatibility ideographs (some PDFs print 年 as U+F98E) to the
    usual ones. Not full NFKC: parsers rely on full-width ：and Ｃ."""
    return re.sub(r'[\uf900-\ufaff]',
                  lambda m: unicodedata.normalize('NFKC', m[0]), text)

def html_file(data):
    """An attached HTML file as plain text, in the charset it declares."""
    m = re.search(rb'charset=["\']?([\w-]+)', data[:4096], re.I)
    charset = m[1].decode().lower() if m else 'utf-8'
    # Taiwan's "big5" is in practice Microsoft's cp950 superset.
    charset = 'cp950' if charset == 'big5' else charset
    return fold(html_text(data.decode(charset, 'replace')))

def pdf_text(data):
    for pw in [''] + config().get('bill_passwords', []):
        try:
            with pdfplumber.open(io.BytesIO(data), password=pw) as pdf:
                # dedupe: some PDFs draw bold text as overlapping copies.
                return fold('\n'.join(p.dedupe_chars().extract_text(
                    layout=True) or '' for p in pdf.pages))
        except PdfminerException as e:
            if not isinstance(e.args[0], PDFPasswordIncorrect):
                raise Error('cannot read the PDF: %r' % e.args[0])
    raise Error('no password in bill_passwords opens the PDF')

# ── Documents ──────────────────────────────────────────────────────────────

@dataclasses.dataclass
class Line:
    date: datetime.date
    desc: str
    amount: float       # in the line's currency; whole numbers for TWD
    kind: str           # 'spend', 'not_spending' or 'foreign'
    currency: str = 'TWD'
    match: tuple = None  # the book row: (id, date, genre_id, place)

@dataclasses.dataclass
class Doc:
    title: str
    lines: list
    window: tuple       # days before and after a line's date to find it booked
    totals: list = dataclasses.field(default_factory=list)  # (text, ok)

    def not_booked(self):
        return [l for l in self.lines if l.kind == 'spend' and not l.match]

    def ok(self):
        return not self.not_booked() and all(ok for _, ok in self.totals)

def number(s):
    return float(s.replace(',', ''))

def money(x):
    return '{:,.2f}'.format(x) if x != int(x) else '{:,}'.format(int(x))

def check_total(doc, label, start, lines, end):
    """Statement total check: start + sum of lines must equal end."""
    got = round(start + sum(l.amount for l in lines), 2)
    if got == end:
        doc.totals.append(('%s total %s = sum ✓' % (label, money(end)), True))
    else:
        doc.totals.append(('%s total %s ≠ sum %s ✗'
                           % (label, money(end), money(got)), False))

def sinopac_card(text):
    """永豐銀行 credit card statement (信用卡電子帳單)."""
    m = re.search(r'結帳日(\d{4})/(\d\d)/(\d\d)', text)
    if not m:
        raise Error('永豐 card statement: no 結帳日')
    closing = datetime.date(*map(int, m.groups()))
    doc = Doc('永豐信用卡 %d-%02d 帳單' % (closing.year, closing.month), [],
              (3, 3))
    # 幣別 上期應繳總金額 已繳款金額 本期新增款項 循環利息 違約金 本期應繳總金額 最低應繳
    summary = {c: (number(a), number(b)) for c, a, b in re.findall(
        r'(?m)^\s*(臺幣|日圓)\s+([\d,.]+)\s+[\d,.]+\s+[\d,.]+\s+[\d,.]+\s+'
        r'[\d,.]+\s+([\d,.]+)\s+[\d,.]+\s*$', text)}
    row = re.compile(r'(\d\d)/(\d\d)\s+\d\d/\d\d\s+(?:\d{4}\s+)?(.+?)\s+'
                     r'(-?[\d,]+(?:\.\d\d)?)(?:\s+\d\d/\d\d\s+\S+\s+'
                     r'([A-Z]{3})\s+([\d,.]+))?')
    section, lines = None, {'臺幣': [], '日圓': []}
    for raw in text.splitlines():
        s = raw.strip()
        if s in lines:
            section = s
            continue
        m = row.fullmatch(s)
        if not (section and m):
            continue
        month, day, desc, amount, cur, orig = m.groups()
        year = closing.year - (int(month) > closing.month)
        amount = number(amount)
        if section == '日圓':
            kind, currency = 'foreign', 'JPY'
            if cur:
                desc += ' (%s %s)' % (cur, money(number(orig)))
        else:
            kind = 'spend' if amount > 0 else 'not_spending'
            currency = 'TWD'
        line = Line(datetime.date(year, int(month), int(day)), desc, amount,
                    kind, currency)
        lines[section].append(line)
        doc.lines.append(line)
    for cur, label in (('臺幣', 'TWD'), ('日圓', 'JPY')):
        if cur in summary:
            check_total(doc, label, summary[cur][0], lines[cur],
                        summary[cur][1])
        elif lines[cur]:
            doc.totals.append(('%s statement total not found ✗' % label,
                               False))
    if not doc.lines:
        doc.totals.append(('no lines found ✗', False))
    return doc

def roc(y, m, d):
    """A date in the ROC calendar (year 115 = 2026)."""
    return datetime.date(int(y) + 1911, int(m), int(d))

def spaced(label):
    """Regex for a label that a PDF may print with spaces between letters."""
    return r'\s*'.join(map(re.escape, label))

def find(pattern, text, what):
    m = re.search(pattern, text)
    if not m:
        raise Error('cannot find %s' % what)
    return m

def check_parts(doc, parts, total):
    """Total check for a one-line bill: its parts must add up to it."""
    got = round(sum(parts), 2)
    sign = '=' if got == total else '≠'
    doc.totals.append(('total %s %s %s %s' % (
        money(total), sign, ' + '.join(money(p) for p in parts),
        '✓' if got == total else '✗'), got == total))

def sinopac_notice(text):
    """永豐 credit card 消費通知: card authorizations, no merchant names."""
    start = roc(*find(r'期間：(\d+)/(\d+)/(\d+)', text, '期間').groups())
    doc = Doc('永豐消費通知 %s' % start.strftime('%m/%d'), [], (3, 3))
    for card, month, day, hh, mm, area, amount in re.findall(
            r'[正附]卡\s+(\d{4})\s+(\d+)\s*/\s*(\d+)\s+(\d+)：(\d+)\s+(\S+)\s+'
            r'NT\$\s*(-?[\d,]+)', text):
        year = start.year - (int(month) > start.month)
        amount = number(amount)
        doc.lines.append(Line(datetime.date(year, int(month), int(day)),
                              'card %s %s:%s %s' % (card, hh, mm, area), amount,
                              'spend' if amount > 0 else 'not_spending'))
    if not doc.lines:
        doc.totals.append(('no lines found ✗', False))
    return doc

def cathay_card(text):
    """國泰世華 credit card statement."""
    y, mo = find(r'信用卡帳單\s+(\d+)年(\d+)月', text, '帳單年月').groups()
    y, mo = int(y) + 1911, int(mo)
    doc = Doc('國泰信用卡 %d-%02d 帳單' % (y, mo), [], (3, 3))
    # 消費日 入帳起息日 交易說明 新臺幣金額 [卡號後四碼] [行動卡號後四碼]
    # [國家] [幣別 外幣金額 折算日]
    row = re.compile(r'(\d\d)/(\d\d)\s+\d\d/\d\d\s+(.+?)\s+(-?[\d,]+)'
                     r'(?:\s+\d{4}){0,2}(?:\s+[A-Z]{2})?'
                     r'(?:\s+([A-Z]{3})\s+([\d,.]+)\s+\d\d/\d\d)?')
    for raw in text.splitlines():
        m = row.fullmatch(raw.strip())
        if not m:
            continue
        month, day, desc, amount, cur, orig = m.groups()
        if cur and cur != 'TWD':
            desc += ' (%s %s)' % (cur, orig)
        amount = number(amount)
        doc.lines.append(Line(
            datetime.date(y - (int(month) > mo), int(month), int(day)), desc,
            amount, 'spend' if amount > 0 else 'not_spending'))
    start = number(find(r'上期帳單總額\s+(-?[\d,]+)', text, '上期帳單總額')[1])
    end = number(find(r'本期應繳總額\s+(-?[\d,]+)', text, '本期應繳總額')[1])
    check_total(doc, 'TWD', start, doc.lines, end)
    return doc

def cht_bill(text):
    """中華電信 電信費用通知單: one bill per phone number, paid by autopay."""
    office, y, mo = find(r'(\S+)營運處(\d+)年(\d+)月繳費通知', text,
                         '繳費通知').groups()
    m = find(r'\$([\d,]+)\s+(\d+)/(\d+)/(\d+)', text, '應繳總金額')
    total, due = number(m[1]), roc(*m.groups()[1:])
    m = find(r'計費期間：(\d+)/(\d+)/(\d+)至(\d+)/(\d+)/(\d+)', text, '計費期間')
    first, last = roc(*m.groups()[:3]), roc(*m.groups()[3:])
    doc = Doc('中華電信 %s %d-%02d' % (office, int(y) + 1911, int(mo)), [],
              ((due - last).days, 7))
    doc.lines.append(Line(due, '%s 電信費 %s-%s' % (
        office, first.strftime('%m/%d'), last.strftime('%m/%d')), total,
        'spend'))
    check_parts(doc, [number(n) for n in re.findall(r'小計\s+(-?[\d,]+)', text)],
                total)
    return doc

def cht_invoice(text):
    """中華電信 電子發票 (.htm), issued after the bill is paid."""
    t = ' '.join(text.split())
    date = datetime.date.fromisoformat(
        find(r'(\d{4}-\d\d-\d\d)', t, 'invoice date')[1])
    total = number(find(r'總計： ([\d,]+)', t, '總計')[1])
    items = find(r'品名 數量 單價 金額 (.*?) 銷售額合計', t, 'items')[1]
    names = re.findall(r'(.+?) \d+ [\d,]+ (-?[\d,]+)(?: |$)', items)
    doc = Doc('中華電信發票 %s' % date, [], (14, 3))
    doc.lines.append(Line(date, ' '.join(n for n, _ in names), total, 'spend'))
    check_parts(doc, [number(a) for _, a in names], total)
    return doc

def gas_bill(text):
    """大台北瓦斯 扣款通知 (before the autopay) or 繳費憑證 (after it)."""
    ym = find(r'收費年月\s+(\d{3})(\d\d)', text, '收費年月')
    paid = roc(*find(r'本期繳費日\s+(\d+)/(\d+)/(\d+)', text, '繳費日').groups())
    billed = roc(*find(r'本期計費日\s+(\d+)/(\d+)/(\d+)', text, '計費日').groups())
    total = number(find(r'應繳總金額\(元\)\s+([\d,]+)', text, '應繳總金額')[1])
    kind = '扣款通知' if '委託轉帳代繳電子通知單' in text else '繳費憑證'
    doc = Doc('瓦斯 %d-%s %s' % (int(ym[1]) + 1911, ym[2], kind), [],
              ((paid - billed).days, 7))
    doc.lines.append(Line(paid, '瓦斯費', total, 'spend'))
    parts = [number(find(spaced(label) + r'\s+(-?[\d,]+)', text, label)[1])
             for label in ('基本費', '從量費', '調價差額', '追(退)金額',
                           '前期氣費金額', '違約金金額', '工料費金額')]
    check_parts(doc, [p for p in parts if p], total)
    return doc

def water_bill(text):
    """臺北自來水 水費通知單 (before the autopay) or 繳費憑證 (after it)."""
    m = find(r'(\d+)年(\d+)月\s+(\d+)/(\d+)/(\d+)\s+\$([\d,]+)', text, '水費')
    y, mo, total = int(m[1]) + 1911, int(m[2]), number(m[6])
    billed = roc(*m.groups()[2:5])
    debit = re.search(r'預計將自「\s*(\d+)\s*年\s*(\d+)\s*月\s*(\d+)\s*日」', text)
    if debit:   # 通知單: 收費日, then the autopay on the debit date
        date, kind = roc(*debit.groups()), '通知單'
        window = ((date - billed).days, 7)
    else:       # 繳費憑證: the payment date
        date, kind, window = billed, '繳費憑證', (7, 7)
    doc = Doc('水費 %d-%02d %s' % (y, mo, kind), [], window)
    doc.lines.append(Line(date, '水費', total, 'spend'))
    parts = [number(n) for n in re.findall(
        r'(?:水費項目小計|代徵費款小計|舊欠水費)：\s*(-?[\d.]+)', text)]
    fine = re.search(r'違約金Liquidated Damages:\s*([\d.]+)', text)
    c, b = find(r'Ｃ退還Ｂ追收：\s*([\d.]*)\s*/\s*([\d.]*)', text, 'Ｃ退還Ｂ追收'
                ).groups()
    parts += [float(fine[1]) if fine else 0, -float(c or 0), float(b or 0)]
    total_due = number(find(r'Total Amount Due：\s*([\d.]+)', text, '應繳總金額')[1])
    check_parts(doc, [p for p in parts if p], total_due)
    return doc

def google_invoice(text):
    """Google 統一發票 (YouTube): items before 5% tax, total after."""
    date = datetime.date.fromisoformat(
        find(r'(\d{4}-\d\d-\d\d) \d\d:\d\d:\d\d', text, 'invoice date')[1])
    total = number(find(r'總計\s+([\d,]+)', text, '總計')[1])
    items = re.findall(r'(?m)^\s*(\S.*?)\s+(\d+)\s+([\d,]+)\s+([\d,]+)\s*$', text)
    doc = Doc('Google 發票 %s' % date, [], (3, 3))
    doc.lines.append(Line(date, ' '.join(i[0] for i in items), total, 'spend'))
    net = sum(number(i[3]) for i in items)
    ok = round(net * 1.05) == total
    doc.totals.append(('total %s %s %s + 5%% tax %s' % (
        money(total), '=' if ok else '≠', money(net), '✓' if ok else '✗'), ok))
    return doc

def anthropic_receipt(text):
    """Anthropic receipt, in USD: shown, not matched (the card statement
    carries the TWD amount)."""
    date = datetime.datetime.strptime(
        find(r'Date paid\s+(\w+ \d+, \d{4})', text, 'Date paid')[1],
        '%B %d, %Y').date()
    total = number(find(r'Amount paid\s+\$([\d,.]+)', text, 'Amount paid')[1])
    doc = Doc('Anthropic receipt %s' % date, [], (3, 3))
    items = re.findall(r'(?m)^\s*(\S.*?)\s+\d+\s+\$[\d,.]+\s+\$([\d,.]+)\s*$',
                       text)
    for name, amount in items:
        doc.lines.append(Line(date, name, number(amount), 'foreign', 'USD'))
    check_total(doc, 'USD', 0, doc.lines, total)
    return doc

# Outgoing bank lines that are not spending: card payments (the card
# statement has the purchases), own transfers, cash withdrawals.
NOT_SPENDING = re.compile(r'信用卡|卡費|自轉|提款')

# A bank debits days after the bill it pays, and after the book's entry.
BANK_WINDOW = (7, 3)

def bank_note(note):
    """A bank line's remark, without account, card and phone numbers."""
    return ' '.join(w for w in (note or '').split()
                    if len(re.findall(r'\d', w)) < 6)

def bank_line(doc, accounts, date, desc, amount, balance, currency):
    """Add one bank line. Its sign comes from the balance: the line belongs
    to the account whose last balance -amount (out) or +amount (in) gives
    the new one. That also proves the amount was read right."""
    for i, last in enumerate(accounts):
        for sign in (1, -1):
            if last is not None and round(last - sign * amount, 2) == balance:
                accounts[i] = balance
                kind = ('foreign' if currency != 'TWD' else 'not_spending'
                        if sign < 0 or NOT_SPENDING.search(desc) else 'spend')
                doc.lines.append(Line(date, desc, sign * amount, kind,
                                      currency))
                return True
    return False

def fubon_bank(text):
    """台北富邦銀行 對帳單: deposit accounts, opened by 承轉結餘 lines."""
    first = find(r'對帳單期間：(\d{4})/(\d\d)/\d\d', text, '對帳單期間')
    doc = Doc('富邦對帳單 %s-%s' % first.groups(), [], BANK_WINDOW)
    # 台幣活存: all TWD. 外幣活存: each account's first line names its currency.
    accounts, foreign, c, broken = {'TWD': []}, False, 'TWD', 0
    for raw in text.splitlines():
        s = raw.strip()
        if s == '外幣活存':
            foreign = True
        cur = re.search(r'(?<![A-Z])(TWD|JPY|USD|EUR)(?![A-Z])', s)
        if foreign and cur:
            c = cur[1]
        m = re.search(r'承轉結餘\s+([\d,]+\.\d\d)$', s)
        if m:
            accounts.setdefault(c, []).append(number(m[1]))
            continue
        m = re.search(r'(\d{4})/(\d\d)/(\d\d)\s+(\S+)\s+(.*?)\s*([\d,]+\.\d\d)$',
                      s)
        if not m or '承轉' in s:
            continue
        y, mo, d, what, middle, balance = m.groups()
        amounts = re.findall(r'(?<!\S)[\d,]+\.\d\d(?!\S)', middle)
        note = ' '.join(re.sub(r'(?<!\S)[\d,]+\.\d\d(?!\S)', '', middle).split())
        if len(amounts) != 1 or not bank_line(
                doc, accounts.setdefault(c, []),
                datetime.date(int(y), int(mo), int(d)),
                ' '.join(filter(None, [what, bank_note(note)])),
                number(amounts[0]),
                number(balance), c):
            broken += 1
    doc.totals.append(('balances follow every line ✓' if not broken else
                       '%d lines break the balances ✗' % broken, not broken))
    end = number(find(r'台幣存款總計\s+([\d,]+\.\d\d)', text, '台幣存款總計')[1])
    ok = round(sum(accounts['TWD']), 2) == end
    doc.totals.append(('TWD end balance %s ✓' % money(end) if ok else
                       'TWD end balance %s ≠ %s ✗' % (
                           money(end), money(sum(accounts['TWD']))), ok))
    return doc

def sinopac_bank(text):
    """永豐銀行 綜合對帳單: one section per account. There is no opening
    balance, so the first line of each account takes its sign from its 摘要
    and its amount is not checked; every later line is, by the balance."""
    first = find(r'對帳單期間：(\d{4})/(\d\d)/\d\d', text, '對帳單期間')
    doc = Doc('永豐對帳單 %s-%s' % first.groups(), [], BANK_WINDOW)
    names = {'新臺幣': 'TWD', '日圓': 'JPY', '美元': 'USD'}
    ends = {names[n]: number(b) for n, b in re.findall(
        r'(新臺幣|日圓|美元)\([A-Z]{3}\)\s+([\d,.]+)', text)}
    broken, currency, last = 0, None, {}
    for raw in text.splitlines():
        s = raw.strip()
        m = re.match(r'帳號:\S*\((\S+)\)$', s)
        if m:
            currency = names.get(m[1], m[1])
            continue
        m = re.match(r'(\d{4})/(\d\d)/(\d\d)\s+(\S+)\s+([\d,.]+)\s+([\d,.]+)'
                     r'(?:\s+(.*))?$', s)
        if not (m and currency):
            continue
        y, mo, d, what, amount, balance, note = m.groups()
        amount, balance = number(amount), number(balance)
        if currency not in last:
            incoming = re.search(r'存入|回饋|利息|匯入', what)
            last[currency] = balance - amount if incoming else balance + amount
        account = [last[currency]]
        if not bank_line(doc, account, datetime.date(int(y), int(mo), int(d)),
                         ' '.join(filter(None, [what, bank_note(note)])), amount,
                         balance,
                         currency):
            broken += 1
        last[currency] = balance
    for currency, balance in last.items():
        if balance != ends.get(currency):
            broken += 1
    doc.totals.append(('balances follow every line ✓ (first line of each '
                       'account unchecked)' if not broken else
                       '%d lines break the balances ✗' % broken, not broken))
    return doc

@dataclasses.dataclass
class Parser:
    """A mail is accepted only when sender, subject and body match; then
    each attachment whose filename and content match is parsed."""
    sender: str         # regex on From
    subject: str        # regex on Subject
    body: str           # text in the mail body
    filename: str       # regex on the attachment filename
    content: str        # text in the attachment
    parse: object       # text -> Doc

PARSERS = [
    Parser(r'<ebillservice@newebill\.banksinopac\.com\.tw>$',
           r'^永豐銀行信用卡\d{4}年\d{1,2}月份電子帳單通知$',
           '永豐銀行信用卡電子帳單',
           r'^永豐銀行信用卡帳單\.pdf$', '信用卡電子帳單', sinopac_card),
    Parser(r'<SpendService@sinopac\.com>$',
           r'^永豐銀行信用卡 \d+月\d+日 消費通知$', '消費彙整通知',
           r'^Sinopac_Service\.pdf$', '消費授權紀錄', sinopac_notice),
    Parser(r'@\S*cathaybk\.com\.tw>$', r'^國泰世華銀行信用卡\d{4}年\d+月電子帳單$',
           '國泰世華信用卡', r'^信用卡電子帳單消費明細_\d+\.pdf$',
           '您本月消費明細如下', cathay_card),
    Parser(r'<cht_ebpp@cht\.com\.tw>$', r'^中華電信\d+年\d+月電信費用通知單',
           '中華電信電子帳單', r'_notification\.pdf$', '繳費通知', cht_bill),
    Parser(r'<invoice@cht\.com\.tw>$', r'^中華電信\d+年\d+月電子發票通知函',
           '中華電信電子發票', r'\.htm$', '電子發票 開立通知', cht_invoice),
    Parser(r'<ebill@taipeigas\.com\.tw>$',
           r'^大台北區瓦斯公司\d+年\d+月份電子(扣款通知|繳費憑證)$',
           '本郵件為系統發送郵件', r'\.pdf$', '大台北區瓦斯股份有限公司',
           gas_bill),
    Parser(r'<ebill@water\.gov\.taipei>$',
           r'^臺北自來水事業處\d+年\d+月水費電子(通知單|繳費憑證)',
           '臺北自來水事業處', r'\.pdf$', '臺北自來水事業處', water_bill),
    Parser(r'<payments-noreply@google\.com>$',
           r'隨信附上您的電子應付憑據 \(統一發票\)$', '統一發票', r'\.pdf$',
           '發票開立通知', google_invoice),
    Parser(r'<invoice\+statements@mail\.anthropic\.com>$',
           r'^Your receipt from Anthropic, PBC', 'Receipt from Anthropic',
           r'^Receipt-[\d-]+\.pdf$', 'Amount paid', anthropic_receipt),
    Parser(r'@\S*taipeifubon\.com\.tw>$', r'^台北富邦銀行\d{4}年\d+月 銀行對帳單$',
           '台北富邦銀行綜合電子對帳單', r'^銀行對帳單\.PDF$', '承轉結餘',
           fubon_bank),
    Parser(r'<ebillservice@newebill\.banksinopac\.com\.tw>$',
           r'永豐銀行\d{4}年\d+月份電子綜合對帳單$', '電子綜合對帳單',
           r'電子綜合對帳單\.pdf$', '綜合對帳單', sinopac_bank),
]

def read_mail(gmail, msg_id):
    """The documents of one mail; [] when no parser accepts it."""
    msg = gmail.message(msg_id)
    sender, subject = header(msg, 'From'), header(msg, 'Subject')
    parsers = [p for p in PARSERS if re.search(p.sender, sender)
               and re.search(p.subject, subject)]
    if not parsers:
        return []
    body = body_text(msg)
    parsers = [p for p in parsers if p.body in body]
    docs = []
    for name, _, att in files(msg):
        for p in parsers:
            if not re.search(p.filename, name):
                continue
            data = gmail.attachment(msg_id, att)
            text = (pdf_text(data) if name.lower().endswith('.pdf')
                    else html_file(data))
            if p.content in text:
                docs.append(p.parse(text))
    return docs

# ── Reconcile ──────────────────────────────────────────────────────────────

def reconcile(db, doc):
    """Mark each spend line booked if a payment of the same amount is in the
    book inside the window. One book row per line inside a document."""
    used = set()
    before, after = (datetime.timedelta(days=d) for d in doc.window)
    for line in sorted(doc.lines, key=lambda l: l.date):
        if line.kind != 'spend':
            continue
        rows = db.execute(
            "SELECT id, date, genre_id, place FROM money"
            " WHERE mode = 'payment' AND active = 1"
            ' AND amount = ? AND date BETWEEN ? AND ?',
            (int(line.amount), (line.date - before).isoformat(),
             (line.date + after).isoformat())).fetchall()
        rows = [r for r in rows if r[0] not in used]
        if rows:
            best = min(rows, key=lambda r: abs(
                datetime.date.fromisoformat(r[1]) - line.date))
            used.add(best[0])
            line.match = best

def bills():
    """The bills in the queue, reconciled: [(message id, [Doc])]."""
    gmail = Gmail()
    out = [(m, docs) for m in gmail.queue() if (docs := read_mail(gmail, m))]
    db = sqlite3.connect('file:%s?mode=ro' % DB, uri=True)
    try:
        for _, docs in out:
            for doc in docs:
                reconcile(db, doc)
    finally:
        db.close()
    return out

# ── Output ─────────────────────────────────────────────────────────────────

def genres():
    """genre_id -> canonical category name, from cats.json."""
    with open(CATS) as f:
        cats = json.load(f)
    return {int(g): names[0] for kind in cats.values()
            for g, names in kind.items()}

SYMBOL = {'TWD': '', 'JPY': '¥', 'USD': '$'}

def show(docs, names):
    """A bill in three groups, each with its count and sum: not booked;
    booked, with the book row (its date only when it differs, category,
    place); other (not spending, foreign currency). Short lines for a phone;
    the amount column lines up in a monospace font."""
    out = []
    for d in docs:
        def amount(l):
            return ('-' if l.amount < 0 else '') + SYMBOL.get(
                l.currency, l.currency + ' ') + money(abs(l.amount))
        width = max((len(amount(l)) for l in d.lines), default=0)
        def row(l):
            return '%s %*s %s' % (l.date.strftime('%m/%d'), width, amount(l),
                                  unicodedata.normalize('NFKC', l.desc))
        def group(head, lines):
            if lines:
                total = sum(l.amount for l in lines if l.currency == 'TWD')
                out.append('%s %d %s, %s' % (head[0], len(lines), head[1:],
                                             money(total)))
        missing = d.not_booked()
        booked = [l for l in d.lines if l.match]
        other = [l for l in d.lines if l.kind != 'spend']
        out.append('%s %s' % ('✅' if d.ok() else '⚠️', d.title))
        group('✗not booked', missing)
        out += [row(l) for l in missing]
        group('✓booked', booked)
        for l in booked:
            _, date, genre, place = l.match
            when = ('' if date == l.date.isoformat()
                    else date[5:].replace('-', '/') + ' ')
            out.append('%s ← %s%s' % (row(l), when, ' '.join(
                filter(None, [names.get(genre, '?'), place]))))
        if other:
            out.append('- %d other' % len(other))
            out += [row(l) for l in other]
        out += [t for t, _ in d.totals]
    return '\n'.join(out)

def main():
    args = sys.argv[1:]
    if not (args in ([], ['auth']) or (len(args) == 1 and args[0].isdigit())):
        sys.exit(__doc__)
    try:
        if args == ['auth']:
            return auth()
        found, names = bills(), genres()
        if not found:
            print('No bills in the inbox.')
        pick = range(1, len(found) + 1) if not args else [int(args[0])]
        for n in pick:
            if not 1 <= n <= len(found):
                raise Error('No bill %d; run ./bills.py for the list.' % n)
            print('%d %s\n' % (n, show(found[n - 1][1], names)))
    except Error as e:
        sys.exit(e)

if __name__ == '__main__':
    main()
