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
import logging

import pyquery
import requests
from telegram.ext import Updater, CommandHandler, MessageHandler, Filters, RegexHandler
import zaim

logging.basicConfig(
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        level=logging.INFO)

def auth(z, config):
    try:
        assert not z.verify()['error']
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

def load_config():
    return json.load(open(os.path.join(os.path.dirname(__file__), 'config.json')))

def init_zaim(config):
    return zaim.Api(config['zaim']['consumer_key'], config['zaim']['consumer_secret'])

def categories(bot, update):
    logging.info('/cat')
    text = u' '.join(sorted(cats.keys(), key=cats.get))
    bot.send_message(chat_id=update.message.chat_id, text=text)

def handler(bot, update):
    global config, z
    chat_id = update.message.chat_id
    text = update.message.text
    name = update.message.from_user.name
    logging.info('%s(%s): %s', name, chat_id, text)
    if text:
        data = parse(text)
        logging.info('data: %s', data)
        if data:
            z = auth(z, config)
            mode = data.pop('mode')
            if mode == 'income':
                func = z.income
            else:
                func = z.payment
            resp = func(**data)
            logging.info('%s: %s', mode, resp)
            genre_or_category = data.get('genre_id', data['category_id']) # income has only category_id
            cat = cats.keys()[cats.values().index(genre_or_category)]
            text = u"Entered %s %s $%d\n/cancel_%d" % (
                    cat, data['place'], data['amount'], resp['money']['id'])
            bot.sendMessage(chat_id=chat_id, text=text)

def cancel(bot, update, groups):
    global config, z
    money_id = int(groups[0])
    logging.info('cancel %s', money_id)
    z = auth(z, config)
    z.delete(mode='payment', money_id=money_id)
    text = 'cancel %d' % money_id
    bot.sendMessage(chat_id=update.message.chat_id, text=text)

def main():
    global config, z
    config = load_config()
    updater = Updater(token=config['telegram']['token'])
    dispatcher = updater.dispatcher
    z = init_zaim(config)
    dispatcher.add_handler(CommandHandler('cat', categories))
    dispatcher.add_handler(RegexHandler(r'/cancel_(\d+)', cancel, pass_groups=True))
    dispatcher.add_handler(MessageHandler(Filters.text, handler))
    logging.info('Start polling')
    updater.start_polling()

cats = {
    u'食物':'10101', u'點心':'10102', u'早餐':'10103', u'午餐':'10104', u'晚餐':'10105',
    u'買菜':'10101', u'咖啡':'10102', u'下午茶': '10102',
    u'雜貨':'10201', u'雜物':'10201',
    u'電車':'10301', u'計程車':'10302', u'公車':'10303', u'機票':'10304',
    u'行動':'10401', u'市話':'10402', u'網路':'10403', u'電視':'10404', u'快遞':'10405', u'郵票':'10406',
    u'手機':'10401', u'電話':'10402',
    u'水費':'10501', u'電費':'10502', u'瓦斯':'10503',
    u'房租':'10601', u'房貸':'10602', u'家具':'10603', u'家電':'10604', u'裝潢':'10605', u'房屋險':'10606',
    u'電器':'10604',
    u'請客':'10701', u'禮物':'10702', u'紅包':'10703',
    u'休閒':'10801', u'展覽':'10802', u'電影':'10803', u'音樂':'10804', u'漫畫':'10805', u'書籍':'10806', u'遊戲':'10807',
    u'書':'10806',
    u'上課':'10901', u'報紙':'10902', u'參考書':'10903', u'考試':'10904', u'學費':'10905', u'補習':'10907',
    u'看病': '11001', u'掛號':'11001', u'藥物':'11002', u'保險':'11003', u'醫療險':'11004',
    u'藥':'11002',
    u'衣服':'11101', u'配件':'11102', u'內衣':'11103', u'健身':'11104', u'理髮':'11105', u'化妝品':'11106', u'美容':'11107', u'洗衣':'11108',
    u'剪髮':'11105',
    u'加油':'11201', u'停車':'11202', u'汽車險':'11203', u'汽車稅':'11204', u'車貸':'11205', u'駕訓班':'11206', u'過路費':'11207',
    u'年金':'11301', u'所得稅':'11302', u'營業稅':'11305',
    u'旅行':'11401', u'房屋':'11402', u'汽車':'11403', u'機車':'11404', u'結婚':'11405', u'生產':'11406', u'看護':'11407',
    u'匯款':'19901', u'零用':'19902', u'預付':'19904', u'提款':'19906', u'儲值':'19908', u'其他':'19909',
    u'匯款':'19901', u'零用':'19902', u'預付':'19904', u'提款':'19906', u'儲值':'19908', u'其他':'19909',

    # income
    u'薪水': '11',
    #u'預付': '12',
    u'獎金': '13',
    #u'額外營收': '14',
    #u'營業收入': '15',
    u'收錢': '19',
    u'收款': '19',
}

cats_income = {
    u'薪水': '11',
    #u'預付': '12',
    u'獎金': '13',
    #u'額外營收': '14',
    #u'營業收入': '15',
    u'收錢': '19',
    u'收款': '19',
}

def parse(text):
    pat = re.compile(u"(\d{8})?\s*(%s)\s*(.*\D)\s*(\d+)元?" % ('|'.join(cats.keys())))
    m = pat.match(text)
    if m:
        date, cat, place, amount = m.groups()
        if date:
            date = re.sub(r'(\d{4})(\d{2})(\d{2})', r'\1-\2-\3', date)
        logging.info('foo: %r', (cat, cats_income, cat in cats_income))
        if cat in cats_income:
            return {
                'category_id': cats_income[cat],
                'amount': int(amount),
                'place': place,
                'date': date,
                'mode': 'income'
            }
        else:
            return {
                'category_id': cats[cat][:3],
                'genre_id': cats[cat],
                'amount': int(amount),
                'place': place,
                'date': date,
                'mode': 'payment'
            }

def test():
    config = load_config()
    z = init_zaim(config)
    print auth(z, config)
    return z

if __name__ == '__main__':
    main()
