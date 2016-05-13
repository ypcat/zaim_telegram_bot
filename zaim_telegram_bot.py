#!/usr/bin/env python
# -*- coding: utf-8 -*-

import codecs
import json
import os
import re
import subprocess
import sys
import time
import traceback

import pyquery
import requests
import telegram
import zaim

def auth(z, config):
    try:
        z.verify()
    except:
        traceback.print_exc()
        print 'Renew oauth token'
        request_token = z.get_request_token('http://example.com')
        auth_url = 'https://auth.zaim.net/users/auth?oauth_token=' + request_token['oauth_token']
        s = requests.Session()
        r = s.get(auth_url)
        q = pyquery.PyQuery(r.text)
        data = {i.name: i.value for i in q('input') if i.name != 'disagree'}
        data['data[User][email]'] = config['zaim']['email']
        data['data[User][password]'] = config['zaim']['password']
        r = s.post('https://auth.zaim.net/users/auth', data=data)
        q = pyquery.PyQuery(r.text)
        oauth_verifier = q('code').text()
        access_token = z.get_access_token(oauth_verifier)
        z = zaim.Api(
            consumer_key = config['zaim']['consumer_key'],
            consumer_secret = config['zaim']['consumer_secret'],
            access_token = access_token['oauth_token'],
            access_token_secret = access_token['oauth_token_secret'],
        )
    return z

def main():
    sys.stdout = codecs.getwriter('utf8')(sys.stdout)
    sys.stderr = codecs.getwriter('utf8')(sys.stderr)
    config = json.load(open(os.path.join(os.path.dirname(__file__), 'config.json')))
    bot = telegram.Bot(config['telegram']['token'])
    z = zaim.Api(config['zaim']['consumer_key'], config['zaim']['consumer_secret'])
    update_id = 0
    print bot.getMe()
    while True:
        try:
            for update in bot.getUpdates(offset=update_id+1, timeout=60):
                update_id = update.update_id
                chat_id = update.message.chat_id
                text = update.message.text
                name = update.message.from_user.name
                voice = update.message.voice
                print name, chat_id, text, voice
                if text.lower() == 'cancel':
                    markup = telegram.ReplyKeyboardHide()
                    bot.sendMessage(chat_id=chat_id, text='Cancelled', reply_markup=markup)
                elif text.lower().startswith('cat'):
                    text = u' '.join(sorted(cats.keys(), key=cats.get))
                    bot.sendMessage(chat_id=chat_id, text=text)
                elif text:
                    data = parse(text)
                    print data
                    if data:
                        z = auth(z, config)
                        print z.payment(**data)
                        markup = telegram.ReplyKeyboardHide()
                        cat = cats.keys()[cats.values().index(data['genre_id'])]
                        text = u"Entered %s %s $%d" % (cat, data['place'], data['amount'])
                        bot.sendMessage(chat_id=chat_id, text=text, reply_markup=markup)
                elif voice:
                    bot.sendMessage(chat_id=chat_id, text='Processing voice')
                    kb = [[t] for t in dictate(bot.getFile(voice.file_id), config)] + [['Cancel']]
                    markup = telegram.ReplyKeyboardMarkup(kb, resize_keyboard=True, one_time_keyboard=True)
                    bot.sendMessage(chat_id=chat_id, text='Choose result', reply_markup=markup)
        except KeyboardInterrupt:
            break
        except:
            traceback.print_exc()
            time.sleep(60)

cats = {
    u'食物':'10101', u'點心':'10102', u'早餐':'10103', u'午餐':'10104', u'晚餐':'10105',
    u'買菜':'10101', u'咖啡':'10102', u'下午茶': '10102',
    u'雜貨':'10201',
    u'電車':'10301', u'計程車':'10302', u'公車':'10303', u'機票':'10304',
    u'行動':'10401', u'市話':'10402', u'網路':'10403', u'電視':'10404', u'快遞':'10405', u'郵票':'10406',
    u'水費':'10501', u'電費':'10502', u'瓦斯':'10503',
    u'房租':'10601', u'房貸':'10602', u'家具':'10603', u'家電':'10604', u'裝潢':'10605', u'房屋險':'10606',
    u'請客':'10701', u'禮物':'10702', u'紅包':'10703',
    u'休閒':'10801', u'展覽':'10802', u'電影':'10803', u'音樂':'10804', u'漫畫':'10805', u'書籍':'10806', u'遊戲':'10807',
    u'上課':'10901', u'報紙':'10902', u'參考書':'10903', u'考試':'10904', u'學費':'10905', u'補習':'10907',
    u'看病': '11001', u'掛號':'11001', u'藥物':'11002', u'保險':'11003', u'醫療險':'11004',
    u'衣服':'11101', u'配件':'11102', u'內衣':'11103', u'健身':'11104', u'理髮':'11105', u'化妝品':'11106', u'美容':'11107', u'洗衣':'11108',
    u'加油':'11201', u'停車':'11202', u'汽車險':'11203', u'汽車稅':'11204', u'車貸':'11205', u'駕訓班':'11206', u'過路費':'11207',
    u'年金':'11301', u'所得稅':'11302', u'營業稅':'11305',
    u'旅行':'11401', u'房屋':'11402', u'汽車':'11403', u'機車':'11404', u'結婚':'11405', u'生產':'11406', u'看護':'11407',
    u'匯款':'19901', u'零用':'19902', u'預付':'19904', u'提款':'19906', u'儲值':'19908', u'其他':'19909',
}

def parse(text):
    pat = re.compile(u"(%s)\s*(.*\D)\s*(\d+)元?" % ('|'.join(cats.keys())))
    m = pat.match(text)
    if m:
        cat, place, amount = m.groups()
        return {
            'category_id': cats[cat][:3],
            'genre_id': cats[cat],
            'amount': int(amount),
            'place': place
        }

def dictate(file, config):
    file_url = file.file_path
    key = config['google']['key']
    api_url = 'https://www.google.com/speech-api/v2/recognize?output=json&lang=zh-tw&key=' + key
    cmd = '|'.join([
        "curl '{file_url}'",
        "opusdec --rate 16000 - -",
        "curl '{api_url}' -H 'Content-Type: audio/l16; rate=16000' --data-binary @-"
    ]).format(**locals())
    print cmd
    out = subprocess.check_output(cmd, shell=1)
    print out.decode('utf8')
    for line in out.splitlines():
        for result in json.loads(line)['result']:
            for alt in result['alternative']:
                print alt['transcript']
                yield alt['transcript']

if __name__ == '__main__':
    main()
