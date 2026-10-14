#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["pdfplumber"]
# ///
"""Dev only: PDF text with PII masked, for parser fixtures.

    tests/mask.py bill.pdf|bill.htm ... > tests/fixtures/name.txt

Amounts, dates and merchant names stay. Refuses to print if a NAMES entry
survives. Text comes from bills.py, as the parsers see it.
"""

import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..'))
import bills

NAMES = ['李沛倫', '沛倫', 'PEI-LUN', 'PEILUN', 'PEI LUN', 'ypcat6']

PATTERNS = [
    (r'[A-Z][12]\d{8}', 'ID'),
    (r'[\w.+-]+@[\w-]+(\.[\w-]+)+', 'EMAIL'),
    (r'李.倫', 'NAME'),
    (r'\S{2,4}(?=\s+先生/女士)', 'NAME'),     # gas bill holder
    (r'(?<=買受人統編)(\s+)\S{2,4}', r'\1<NAME>'),
    (r'\S*[市縣]\S*?[區鄉鎮市]\S*?[路街道]\S*?號\S*', 'ADDRESS'),
    (r'[^\s，,:：]{0,15}?[路街巷弄段][^\s，,]{0,20}?號[^\s，,]{0,6}', 'ADDRESS'),
    (r'\d{4}[- ]?[\d*Xx]{4}[- ]?[\d*Xx]{4}[- ]?\d{4}', 'CARD'),
    (r'(?<![\dXx*-])(?=[\dXx*-]*\d)(?=[\dXx*-]*[Xx*])[\dXx*-]{8,}',
     'NUMBER'),
    (r'(?<![A-Za-z0-9])(?=[A-Z0-9-]*[A-Z])(?=(?:[A-Z-]*\d){6})[A-Z0-9-]{7,}'
     r'(?![A-Za-z0-9])', 'CODE'),
    (r'(?<![\d,.])\d[\d-]{6,}\d(?![\d,.])', 'NUMBER'),
    (r'(?<!\d)\d\s+\d\d\s+\d{6}\s+\d(?!\d)', 'NUMBER'),  # water number
    (r'(?<=用水地址：)[^\n]+', 'ADDRESS'),  # wraps before 號
    (r'[^\n]*\bNo\.\s*\d+[^\n]*\b(Rd|St|Ln|Aly|Sec)\.[^\n]*', 'ADDRESS'),
    (r'\S*[市縣][A-Z][a-z]+(-[a-z]+)?', 'ADDRESS'),
]
DATE = re.compile(r'(19|20)\d\d-?(0[1-9]|1[012])-?(0[1-9]|[12]\d|3[01])')

def number(m):
    return m[0] if DATE.fullmatch(m[0]) else '<NUMBER>'

def mask(text):
    for name in NAMES:
        text = re.sub(re.escape(name), '<NAME>', text, flags=re.I)
    for pat, tag in PATTERNS:
        repl = (number if tag == 'NUMBER' else tag if '\\' in tag
                else '<%s>' % tag)
        text = re.sub(pat, repl, text)
    return text

def main():
    for path in sys.argv[1:]:
        with open(path, 'rb') as f:
            data = f.read()
        text = mask(bills.pdf_text(data) if path.lower().endswith('.pdf')
                    else bills.html_file(data))
        if any(n.lower() in text.lower() for n in NAMES):
            sys.exit('%s: a name survived masking' % path)
        print(text)

if __name__ == '__main__':
    main()
