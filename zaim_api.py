# -*- coding: utf-8 -*-
"""Minimal Zaim API v2 client.

Vendored replacement for the abandoned `zaim` PyPI package (0.2.3, last
released 2019), which pulled in `future`/`six`/`tabulate` for Python 2
compatibility. Only the endpoints this project uses are implemented.
"""

import json
import os
from urllib.parse import parse_qsl

import requests
from requests_oauthlib import OAuth1

BASE_URL = 'https://api.zaim.net/v2'
AUTH_URL = 'https://auth.zaim.net/users/auth'
TOKEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          'oauth_token.json')


class Api:
    def __init__(self, consumer_key=None, consumer_secret=None,
                 access_token=None, access_token_secret=None):
        self.consumer_key = consumer_key
        self.consumer_secret = consumer_secret
        self.auth = None
        if access_token is not None and access_token_secret is not None:
            self.auth = OAuth1(consumer_key, consumer_secret,
                               access_token, access_token_secret)

    def _request(self, method, path, **kwargs):
        key = 'params' if method == 'GET' else 'data'
        r = requests.request(method, BASE_URL + path, auth=self.auth,
                             **{key: kwargs})
        try:
            return r.json()
        except ValueError:
            raise Exception(r.text)

    def get_request_token(self, callback_uri):
        auth = OAuth1(self.consumer_key, self.consumer_secret,
                      callback_uri=callback_uri)
        r = requests.post(BASE_URL + '/auth/request', auth=auth)
        request_token = dict(parse_qsl(r.text))
        self.request_token = request_token['oauth_token']
        self.request_token_secret = request_token['oauth_token_secret']
        return request_token

    def get_access_token(self, oauth_verifier):
        auth = OAuth1(self.consumer_key, self.consumer_secret,
                      self.request_token, self.request_token_secret,
                      verifier=oauth_verifier)
        r = requests.post(BASE_URL + '/auth/access', auth=auth)
        access_token = dict(parse_qsl(r.text))
        self.auth = OAuth1(self.consumer_key, self.consumer_secret,
                           access_token['oauth_token'],
                           access_token['oauth_token_secret'])
        return access_token

    def verify(self):
        return self._request('GET', '/home/user/verify')

    def money(self, mapping=1, category_id=None, genre_id=None, mode=None,
              order=None, start_date=None, end_date=None, page=None,
              limit=None, group_by=None):
        return self._request('GET', '/home/money',
                             mapping=mapping, category_id=category_id,
                             genre_id=genre_id, mode=mode, order=order,
                             start_date=start_date, end_date=end_date,
                             page=page, limit=limit, group_by=group_by)

    def payment(self, mapping=1, category_id=None, genre_id=None, amount=None,
                date=None, from_account_id=None, comment=None, name=None,
                place=None):
        return self._request('POST', '/home/money/payment',
                             mapping=mapping, category_id=category_id,
                             genre_id=genre_id, amount=amount, date=date,
                             from_account_id=from_account_id, comment=comment,
                             name=name, place=place)

    def income(self, mapping=1, category_id=None, amount=None, date=None,
               to_account_id=None, comment=None, place=None):
        return self._request('POST', '/home/money/income',
                             mapping=mapping, category_id=category_id,
                             amount=amount, date=date,
                             to_account_id=to_account_id, comment=comment,
                             place=place)

    def delete(self, mode, money_id):
        return self._request('DELETE', '/home/money/%s/%d' % (mode, money_id))


# --- access token persistence -------------------------------------------
#
# Zaim uses OAuth 1.0a, which has no refresh mechanism: an access token is
# valid until the user revokes it in the Zaim UI. So authorize once, save the
# token, and reuse it forever.

def from_token(consumer_key, consumer_secret, token_path=TOKEN_PATH):
    """Build an authenticated Api from the saved access token."""
    with open(token_path) as f:
        token = json.load(f)
    return Api(consumer_key, consumer_secret,
               token['oauth_token'], token['oauth_token_secret'])


def authorize(consumer_key, consumer_secret, token_path=TOKEN_PATH,
              prompt=input):
    """Run the interactive OAuth 1.0a flow once and save the access token."""
    api = Api(consumer_key, consumer_secret)
    request_token = api.get_request_token('oob')
    print('Open this URL, approve access, then paste the verifier code:')
    print('  %s?oauth_token=%s' % (AUTH_URL, request_token['oauth_token']))
    verifier = prompt('verifier: ').strip()
    token = api.get_access_token(verifier)
    fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(token, f)
    print('Saved access token to %s' % token_path)
    return api
