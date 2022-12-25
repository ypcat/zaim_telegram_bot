#!/usr/bin/env python

import argparse
import csv
import re
import sys

def reconcile(fn_txt, fn_csv):
    right = []
    for row in csv.reader(open(fn_csv)):
        row[0] = row[0][5:7] + '/' + row[0][8:10]
        row[2] = int(row[2])
        right.append(row)
    for r in sorted(right):
        print(r)
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
    print('matched:')
    for row in matched:
        print(row)
    print('unmatched:')
    for row in unmatched:
        print(row)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('txt')
    parser.add_argument('csv')
    args = parser.parse_args()
    reconcile(args.txt, args.csv)

def test():
    reconcile('2022**_****.txt', '20221213_zaim.csv')

if __name__ == '__main__':
    #test()
    main()

