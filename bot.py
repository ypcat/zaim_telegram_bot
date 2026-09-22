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

from telegram import BotCommand
from telegram.ext import (
    ApplicationBuilder, CommandHandler, MessageHandler, filters)

import zaim_api

logging.basicConfig(
        format='%(asctime)s %(levelname)-7s %(message)s',
        level=os.environ.get('LOG_LEVEL', 'INFO').upper())

# The Telegram API embeds the bot token in the request path
# (.../bot<TOKEN>/getUpdates), so anything logging a URL leaks it: httpx does
# at INFO, and python-telegram-bot does at DEBUG. Cap both. LOG_LEVEL=DEBUG
# then turns on this module's own debug lines without exposing the token.
logging.getLogger('httpx').setLevel(logging.WARNING)
logging.getLogger('httpcore').setLevel(logging.WARNING)
logging.getLogger('telegram').setLevel(
    max(logging.getLogger().getEffectiveLevel(), logging.INFO))

# Published to Telegram with setMyCommands so they show in the client's
# command menu. /cancel_<id> is omitted: the id varies, so it cannot be
# registered as a static command.
COMMANDS = [
    ('help', 'Show usage'),
    ('cats', 'List categories and aliases'),
    ('month', "This month's total"),
    ('alias', 'Add an alias, e.g. /alias 買菜=食物'),
    ('unalias', 'Remove aliases, e.g. /unalias 買菜 咖啡'),
]

USAGE = '''Log an entry by typing:  <category> <place> <amount>

  午餐 摩斯 120
  20260521 晚餐 鼎泰豐 850   (date first, YYYYMMDD)
  薪水 公司 60000            (income category, logged as income)

Each reply carries a /cancel_<id> link to undo that entry.

/help   this message
/cats   list all categories and their aliases
/month  this month's total
/alias  add an alias, e.g. /alias 買菜=食物
/unalias  remove aliases, e.g. /unalias 買菜 咖啡'''

PARSE_HINT = ("Couldn't parse that. Expected: <category> <place> <amount>\n"
              'e.g. 午餐 摩斯 120   -   /help for the full syntax')

CATS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'cats.json')

def load_cats():
    with open(CATS_PATH) as f:
        return json.load(f)

def save_cats(data):
    tmp = CATS_PATH + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write('\n')
    os.replace(tmp, CATS_PATH)

def reindex():
    """Rebuild the name lookups and the parsing regexes from CATS."""
    global name_to, canonical, entry_pattern, entry_prefix
    name_to, canonical = {}, {}
    for mode in ('expense', 'income'):
        for cid, names in CATS[mode].items():
            canonical[cid] = names[0]
            for name in names:
                name_to[name] = (mode, cid)
    # Longest name first, so 書籍 wins over 書 and 汽車險 over 汽車.
    alt = '|'.join(re.escape(n) for n in sorted(name_to, key=len, reverse=True))
    entry_pattern = re.compile(r"(\d{8})?\s*(%s)\s*(.*\D)\s*(\d+)元?" % alt)
    # The leading part of the same pattern: a message starting with a known
    # category is an attempt at an entry, so failing to parse is worth a hint.
    # Anything else is ordinary chat and is ignored, which matters in groups.
    entry_prefix = re.compile(r"(\d{8})?\s*(%s)" % alt)

CATS = load_cats()
reindex()

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
    me = r.get('me', {})
    logging.info('Zaim account %s (%s), %d entries',
                 me.get('id'), me.get('currency_code'), me.get('input_count', 0))
    return api

REAUTH_HINT = ('Zaim rejected the request: %s\n'
               'If this is 401, the access token expired. Reauthorize with '
               '`bot.py --auth` and tick 家計簿へのアクセスを永続的に許可する.')

def who(update):
    return update.message.from_user.name

def zaim_error(resp):
    """Return a user-facing message if the Zaim call failed, else None."""
    if isinstance(resp, dict) and resp.get('error'):
        return REAUTH_HINT % resp.get('message', resp['error'])

async def usage(update, context):
    logging.info('%s /help', who(update))
    await context.bot.send_message(chat_id=update.message.chat_id, text=USAGE)

def format_cats():
    """Expense grouped by parent category, income last, aliases joined by =."""
    groups = {}
    for cid, names in CATS['expense'].items():
        groups.setdefault(cid[:3], []).append((cid, names))
    lines = ['Expense']
    for parent in sorted(groups):
        lines.append('  ' + ' '.join('='.join(names)
                                     for _, names in sorted(groups[parent])))
    lines.append('')
    lines.append('Income')
    lines.append('  ' + ' '.join('='.join(names)
                                 for _, names in sorted(CATS['income'].items())))
    return '\n'.join(lines)

async def categories(update, context):
    logging.info('%s /cats', who(update))
    await context.bot.send_message(chat_id=update.message.chat_id,
                                   text=format_cats())

ALIAS_USAGE = ('Usage: /alias <new>=<existing>\n'
               'e.g. /alias 買菜=食物\n'
               '/cats lists every category')

def add_alias(arg):
    """Add <new>=<existing> to cats.json. Returns the reply text."""
    if '=' not in arg:
        return ALIAS_USAGE
    new, existing = (part.strip() for part in arg.split('=', 1))
    if not new or not existing:
        return ALIAS_USAGE
    if existing not in name_to:
        return 'No category called %s. /cats lists them.' % existing
    if re.search(r'\s', new) or new.isdigit():
        return '%s cannot be an alias (no spaces, not all digits).' % new
    mode, cid = name_to[existing]
    if new in name_to:
        if name_to[new] == (mode, cid):
            return '%s=%s already exists.' % (new, canonical[cid])
        return '%s is already an alias of %s.' % (new, canonical[name_to[new][1]])
    CATS[mode][cid].append(new)
    save_cats(CATS)
    reindex()
    return 'Added %s=%s' % (new, canonical[cid])

