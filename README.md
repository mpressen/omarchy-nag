# Nag

Disposable alarms for the Omarchy bar. Type `15:15 pick up the kids` into one field and it is set. The bar counts down to it, turns red in the last five minutes, and then keeps going until you answer it.

It exists because an alarm for quarter past three today is not an appointment. Putting it in a calendar gives it a life it does not deserve: it syncs to your phone, it shows up in next week's agenda view, and you have to go back and delete it. Nag is the other thing, the one a kitchen timer does, with the difference that you can say what it is for.

Named after and inspired by [Pester](https://sabi.net/nriley/software/) by Nicholas Riley, which has done this on the Mac since 2002.

![Nag in the Omarchy bar](preview.png)

## What you can type

The field takes the time and the message together, and works out where one ends and the other begins.

| You type | You get |
| --- | --- |
| `5m tea` | five minutes from now |
| `90s` | ninety seconds, no message |
| `1h30 call Paul` | an hour and a half from now |
| `15:15 pick up the kids` | quarter past three today, or tomorrow if it has gone |
| `9pm laundry` | tonight |
| `tomorrow 9:00 dentist` | tomorrow morning |
| `wed 18:15 hockey` | the next Wednesday |
| `next monday 8:00 standup` | as it says |
| `2d water the plants` | two days from now |
| `dec 25 9:00 call mum` | a date further out |
| `every fri 15:00 standup` | every Friday at three |
| `every weekday 5pm leave` | Monday to Friday at five |
| `daily 9:00 water the plants` | every day at nine |
| `every mon, wed and fri 7:30 run` | those three days |
| `17:00 every weekday leave` | the time may come first |
| `monthly 15 9:00 rent` | the 15th of every month |
| `every month on the 31st at 9 invoice` | the last day in a shorter month |
| `every weekday except wed 16:30 school` | Monday to Friday but Wednesday |
| `every 5m drink water` | every five minutes from now |
| `every 30s` | every thirty seconds |
| `every 2 days 9:00 plants` | at nine, every other day |

A repeat starts with `every` (or `daily`, `weekdays`, `weekends`) and needs a time: `every friday standup` is refused rather than guessed. The one exception is an interval under a day, `every 5m`, `every 30s`, `every 1h30`, which counts from the moment it is set and takes no time (from 10 seconds up); one that comes round while the previous one is still ringing takes its place rather than ringing on top of it. An interval in whole days or weeks, `every 2 days`, `every 3d`, `every 2 weeks`, needs a time like any other repeat and starts today, or tomorrow if that time has gone. Days can be `day`, `weekday`/`workday`, `weekend`, any day name, lists (`mon, wed and fri`, `mon,wed,fri`) and ranges (`mon-fri`), and `every day` or `every weekday` can leave days out with `except` (`every weekday except wed`, `every day except sat and sun`); the time can be `15:00`, `3pm`, `9:30am` or a bare hour after `at` (`every friday at 15`). Without `every`, `wed 18:15 hockey` is next Wednesday, once. A monthly repeat (`monthly` or `every month`) takes a day of the month, `15`, `15th` or `on the 15th`, or today's without one; a month too short for that day gets its last day, and the next month is back on the day asked for, so the 31st rings on 28 February and 31 March. English only.

A bare number is minutes, so `5` is five minutes, which is what `omarchy reminder` takes too. Durations also accept the spelled-out units (`min`, `hour`, `days`) and `u` for uur.

The line under the field shows what was understood before you commit to it, in the same words the bar will use afterwards. That is the point of it: `wed 18:15 hockey` reading back as "Hockey Wednesday at 18:15" tells you the Wednesday went into the time and not into the message.

## Keys

Everything works without the mouse, and the field keeps the focus the whole time so you can keep typing.

| Key | What it does |
| --- | --- |
| `Enter` | set the alarm |
| `Down` and `Up` | walk into the list of alarms and back out |
| `Enter` on a ringing alarm | snooze it (five minutes, or the Snooze setting) |
| `Delete` on an alarm | remove it, or dismiss it if it is ringing; a repeat asks for a second press |
| `Escape` | leave the list, then close the panel |

Typing anything takes the cursor back out of the list, so you never have to think about which mode you are in.

## Repeating alarms

Each row of a repeat is marked `↻`, with its rule on hover, and has a skip button, which moves it on to the occurrence after the next one. Snooze and dismiss act on the occurrence that rings; the next one is already set by then and does not move. The remove button deletes the whole repeat, on a second click.

A row shows the time the way you typed it: `17:20` for a clock time, the countdown for `5m`, the other one on hover. A message too long for the row reads in full on hover, and is capped at 80 characters.

Every row has an edit button: the field comes back with the alarm as text (`every fri 15:00 standup`, `15:15 pick up the kids`), and Enter replaces the alarm with what it then says. With snooze off, a ringing alarm has the edit button instead of snooze, to put it off by hand.

## When it goes off

A critical notification, the freedesktop alarm sound repeating until you snooze or dismiss it, and the bar widget pulsing red. The alarm keeps ringing in the panel until you dismiss or snooze it, because an alarm that clears itself after a few seconds is one you can miss, and missing it is the whole thing this is meant to prevent. After five minutes with no answer (the Missed after setting), sound or no sound, it stops and its notification turns into a "Missed" one, with no buttons, that stays until you close it. The notification has Snooze and Dismiss buttons, clicking the card snoozes, and closing it with its X dismisses the alarm. On Omarchy before 4.5, which has no notification buttons, clicking it opens the panel instead.

## Setting one from anywhere

`nag ask` opens the panel wherever you are, so setting an alarm is one keystroke away from any workspace. It is the same panel with the same line reading back what it understood, because a second, simpler prompt somewhere else would be one that cannot tell you what it made of what you typed. If there is no Nag widget in your bar to open, it falls back to the Omarchy menu's text prompt and confirms with a notification instead.

Add it to your menu by putting this in `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"nag": {
  "icon": "󰔟",
  "label": "Nag",
  "description": "Set a disposable alarm",
  "action": "$HOME/.config/omarchy/plugins/jankeesvw.nag/bin/nag ask"
}
```

Or bind it to a key in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER, N, Set an alarm, exec, $HOME/.config/omarchy/plugins/jankeesvw.nag/bin/nag ask
```

The panel also opens with `omarchy-shell shell toggle jankeesvw.nag`, which closes it again on the same key.

## Install

```sh
omarchy plugin add https://github.com/jankeesvw/omarchy-nag.git --enable
omarchy bar move jankeesvw.nag --section right
```

Update an installed copy with `omarchy plugin update jankeesvw.nag`.

The countdown shows in the bar from an hour before the next alarm (`countdownMinutes`, 0 for as soon as one is set), so a repeat that rings tomorrow does not sit in the bar all day. With `countdownOn` false the bar shows nothing before an alarm rings.

While no alarm is coming up, the icon stays hidden until the pointer comes onto the bar, the way Omarchy's own indicators do.

To wear another glyph than the timer, in the bar and on the notifications, for instance Omarchy's reminder bell where Nag replaces the reminder:

```sh
omarchy bar set jankeesvw.nag icon 󰢌
```

Nothing to configure, no account, no API key. It needs `jq`, `dd`, `date` and `systemd-run`, which Omarchy already has, and it plays the alarm through `pw-play` with a sound from the `sound-theme-freedesktop` package.

## How it works, and why that matters

Alarms are systemd user timers, set with `--on-calendar` against wall-clock time. That is what makes them survive a shell restart, a Quickshell crash and a suspend. It is also the one behavioural difference from the built-in `omarchy reminder`, which uses `--on-active`: those count monotonic seconds, which stop while the machine sleeps, so a reminder set for 15:15 fires late by however long the lid was shut.

Every alarm is written to disk as well, and the plugin re-arms any timer that has gone missing while its time is still ahead. That covers a reboot, which transient systemd units do not survive on their own. An alarm whose time went by while the machine was off still rings if it is only a few minutes late (within Missed after), and is otherwise reported as missed rather than dropped; a repeat moves on to its next occurrence.

There is no network access of any kind. Nothing is sent anywhere, and nothing is fetched.

## Taking a screenshot of it

`nag demo on` swaps the alarm list for three invented ones at fixed offsets from now, so a screenshot is reproducible and shows nothing of yours. While it is on, every write is a no-op: a click during a shoot cannot cancel a real alarm, and nothing fires. `nag demo off` puts your own alarms back and refreshes the bar at once, so the widget cannot be left showing invented data.

```sh
nag demo on
nag demo status
nag demo off
```

## Files it writes

Everything lives under `~/.local/state/nag`, created 0700, with each file 0600:

- `alarms/<id>.json` for each pending alarm, holding its time and its message
- `ringing/<id>.json` for an alarm that has gone off and is waiting to be answered
- `demo`, an empty marker file, only while demo mode is on

Your alarm messages are in those files, so treat them as you would any note to yourself.

It also creates one transient systemd user unit per alarm, named `nag-<id>.timer`, and it does not touch your Hyprland configuration, `shell.json`, or any other plugin's files.

## Removing it

```sh
omarchy plugin remove jankeesvw.nag
```

Two things survive that, and both need one command each.

Alarms that have not gone off yet are systemd timers, and they keep running after the plugin directory is gone. Stop them before or after removal, which works either way because it does not need the plugin:

```sh
systemctl --user stop 'nag-*.timer'
```

Your stored alarms and messages stay on disk. Delete them if you want them gone:

```sh
rm -rf ~/.local/state/nag
```

If you added the menu row or the keybinding above, remove those lines by hand as well. The plugin never wrote them.

## Tests

`python3 -m unittest discover -s tests` runs end-to-end tests of `bin/nag`: setting, listing, firing, snoozing and dismissing alarms, the notification and its buttons, the sound settings and demo mode. They run in a sandbox with stand-ins for systemd, the shell, notifications and `pw-play`, so nothing rings and no real alarm is touched.

## Licence

MIT. See [LICENSE](LICENSE).
