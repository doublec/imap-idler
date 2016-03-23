# IMAP Idle Monitor

This project is an IMAP Idle monitor written in [Pony](http://www.ponylang.org/). When run it reads `idle.json` for the IMAP servers to monitor and the command to run when IDLE indicates that the mailbox has changed. There is an `imap.json.example` file showing the format of the configuration file.

This was written to learn Pony's networking libraries and was a utility I wanted to update my [notmuch](http://notmuchmail.org/) mail database when new mail arrives.
