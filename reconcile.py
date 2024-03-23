#!/usr/bin/env python

import argparse
import csv
import glob
import os
import re
import sys

def latest(pat):
    return sorted(glob.glob(pat), key=os.path.getmtime)[-1]

def reconcile(fn_txt, fn_csv):
    fn_txt = fn_txt or latest('*.txt')
    fn_csv = fn_csv or latest('*.csv')
    print(fn_txt, fn_csv)
    right = []
    for row in csv.reader(open(fn_csv)):
        row[0] = row[0][5:7] + '/' + row[0][8:10]
        row[2] = int(row[2])
        right.append(row)
    for r in sorted(right):
        print(' '.join(str(c) for c in r))
    matched = []
    unmatched = []
    for line in open(fn_txt):
        parts = line.split()
        date = parts[0]
        place = ' '.join(parts[2:-1])
        amount = int(parts[-1].replace(',', ''))
        match = None
        for row in right:
            if date == row[0] and amount == row[2]:
                match = row[1]
                break
        if match:
            matched.append([date, place, amount, match])
        else:
            unmatched.append([date, place, amount])
    print
    print('matched:')
    for r in matched:
        print(' '.join(str(c) for c in r))
    print
    print('unmatched:')
    for r in unmatched:
        print(' '.join(str(c) for c in r))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('txt', nargs='?')
    parser.add_argument('csv', nargs='?')
    args = parser.parse_args()
    reconcile(args.txt, args.csv)

def test():
    reconcile('2022**_****.txt', '20221213_zaim.csv')

if __name__ == '__main__':
    #test()
    main()

