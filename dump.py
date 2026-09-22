#!/usr/bin/env python3
# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "requests",
#     "requests-oauthlib",
# ]
# ///

import datetime
import json

import zaim_api

def load_config():
    with open('config.json') as f:
        return json.load(f)

def auth():
    config = load_config()
    ck = config['zaim']['consumer_key']
    cs = config['zaim']['consumer_secret']
    try:
        api = zaim_api.from_token(ck, cs)
    except FileNotFoundError:
        return zaim_api.authorize(ck, cs)
    r = api.verify()
    if r.get('error'):
        print(r)
        return zaim_api.authorize(ck, cs)
    return api

def main():
    api = auth()
    start_date = (datetime.datetime.now() - datetime.timedelta(days=9000)).strftime('%Y-%m-%d')
    result = api.money(start_date=start_date)
    #fn = '%s_zaim.csv' % datetime.datetime.now().strftime('%Y%m%d')
    fn = '%s_zaim.jsonl' % datetime.datetime.now().strftime('%Y%m%d')
    with open(fn, 'w', encoding='utf-8') as f:
        for entry in result['money']:
            #line = '%s,%s,%s' % (entry['date'], entry['place'], entry['amount'])
            line = json.dumps(entry)
            f.write(line + '\n')
    print('write to %s' % fn)

if __name__ == '__main__':
    main()
