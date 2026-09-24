# -*- coding: utf-8 -*-
"""Minimal Zaim API v2 client.

Vendored replacement for the abandoned `zaim` PyPI package (0.2.3, last
released 2019), which pulled in `future`/`six`/`tabulate` for Python 2
compatibility. Only the endpoints this project uses are implemented.
"""

import json
import os
import re
from html.parser import HTMLParser
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
# Zaim uses OAuth 1.0a, which has no refresh mechanism: there is no refresh
# token and no renewal endpoint. Its approval page offers
#
#   [x] 家計簿へのアクセスを永続的に許可する
#
# which is documented as making the token permanent, but a token authorized
# with it (and with permanent access enabled on the app) was still rejected
# 27 hours later. Treat tokens as lasting about a day; the only recovery is to
# authorize again, which authorize_headless() below does without a browser.

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
    print('Open this URL and approve access:')
    print('  %s?oauth_token=%s' % (AUTH_URL, request_token['oauth_token']))
    print()
    print('  IMPORTANT: tick "家計簿へのアクセスを永続的に許可する" on that page.')
    print('  Without it the token expires in 24 hours. If the checkbox is not')
    print('  shown, enable 永続許可 for this app at https://dev.zaim.net/ first.')
    print()
    try:
        verifier = prompt('verifier code: ').strip()
    except (EOFError, KeyboardInterrupt):
        raise SystemExit('\nAborted. Existing token left alone.')
    if not verifier:
        raise SystemExit('No code entered. Nothing changed.')
    try:
        token = api.get_access_token(verifier)
    except KeyError:
        raise SystemExit('Zaim did not return a token - wrong code? '
                         'Run it again and copy the whole code.')
    save_token(token, token_path)
    print('Saved access token to %s' % token_path)
    return api


def save_token(token, token_path=TOKEN_PATH):
    # Write a fresh 0600 file and rename it over the old one: O_CREAT's mode
    # would not tighten an existing file, and a crash mid-write must not
    # leave a truncated token behind.
    tmp = token_path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(token, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, token_path)


# --- headless authorization ---------------------------------------------
#
# In practice Zaim tokens expire after about 24 hours even with permanent
# access enabled on the app, so an unattended bot has to be able to
# reauthorize without a browser. This logs in with the account password and
# submits the approval form, as the original bot did.

class LoginRejected(RuntimeError):
    """Zaim refused the email/password. Retrying will not help."""


class _AuthPage(HTMLParser):
    """Collect the form's inputs, <code> text and Zaim's login error.

    Inputs are collected the way the original pyquery scraper did, which on
    the live page produces byte-identical POST data: an input's value
    attribute, checkboxes and radios only when checked, 'disagree' skipped.
    """

    def __init__(self):
        super().__init__()
        self.fields, self.code, self.error = {}, [], []
        self._in = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'code':
            self._in = self.code
        elif a.get('id') == 'loginResultMessage':
            self._in = self.error
        if tag != 'input' or not a.get('name') or a['name'] == 'disagree':
            return
        if (a.get('type') or '').lower() in ('checkbox', 'radio'):
            value = (a.get('value') or 'on') if 'checked' in a else None
        else:
            value = a.get('value')
        if value is None:
            self.fields.pop(a['name'], None)
        else:
            self.fields[a['name']] = value

    def handle_endtag(self, tag):
        if tag in ('code', 'div'):
            self._in = None

    def handle_data(self, data):
        if self._in is not None:
            self._in.append(data)


def authorize_headless(consumer_key, consumer_secret, email, password,
                       token_path=TOKEN_PATH):
    """Log in, approve access, save the token.

    Raises LoginRejected when Zaim refuses the credentials, RuntimeError for
    anything else. Mirrors the original scraper, including its callback URL.
    """
    api = Api(consumer_key, consumer_secret)
    request_token = api.get_request_token('http://example.com')
    s = requests.Session()
    r = s.get('%s?oauth_token=%s' % (AUTH_URL, request_token['oauth_token']))
    page = _AuthPage()
    page.feed(r.text)
    data = dict(page.fields)
    data['data[User][email]'] = email
    data['data[User][password]'] = password
    r = s.post(AUTH_URL, data=data)
    page = _AuthPage()
    page.feed(r.text)
    error = ''.join(page.error).strip()
    if error:
        raise LoginRejected('Zaim refused the login: %s' % error)
    verifier = ''.join(page.code).strip()
    if not verifier:
        # Also accept a redirect to the callback carrying the verifier.
        seen = [h.headers.get('Location', '') for h in r.history] + [r.url, r.text]
        m = re.search(r'oauth_verifier=([\w-]+)', ' '.join(seen))
        verifier = m.group(1) if m else ''
    if not verifier:
        dump = os.path.join(os.path.dirname(token_path), 'zaim_auth_debug.html')
        fd = os.open(dump, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(r.text)
        raise RuntimeError('no verifier after login (HTTP %s, %s); page saved '
                           'to %s' % (r.status_code, r.url.split('?')[0], dump))
    try:
        token = api.get_access_token(verifier)
    except KeyError:
        raise RuntimeError('Zaim refused the verifier from the login page')
    save_token(token, token_path)
    return api
