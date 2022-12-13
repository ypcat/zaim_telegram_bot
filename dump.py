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
    oauth_token = api.get_access_token(input('Paste authorized token:'))
    with open('oauth_token.json','w') as f:
        json.dump(oauth_token, f)

def main():
    #TODO fallback oauth
    config = json.load(open('config.json'))
    oauth_token = json.load(open('oauth_token.json'))
    api = zaim.Api(consumer_key=config['zaim']['consumer_key'],
                   consumer_secret=config['zaim']['consumer_secret'],
                   access_token=oauth_token['oauth_token'],
                   access_token_secret=oauth_token['oauth_token_secret'])
    start_date = (datetime.datetime.now() - datetime.timedelta(days=90)).strftime('%Y-%m-%d')
    result = api.money(start_date=start_date)
    for entry in result['money']:
        line = u'%s,%s,%s' % (entry['date'], entry['place'], entry['amount'])
        print(line.encode('utf8'))

if __name__ == '__main__':
    main()

