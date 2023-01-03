# RSS Telegram Bot
 Inspired by my favorite RSS-to-Telegram-Bot by BoKKeR.
 

## What does it do?
 Conditionally notify users when new RSS is retrieved using telegram's bot api. \
 It's different from the original RSS-to-Telegram-Bot by BoKKeR, I made it so that it gives me updates when they contain keywords that I'm interested in.

## Why did you rewrite it?
 while the original python bot satisfies my needs, using it on an underpowered cpu like my router didn't go well, it's slow and buggy. \
 I find Nim to be especially useful in this case, it's python done right imo. \
 The performance uplift was such a surprise, worth it. \
 There's much to be done later, currently, it's for my personal use only.

### Dependencies:
Make sure to install these first:
```
nimble install telebot 
```
Make sure to replace the const fields with your own fields in the main.nim source file.