async def alias(update, context):
    arg = ' '.join(context.args)
    reply = add_alias(arg)
    logging.info('%s /alias %s -> %s', who(update), arg, reply.splitlines()[0])
    await context.bot.send_message(chat_id=update.message.chat_id, text=reply)

UNALIAS_USAGE = ('Usage: /unalias <name> [name ...]\n'
                 'e.g. /unalias 買菜 咖啡\n'
                 "A category's last remaining name is never removed.")

def remove_aliases(args):
    """Remove one or more names. Every category keeps at least one."""
    names = [n for n in re.split(r'[\s,]+', ' '.join(args)) if n]
    if not names:
        return UNALIAS_USAGE
    replies, changed = [], False
    for name in names:
        if name not in name_to:
            replies.append('%s: no such category or alias' % name)
            continue
        mode, cid = name_to[name]
        siblings = CATS[mode][cid]
        if len(siblings) == 1:
            replies.append('%s: only name left for this category, kept' % name)
            continue
        was_canonical = siblings[0] == name
        siblings.remove(name)
        changed = True
        reindex()
        if was_canonical:
            replies.append('Removed %s; this category is now %s'
                           % (name, siblings[0]))
        else:
            replies.append('Removed %s from %s' % (name, siblings[0]))
    if changed:
        save_cats(CATS)
    return '\n'.join(replies)

async def unalias(update, context):
    reply = remove_aliases(context.args)
    logging.info('%s /unalias %s -> %s', who(update), ' '.join(context.args),
                 '; '.join(reply.splitlines()))
    await context.bot.send_message(chat_id=update.message.chat_id, text=reply)

async def handler(update, context):
    chat_id = update.message.chat_id
    text = update.message.text
    name = who(update)
    if text:
        data = parse(text)
        if not data:
            if entry_prefix.match(text):
                logging.info('%s could not parse %r', name, text)
                await context.bot.send_message(chat_id=chat_id, text=PARSE_HINT)
            else:
                logging.debug('%s ignored %r', name, text)
            return
        mode = data.pop('mode')
        if mode == 'income':
            func = z.income
        else:
            func = z.payment
        resp = await asyncio.to_thread(lambda: func(**data))
        err = zaim_error(resp)
        if err:
            logging.warning('%s %s rejected by Zaim: %s', name, mode,
                            resp.get('message'))
            await context.bot.send_message(chat_id=chat_id, text=err)
            return

        # income has only category_id
        cat = canonical[data.get('genre_id', data['category_id'])]

        logging.info('%s %s %s %s %s -> id %s', name, mode, cat,
                     data['place'].strip(), data['amount'], resp['money']['id'])
        reply_text = f"Entered {cat} {data['place']} ${data['amount']}\n/cancel_{resp['money']['id']}"
        await context.bot.send_message(chat_id=chat_id, text=reply_text)
        await month(update, context)

async def cancel(update, context):
    money_id = int(context.match.group(1))
    resp = await asyncio.to_thread(z.delete, mode='payment', money_id=money_id)
    err = zaim_error(resp)
    if err:
        logging.warning('%s cancel %s rejected by Zaim: %s', who(update),
                        money_id, resp.get('message'))
        await context.bot.send_message(chat_id=update.message.chat_id, text=err)
        return
    logging.info('%s cancel %s', who(update), money_id)
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
    logging.info('%s month %d-%02d: %d over %d payments', who(update),
                 today.year, today.month, amount, len(r['money']))
    reply_text = f'{today.year}-{today.month:02d}: {amount}'
    await context.bot.send_message(chat_id=update.message.chat_id, text=reply_text)

def parse(text):
    m = entry_pattern.match(text)
    if not m:
        return
    date, cat, place, amount = m.groups()
    if date:
        date = re.sub(r'(\d{4})(\d{2})(\d{2})', r'\1-\2-\3', date)
    mode, cid = name_to[cat]
    if mode == 'income':
        return {
            'category_id': cid,
            'amount': int(amount),
            'place': place,
            'date': date,
            'mode': 'income'
        }
    return {
        'category_id': cid[:3],
        'genre_id': cid,
        'amount': int(amount),
        'place': place,
        'date': date,
        'mode': 'payment'
    }

async def post_init(application):
    await application.bot.set_my_commands(
        [BotCommand(name, description) for name, description in COMMANDS])
    logging.info('Polling as @%s, published %s', application.bot.username,
                 ', '.join('/' + name for name, _ in COMMANDS))

def main():
    global config, z
    config = load_config()
    if '--auth' in sys.argv:
        zaim_api.authorize(config['zaim']['consumer_key'],
                           config['zaim']['consumer_secret'])
        return
    z = init_zaim(config)
    logging.info('%d category names in %d categories', len(name_to), len(canonical))
    application = (ApplicationBuilder()
                   .token(config['telegram']['token'])
                   .post_init(post_init)
                   .build())

    application.add_handler(CommandHandler(['help', 'start'], usage))
    application.add_handler(CommandHandler(['cats', 'cat'], categories))
    application.add_handler(CommandHandler('month', month))
    application.add_handler(CommandHandler('alias', alias))
    application.add_handler(CommandHandler('unalias', unalias))
    application.add_handler(MessageHandler(filters.Regex(r'/cancel_(\d+)'), cancel))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handler))

    application.run_polling()

if __name__ == '__main__':
    main()
