#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["pdfplumber"]
# ///
"""Dev only: PDF text with PII masked, for parser fixtures.

    tests/mask.py bill.pdf ... > tests/fixtures/name.txt

Amounts, dates and merchant names stay. Refuses to print if a NAMES entry
survives. Passwords come from config.json bill_passwords.
"""

import json
import logging
import os
import re
import sys

import pdfplumber

NAMES = ['李沛倫', '沛倫', 'PEI-LUN', 'PEILUN', 'PEI LUN']
CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                      'config.json')

PATTERNS = [
    (r'[A-Z][12]\d{8}', 'ID'),
    (r'[\w.+-]+@[\w-]+(\.[\w-]+)+', 'EMAIL'),
    (r'\S*[市縣]\S*?[區鄉鎮市]\S*?[路街道]\S*?號\S*', 'ADDRESS'),
    (r'\d{4}[- ]?[\d*Xx]{4}[- ]?[\d*Xx]{4}[- ]?\d{4}', 'CARD'),
    (r'(?=[\dXx*-]*\d)(?=[\dXx*-]*[Xx*])\b[\dXx*-]{8,}', 'NUMBER'),
    (r'(?<![\d,.])\d[\d-]{7,}\d(?![\d,.])', 'NUMBER'),
]
DATE = re.compile(r'(19|20)\d\d-?(0[1-9]|1[012])-?(0[1-9]|[12]\d|3[01])')

def number(m):
    return m[0] if DATE.fullmatch(m[0]) else '<NUMBER>'

def mask(text):
    for name in NAMES:
        text = re.sub(re.escape(name), '<NAME>', text, flags=re.I)
    for pat, tag in PATTERNS:
        text = re.sub(pat, number if tag == 'NUMBER' else '<%s>' % tag, text)
    return text

def pdf_text(path, passwords):
    for pw in [''] + passwords:
        try:
            with pdfplumber.open(path, password=pw) as pdf:
                return '\n'.join(p.extract_text(layout=True) or ''
                                 for p in pdf.pages)
        except Exception:
            continue
    sys.exit('%s: no password opens it' % path)

def main():
    logging.getLogger('pdfminer').setLevel(logging.ERROR)
    with open(CONFIG) as f:
        passwords = json.load(f).get('bill_passwords', [])
    for path in sys.argv[1:]:
        text = mask(pdf_text(path, passwords))
        if any(n.lower() in text.lower() for n in NAMES):
            sys.exit('%s: a name survived masking' % path)
        print(text)

if __name__ == '__main__':
    main()
