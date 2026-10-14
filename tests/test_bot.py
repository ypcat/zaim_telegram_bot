"""/bills handlers with fake Telegram objects. The bot is not started.

    .venv/bin/python -m unittest discover tests
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import bills
import bot
import zaim_db

FIXTURES = os.path.join(os.path.dirname(__file__), 'fixtures')
CHAT = 42

def fake(data=None, chat=CHAT):
    """An update (a command, or a button tap if data) and a context."""
    msg = mock.AsyncMock()
    update = mock.MagicMock()
    update.effective_chat.id = chat
    update.callback_query = None
    if data:
        update.callback_query = mock.AsyncMock()
        update.callback_query.data = data
        update.callback_query.message = msg
    context = mock.MagicMock()
    context.bot.send_message = mock.AsyncMock(return_value=msg)
    context.bot_data = {}
    return update, context, msg

class Bills(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.tmp.name, 'zaim.db')
        self.book = zaim_db.Api(self.db)
        self.book.payment(category_id=101, genre_id=10101, amount=46,
                          date='2026-09-13', place='P')
        with open(os.path.join(FIXTURES, 'sinopac_card.txt')) as f:
            self.doc = bills.sinopac_card(f.read())
        self.patches = [mock.patch.object(bills, 'DB', self.db),
                        mock.patch.object(bot, 'config',
                                          {'bills_chats': [CHAT]}, create=True),
                        mock.patch.object(bills, 'Gmail', mock.MagicMock())]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def queue(self, *found):
        """bills.bills() reading these mails instead of Gmail."""
        bills.Gmail.return_value.queue.return_value = [m for m, _ in found]
        return mock.patch.object(bills, 'read_mail',
                                 lambda g, m: dict(found)[m])

    async def test_not_allowed(self):
        update, context, _ = fake(chat=7)
        await bot.bills_command(update, context)
        text = context.bot.send_message.call_args.kwargs['text']
        self.assertEqual(text, 'Not allowed. To allow it, add chat id 7 to'
                               ' bills_chats in config.json.')
        update, context, _ = fake('bill:a', chat=7)
        await bot.bill_button(update, context)
        update.callback_query.answer.assert_awaited_with('Not allowed.')
        context.bot.send_message.assert_not_awaited()

    async def test_one_mail_expanded(self):
        update, context, msg = fake()
        with self.queue(('a', [self.doc]), ('b', [])):
            await bot.bills_command(update, context)
        args = msg.edit_text.call_args
        self.assertIn('✗ 8 not booked', args.args[0])
        self.assertNotIn('reply_markup', args.kwargs)

    async def test_list_and_detail(self):
        update, context, msg = fake()
        with self.queue(('a', [self.doc]), ('c', [self.doc])):
            await bot.bills_command(update, context)
        self.assertEqual(context.bot.send_message.call_args.kwargs['text'],
                         '<pre>Reading the inbox, about 30 s ...</pre>')
        args = msg.edit_text.call_args
        self.assertEqual(args.args[0], '<pre>1 ⚠️ 永豐信用卡 2026-10 帳單 ✗8\n'
                                       '2 ⚠️ 永豐信用卡 2026-10 帳單 ✗8</pre>')
        keys = args.kwargs['reply_markup'].inline_keyboard
        self.assertEqual([[(k.text, k.callback_data) for k in row]
                          for row in keys],
                         [[('1', 'bill:a'), ('2', 'bill:c')]])

        # Tap 1: the detail, as a new message.
        update, context2, _ = fake('bill:a')
        context2.bot_data = context.bot_data
        await bot.bill_button(update, context2)
        detail = context2.bot.send_message.call_args.kwargs
        self.assertIn('✗ 8 not booked', detail['text'])
        self.assertIn('09/13     46 Go Share 服務費 ← 食物 P', detail['text'])
        self.assertNotIn('reply_markup', detail)

        # Book a missing line, tap 1 again: checked against the book again.
        self.book.payment(category_id=101, genre_id=10101, amount=501,
                          date='2026-09-15', place='IKEA')
        await bot.bill_button(update, context2)
        text = context2.bot.send_message.call_args.kwargs['text']
        self.assertIn('✗ 7 not booked', text)
        self.assertIn('501 A- IKEA宜家家居-內湖店 ← 食物 IKEA', text)

    async def test_progress(self):
        update, context, msg = fake()
        with self.queue(('a', [self.doc]), ('c', [self.doc])):
            await bot.bills_command(update, context)
        texts = [c.args[0] for c in msg.edit_text.call_args_list]
        self.assertEqual(texts[0], '<pre>Reading mail 1 of 2 ...</pre>')
        self.assertTrue(texts[-1].startswith('<pre>1 ⚠️'))

    async def test_timeout(self):
        gmail = self.patches[2].temp_original.__new__(
            self.patches[2].temp_original)
        gmail.token = 't'
        with mock.patch('urllib.request.urlopen', side_effect=TimeoutError(
                'timed out')):
            with self.assertRaisesRegex(bills.Error,
                                        '^Gmail API: timed out$'):
                gmail.get('/messages')

    async def test_html_escaped(self):
        self.doc.title = '<b>&'
        update, context, msg = fake()
        with self.queue(('a', [self.doc])):
            await bot.bills_command(update, context)
        self.assertIn('&lt;b&gt;&amp;', msg.edit_text.call_args.args[0])

    async def test_gone_after_restart(self):
        update, context, _ = fake('bill:a')
        await bot.bill_button(update, context)
        update.callback_query.answer.assert_awaited_with(
            'Not in the last /bills; run /bills again.', show_alert=True)

    async def test_error(self):
        bills.Gmail.side_effect = bills.Error('no gmail_token.json')
        update, context, msg = fake()
        await bot.bills_command(update, context)
        msg.edit_text.assert_awaited_with(
            'Could not check the bills: no gmail_token.json')

if __name__ == '__main__':
    unittest.main()
