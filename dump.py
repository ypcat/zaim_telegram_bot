#!/usr/bin/env python2

import datetime
import json

import zaim

def oauth():
    config = json.load(open('config.json'))
    api = zaim.Api(consumer_key=config['zaim']['consumer_key'],
                   consumer_secret=config['zaim']['consumer_secret'])
    request_token = api.get_request_token('oob')
    print('https://auth.zaim.net/users/auth?oauth_token=' + request_token['oauth_token'])
    token = raw_input('Paste authorized token: ')
    oauth_token = api.get_access_token(token)
    with open('oauth_token.json','w') as f:
        json.dump(oauth_token, f)

def auth():
    config = json.load(open('config.json'))
    oauth_token = json.load(open('oauth_token.json'))
    api = zaim.Api(consumer_key=config['zaim']['consumer_key'],
                   consumer_secret=config['zaim']['consumer_secret'],
                   access_token=oauth_token['oauth_token'],
                   access_token_secret=oauth_token['oauth_token_secret'])
    r = api.verify()
    if r.get('error'):
        print(r)
        oauth()
        return auth()
    return api

def main():
    api = auth()
    start_date = (datetime.datetime.now() - datetime.timedelta(days=90)).strftime('%Y-%m-%d')
    result = api.money(start_date=start_date)
    fn = '%s_zaim.csv' % datetime.datetime.now().strftime('%Y%m%d')
    with open(fn, 'w') as f:
        for entry in result['money']:
            line = u'%s,%s,%s' % (entry['date'], entry['place'], entry['amount'])
            f.write(line.encode('utf8') + '\n')
    print('write to %s' % fn)

if __name__ == '__main__':
    main()

