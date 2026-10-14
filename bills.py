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

def pdf_text(data):
    for pw in [''] + config().get('bill_passwords', []):
        try:
            with pdfplumber.open(io.BytesIO(data), password=pw) as pdf:
                return '\n'.join(p.extract_text(layout=True) or ''
                                 for p in pdf.pages)
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
        doc.totals.append(('%s total %s = sum of lines ✓' % (label, money(end)),
                           True))
    else:
        doc.totals.append(('%s total %s ≠ sum of lines %s ✗'
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
            kind = 'foreign'
            desc += ' ¥' + money(amount) + (
                ' (%s %s)' % (cur, money(number(orig))) if cur else '')
        else:
            kind = 'spend' if amount > 0 else 'not_spending'
        line = Line(datetime.date(year, int(month), int(day)), desc, amount,
                    kind)
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
                    else html_text(data.decode('utf-8', 'replace')))
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

def show(docs, names):
    """A bill, line by line: ✓ booked (with the book row), ✗ not booked,
    - not spending, ¥ foreign currency (not checked)."""
    out = []
    for d in docs:
        out.append('%s %s' % ('✅' if d.ok() else '⚠️', d.title))
        for l in d.lines:
            if l.kind == 'foreign':
                out.append('  ¥ %s %10s  %s' % (l.date.strftime('%m/%d'), '',
                                                l.desc))
                continue
            row = '  %s %s %10s  %s' % (
                {'spend': '✓' if l.match else '✗', 'not_spending': '-'}[l.kind],
                l.date.strftime('%m/%d'), money(l.amount), l.desc)
            if l.match:
                _, date, genre, place = l.match
                row += '  ← book %s %s %s' % (date[5:].replace('-', '/'),
                                              names.get(genre, '?'), place)
            out.append(row)
        out += ['  ' + t for t, _ in d.totals]
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
