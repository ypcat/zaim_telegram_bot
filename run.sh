#!/bin/bash
cd `dirname $0`
exec uv run --locked python bot.py
