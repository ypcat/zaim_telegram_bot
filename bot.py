# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "python-telegram-bot>=22.8",
#     "requests",
#     "requests-oauthlib",
# ]
# ///

import asyncio
import datetime
import json
import os
import re
import sys
import logging

from telegram.ext import (
    ApplicationBuilder, CommandHandler, MessageHandler, filters)

import zaim_api

logging.basicConfig(
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        level=logging.INFO)

# httpx logs every request URL at INFO, and the Telegram API embeds the bot
# token in the path (.../bot<TOKEN>/getUpdates). Keep it out of the logs.
logging.getLogger('httpx').setLevel(logging.WARNING)
logging.getLogger('httpcore').setLevel(logging.WARNING)

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
    u'轉帳':'19901', u'代買':'19904', u'代購':'19904',

    # income
    u'薪水': '11',
    #u'預付': '12',
    u'獎金': '13',
    #u'額外營收': '14',
    #u'營業收入': '15',
    u'營收': '15',
    u'收錢': '19',
    u'收款': '19',
}

cats_income = {
    u'薪水': '11',
    #u'預付': '12',
    u'獎金': '13',
    #u'額外營收': '14',
    #u'營業收入': '15',
    u'營收': '15',
    u'收錢': '19',
    u'收款': '19',
}

def load_config():
    with open(os.path.join(os.path.dirname(__file__), 'config.json')) as f:
        return json.load(f)

def init_zaim(config):
    # Authorize once with --auth. The token then lasts until the app is
    # revoked, provided 永続的に許可 was ticked on Zaim's approval page.
    try:
        api = zaim_api.from_token(config['zaim']['consumer_key'],
                                  config['zaim']['consumer_secret'])
    except FileNotFoundError:
        sys.exit('No %s. Run `uv run python bot.py --auth` once to authorize.'
                 % zaim_api.TOKEN_PATH)
    # Fail at startup rather than on the first message days later.
    r = api.verify()
    if r.get('error'):
        sys.exit('Zaim rejected the saved token (%s). Run '
                 '`uv run python bot.py --auth` to reauthorize.' % r.get('message'))
    return api

REAUTH_HINT = ('Zaim rejected the request: %s\n'
               'If this is 401, the access token expired. Reauthorize with '
               '`bot.py --auth` and tick 家計簿へのアクセスを永続的に許可する.')

def zaim_error(resp):
    """Return a user-facing message if the Zaim call failed, else None."""
    if isinstance(resp, dict) and resp.get('error'):
        return REAUTH_HINT % resp.get('message', resp['error'])

async def categories(update, context):
    logging.info('/cat')
    text = ' '.join(sorted(cats.keys(), key=cats.get))
    await context.bot.send_message(chat_id=update.message.chat_id, text=text)

async def alias(update, context):
    logging.info('/alias %s', update.message.text)
    # Fixed a bug from original: 'text' was undefined here
    await context.bot.send_message(chat_id=update.message.chat_id, text=update.message.text)

async def handler(update, context):
    chat_id = update.message.chat_id
    text = update.message.text
    name = update.message.from_user.name
    logging.info('%s(%s): %s', name, chat_id, text)
    if text:
        data = parse(text)
        logging.info('data: %s', data)
        if data:
            mode = data.pop('mode')
            if mode == 'income':
                func = z.income
            else:
                func = z.payment
            resp = await asyncio.to_thread(lambda: func(**data))
            logging.info('%s: %s', mode, resp)
            err = zaim_error(resp)
            if err:
                await context.bot.send_message(chat_id=chat_id, text=err)
                return

            genre_or_category = data.get('genre_id', data['category_id'])

            # Python 3 equivalent of getting a dict key by value
            cat_list = list(cats.keys())
            val_list = list(cats.values())
            cat = cat_list[val_list.index(genre_or_category)]

            reply_text = f"Entered {cat} {data['place']} ${data['amount']}\n/cancel_{resp['money']['id']}"
            await context.bot.send_message(chat_id=chat_id, text=reply_text)
            await month(update, context)

async def cancel(update, context):
    money_id = int(context.match.group(1))
    logging.info('cancel %s', money_id)
    await asyncio.to_thread(z.delete, mode='payment', money_id=money_id)
    reply_text = f'cancel {money_id}'
    await context.bot.send_message(chat_id=update.message.chat_id, text=reply_text)

async def month(update, context):
    today = datetime.date.today()
    start = today - datetime.timedelta(days=today.day - 1)
    r = await asyncio.to_thread(z.money, mode='payment',
                                start_date=start.isoformat(),
                                end_date=today.isoformat())
    err = zaim_error(r)
    if err:
        await context.bot.send_message(chat_id=update.message.chat_id, text=err)
        return
    amount = sum(i['amount'] for i in r['money'])
    reply_text = f'{today.year}-{today.month:02d}: {amount}'
    await context.bot.send_message(chat_id=update.message.chat_id, text=reply_text)

def parse(text):
    pat = re.compile(r"(\d{8})?\s*(%s)\s*(.*\D)\s*(\d+)元?" % ('|'.join(cats.keys())))
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

def main():
    global config, z
    config = load_config()
    if '--auth' in sys.argv:
        zaim_api.authorize(config['zaim']['consumer_key'],
                           config['zaim']['consumer_secret'])
        return
    z = init_zaim(config)
    application = ApplicationBuilder().token(config['telegram']['token']).build()

    application.add_handler(CommandHandler('cat', categories))
    application.add_handler(CommandHandler('month', month))
    application.add_handler(CommandHandler('alias', alias))
    application.add_handler(MessageHandler(filters.Regex(r'/cancel_(\d+)'), cancel))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handler))

    logging.info('Start polling')
    application.run_polling()

if __name__ == '__main__':
    main()
