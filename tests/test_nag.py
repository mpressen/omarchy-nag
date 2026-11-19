"""End-to-end tests for bin/nag.

Each test drives the real script through its command line, the way the panel,
the notification buttons and the systemd timers do, inside a sandbox: its own
state directory, and stand-ins on PATH for everything that would reach the
desktop (systemd, the shell, notifications, the speakers). The stand-ins record
how they were called, so a test can check what reached the desktop without
anything actually ringing.

Run with:  python3 -m unittest discover -s tests
"""

import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from datetime import date, datetime, timedelta
from datetime import time as clock

NAG = os.environ.get("NAG_BIN") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "nag")
DEFAULT_SOUND = "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
NID = "42"

# Every stand-in logs its name and arguments as one JSON array per line.
LOG = r'''printf '%s\0' "$(basename "$0")" "$@" | jq -Rsc 'split("\u0000")[:-1]' >>"$NAG_TEST/calls.log"
'''

STUBS = {
    # Settings come from a JSON file instead of shell.json. Unset keys print
    # nothing and fail, as `omarchy-bar get` does.
    "omarchy-bar": """
[[ $1 == get ]] || exit 0
jq -r --arg k "$3" 'if has($k) then .[$k] else empty end' "$NAG_TEST/settings.json"
""",
    # A loaded unit is a marker file. A timer only waits; a service runs now,
    # in the background, and its marker goes when it ends.
    "systemd-run": """
cmd=(); unit=""; timer=0
while (($#)); do
  case $1 in
    --unit=*) unit=${1#--unit=} ;;
    --on-calendar=*) timer=1 ;;
    --) shift; cmd=("$@"); break ;;
  esac
  shift
done
if ((timer)); then : >"$NAG_TEST/timers/$unit.timer"; exit 0; fi
if [[ -n $unit ]]; then
  [[ -e $NAG_TEST/timers/$unit.service ]] && exit 1
  : >"$NAG_TEST/timers/$unit.service"
fi
( "${cmd[@]}"; [[ -z $unit ]] || rm -f "$NAG_TEST/timers/$unit.service" ) >/dev/null 2>&1 &
echo $! >>"$NAG_TEST/pids"
""",
    "systemctl": """
case $2 in
  list-units) for u in "${@:3}"; do [[ $u != -* && -e $NAG_TEST/timers/$u ]] && echo "$u loaded active"; done ;;
  stop) rm -f "$NAG_TEST/timers/$3" ;;
esac
exit 0
""",
    "omarchy-notification-send": """
for a; do [[ $a == -p ]] && echo "$NAG_NID"; done
exit 0
""",
    "omarchy-shell": """
[[ "$1 $2" == "shell summon" ]] && echo "${NAG_SUMMON:-unknown}"
exit 0
""",
    "omarchy-menu-input": 'printf "%s" "$NAG_MENU_INPUT"\n',
    # The notification server's signals are whatever the test writes to a file.
    "gdbus": 'exec tail -n +1 -F "$NAG_TEST/dbus" 2>/dev/null\n',
    "pw-play": "/usr/bin/sleep 0.05\n",
    # Real waits would make the suite crawl; the log keeps the asked length.
    "sleep": "/usr/bin/sleep 0.05\n",
}


def wait_for(condition, timeout=5.0, what="condition"):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


class NagTestCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="nag-test-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        stubs = os.path.join(self.root, "stubs")
        os.makedirs(stubs)
        os.makedirs(os.path.join(self.root, "timers"))
        for name in ("calls.log", "dbus", "pids"):
            open(os.path.join(self.root, name), "w").close()
        for name, body in STUBS.items():
            path = os.path.join(stubs, name)
            with open(path, "w") as f:
                f.write("#!/bin/bash\n" + LOG + body)
            os.chmod(path, 0o755)

        self.home = os.path.join(self.root, "home")
        os.makedirs(self.home)
        self.env = {
            "PATH": stubs + ":/usr/bin:/bin",
            "HOME": self.home,
            "XDG_STATE_HOME": os.path.join(self.root, "state"),
            "NAG_TEST": self.root,
            "NAG_NID": NID,
            "LANG": "C.UTF-8",
        }
        self.sound = os.path.join(self.root, "ring.oga")
        open(self.sound, "w").close()
        self.settings(sound=self.sound)
        self.rings = []
        self.addCleanup(self.stop_rings)

    # --- driving the script -------------------------------------------------

    def settings(self, **values):
        with open(os.path.join(self.root, "settings.json"), "w") as f:
            json.dump(values, f)

    def nag(self, *args, **env):
        out = subprocess.run(
            [NAG, *args], env={**self.env, **env}, capture_output=True,
            text=True, timeout=20, start_new_session=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout) if out.stdout.strip() else None

    def set(self, text):
        result = self.nag("set", text)
        self.assertTrue(result["ok"], result)
        return result

    def alarms(self):
        return self.nag("list")["alarms"]

    def ring(self, text="5m tea"):
        """Set an alarm and let its timer fire; returns the alarm's id."""
        alarm_id = self.set(text)["id"]
        proc = subprocess.Popen(
            [NAG, "fire", alarm_id], env=self.env, start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.rings.append(proc)
        wait_for(lambda: any(a["ringing"] for a in self.alarms()), what="ringing")
        return alarm_id

    def stop_rings(self):
        with open(os.path.join(self.root, "pids")) as f:
            groups = [int(pid) for pid in f.read().split()]
        for pid in [proc.pid for proc in self.rings] + groups:
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        for proc in self.rings:
            proc.wait()

    def close_notification(self, nid=NID):
        """The shell closing the card, as its X does."""
        with open(os.path.join(self.root, "dbus"), "a") as f:
            f.write("/org/freedesktop/Notifications: org.freedesktop.Notifications."
                    f"NotificationClosed (uint32 {nid}, uint32 2)\n")

    def calls(self, name):
        with open(os.path.join(self.root, "calls.log")) as f:
            rows = [json.loads(line) for line in f if line.strip()]
        return [row[1:] for row in rows if row[0] == name]

    def notifications(self):
        return self.calls("omarchy-notification-send")

    def first_play(self):
        return wait_for(lambda: self.calls("pw-play"), what="the sound")[0]

    def timers(self):
        return sorted(t for t in os.listdir(os.path.join(self.root, "timers")) if t.endswith(".timer"))

    def reboot(self):
        """Transient units do not survive a reboot; the alarm files do."""
        for unit in os.listdir(os.path.join(self.root, "timers")):
            os.remove(os.path.join(self.root, "timers", unit))

    def move_alarm(self, alarm_id, at):
        """Pretend an alarm's time is somewhere else, as a reboot past it would."""
        with open(self.alarm_file(alarm_id)) as f:
            doc = json.load(f)
        doc["at"] = at
        with open(self.alarm_file(alarm_id), "w") as f:
            json.dump(doc, f)

    def alarm_file(self, alarm_id):
        return os.path.join(self.root, "state", "nag", "alarms", alarm_id + ".json")


def epoch(day, hour, minute=0):
    return int(datetime.combine(day, clock(hour, minute)).timestamp())


class ParsingTest(NagTestCase):
    def parse(self, text):
        return self.nag("parse", text)

    def assertDueIn(self, text, seconds, message):
        before = int(time.time())
        result = self.parse(text)
        self.assertTrue(result["ok"], result)
        self.assertGreaterEqual(result["at"], before + seconds)
        self.assertLessEqual(result["at"], int(time.time()) + seconds)
        self.assertEqual(result["message"], message)

    def test_durations(self):
        self.assertDueIn("5m tea", 300, "tea")
        self.assertDueIn("90s", 90, "")
        self.assertDueIn("1h30 call Paul", 5400, "call Paul")
        self.assertDueIn("2d water the plants", 2 * 86400, "water the plants")
        self.assertDueIn("1 hour stretch", 3600, "stretch")
        self.assertDueIn("2u nap", 7200, "nap")

    def test_bare_number_is_minutes(self):
        self.assertDueIn("5", 300, "")

    def test_leading_zero_is_not_octal(self):
        self.assertDueIn("08m eggs", 480, "eggs")

    def test_day_and_time_words_go_to_the_time(self):
        result = self.parse("tomorrow 9:00 dentist")
        self.assertEqual(result["at"], epoch(date.today() + timedelta(days=1), 9))
        self.assertEqual(result["message"], "dentist")
        self.assertEqual(result["atPhrase"], "tomorrow at 09:00")

    def test_clock_time_already_gone_means_tomorrow(self):
        earlier = max(datetime.now() - timedelta(hours=1),
                      datetime.combine(date.today(), clock(0, 0)))
        result = self.parse(earlier.strftime("%H:%M") + " lunch")
        self.assertEqual(result["at"],
                         epoch(date.today() + timedelta(days=1), earlier.hour, earlier.minute))

    def test_reads_back_the_moment_and_the_wait(self):
        result = self.parse("1h30 call")
        self.assertIn(result["remaining"], ("1h 30m", "1h 29m"))
        self.assertTrue(result["atPhrase"].startswith(("at ", "tomorrow at ")), result)

    def test_text_without_a_time_is_refused(self):
        self.assertFalse(self.parse("pick up the kids")["ok"])
        self.assertFalse(self.parse("yesterday 9:00 too late")["ok"])
        self.assertFalse(self.parse("")["ok"])

    def test_message_whitespace_and_control_characters_are_cleaned(self):
        self.assertEqual(self.parse("5m  tea \t\x07 now")["message"], "tea now")

    def test_list_says_whether_the_time_was_typed_as_a_duration(self):
        self.set("5m tea")
        self.set("tomorrow 9:00 dentist")
        self.set("every day 9:00 water")
        relative = {a["message"]: a["relative"] for a in self.alarms()}
        self.assertEqual(relative, {"tea": True, "dentist": False, "water": False})

    def test_duration_alarm_is_edited_as_a_duration(self):
        for typed in ("5m tea", "2h 30m tea", "1d 2h 5m tea"):
            self.set(typed)
            [alarm] = [a for a in self.alarms() if a["spec"] == typed]
            self.assertEqual(self.parse(alarm["spec"])["message"], "tea")
        self.set("40s soon")
        [soon] = [a for a in self.alarms() if a["message"] == "soon"]
        self.assertRegex(soon["spec"], r"^\d+s soon$")
        self.set("tomorrow 9:00 dentist")
        [dentist] = [a for a in self.alarms() if a["message"] == "dentist"]
        self.assertEqual(dentist["spec"], "tomorrow 09:00 dentist")

    def test_long_message_is_capped_to_fit_a_row(self):
        alarm = self.set("5m " + "a" * 150)
        self.assertEqual(alarm["message"], "a" * 80)


class AlarmsTest(NagTestCase):
    def test_set_alarm_is_listed_and_timed(self):
        alarm_id = self.set("5m tea")["id"]
        [alarm] = self.alarms()
        self.assertEqual((alarm["id"], alarm["message"], alarm["ringing"]), (alarm_id, "tea", False))
        self.assertEqual(self.timers(), [f"nag-{alarm_id}.timer"])

    def test_list_is_in_time_order_with_the_next_one_first(self):
        self.set("1h later")
        self.set("5m sooner")
        listing = self.nag("list")
        self.assertEqual([a["message"] for a in listing["alarms"]], ["sooner", "later"])
        self.assertEqual(listing["next"]["message"], "sooner")
        self.assertEqual(listing["count"], 2)

    def test_cancel_removes_the_alarm_and_its_timer(self):
        alarm_id = self.set("5m tea")["id"]
        self.assertTrue(self.nag("cancel", alarm_id)["ok"])
        self.assertEqual(self.alarms(), [])
        self.assertEqual(self.timers(), [])

    def test_clear_removes_everything(self):
        self.set("5m tea")
        self.set("1h call")
        self.nag("clear")
        self.assertEqual(self.alarms(), [])
        self.assertEqual(self.timers(), [])

    def test_unknown_ids_are_refused(self):
        for command in ("cancel", "dismiss", "snooze"):
            self.assertFalse(self.nag(command, "../../etc")["ok"], command)

    def test_alarm_survives_a_reboot(self):
        alarm_id = self.set("1h call")["id"]
        os.remove(os.path.join(self.root, "timers", f"nag-{alarm_id}.timer"))
        self.assertEqual([a["id"] for a in self.alarms()], [alarm_id])
        self.assertEqual(self.timers(), [f"nag-{alarm_id}.timer"])

    def test_alarm_missed_while_off_is_reported_not_lost(self):
        alarm_id = self.set("5m tea")["id"]
        self.reboot()
        self.move_alarm(alarm_id, int(time.time()) - 3600)
        self.assertEqual(self.alarms(), [])
        [notification] = self.notifications()
        self.assertIn("Missed: tea", notification)

    def test_alarm_just_missed_while_off_still_rings(self):
        alarm_id = self.set("5m tea")["id"]
        self.reboot()
        self.move_alarm(alarm_id, int(time.time()) - 60)
        self.alarms()
        wait_for(lambda: any(a["ringing"] for a in self.alarms()), what="the late ring")
        self.assertNotIn("Missed: tea", sum(self.notifications(), []))

    def test_corrupt_or_planted_files_are_dropped(self):
        self.set("5m tea")
        alarm_dir = os.path.dirname(self.alarm_file("x"))
        with open(os.path.join(alarm_dir, "1700000000-1.json"), "w") as f:
            f.write("not json")
        os.symlink("/etc/passwd", os.path.join(alarm_dir, "1700000000-2.json"))
        self.assertEqual([a["message"] for a in self.alarms()], ["tea"])
        self.assertEqual(len(os.listdir(alarm_dir)), 1)


class RingingTest(NagTestCase):
    def test_fired_alarm_rings_until_answered(self):
        alarm_id = self.ring("5m tea")
        [alarm] = self.alarms()
        self.assertEqual((alarm["id"], alarm["remaining"]), (alarm_id, "now"))
        self.assertEqual(self.nag("list")["ringingCount"], 1)
        self.assertEqual(self.first_play(), ["--", self.sound])
        wait_for(lambda: len(self.calls("pw-play")) >= 3, what="the sound to repeat")

    def test_notification_offers_snooze_and_dismiss(self):
        self.settings(sound=self.sound, snoozeMinutes=10)
        alarm_id = self.ring("5m tea")
        [notification] = self.notifications()
        self.assertIn("critical", notification)
        self.assertIn("tea", notification)
        actions = [notification[i + 1] for i, a in enumerate(notification) if a == "--action"]
        self.assertEqual(actions, ["Snooze 10 min", "Dismiss"])
        self.assertEqual(notification[-1], alarm_id)

    def test_without_snooze_the_notification_only_dismisses(self):
        self.settings(sound=self.sound, snoozeOn=False)
        alarm_id = self.ring()
        [notification] = self.notifications()
        self.assertNotIn("--action", notification)
        self.assertEqual(notification[notification.index("--exec") + 2:], ["dismiss", alarm_id])

    def test_dismiss_stops_the_alarm(self):
        alarm_id = self.ring()
        self.assertTrue(self.nag("dismiss", alarm_id)["ok"])
        self.assertEqual(self.alarms(), [])
        self.rings[0].wait(timeout=5)

    def test_answered_alarm_leaves_no_bus_monitor_running(self):
        self.nag("dismiss", self.ring())
        self.rings[0].wait(timeout=5)
        monitor = os.path.join(self.root, "dbus")
        wait_for(lambda: subprocess.run(["pgrep", "-f", monitor],
                                        stdout=subprocess.DEVNULL).returncode == 1,
                 what="the close watcher to stop")

    def test_snooze_sets_it_again_later(self):
        self.settings(sound=self.sound, snoozeMinutes=10)
        alarm_id = self.ring("5m tea")
        before = int(time.time())
        snoozed = self.nag("snooze", alarm_id)
        [alarm] = self.alarms()
        self.assertEqual((alarm["id"], alarm["message"], alarm["ringing"]), (snoozed["id"], "tea", False))
        self.assertGreaterEqual(alarm["at"], before + 600)
        self.assertLessEqual(alarm["at"], int(time.time()) + 600)

    def test_snooze_length_from_the_panel(self):
        alarm_id = self.ring()
        before = int(time.time())
        self.nag("snooze", alarm_id, "3")
        self.assertGreaterEqual(self.alarms()[0]["at"], before + 180)
        self.assertFalse(self.nag("snooze", self.alarms()[0]["id"], "0")["ok"])

    def test_closing_the_notification_dismisses(self):
        self.ring()
        self.close_notification()
        wait_for(lambda: self.alarms() == [], what="the dismiss")

    def test_closing_another_notification_does_nothing(self):
        self.ring()
        self.close_notification(nid="7")
        time.sleep(0.5)
        self.assertEqual(len(self.alarms()), 1)

    def test_closing_after_a_snooze_keeps_the_snoozed_alarm(self):
        alarm_id = self.ring()
        self.nag("snooze", alarm_id)
        self.close_notification()
        time.sleep(0.5)
        [alarm] = self.alarms()
        self.assertFalse(alarm["ringing"])

    def test_sound_off_rings_silently(self):
        self.settings(sound=self.sound, soundOn=False)
        self.ring()
        time.sleep(0.3)
        self.assertEqual(self.calls("pw-play"), [])
        self.assertEqual(len(self.notifications()), 1)

    def test_sound_once(self):
        self.settings(sound=self.sound, soundRepeat=False)
        self.ring()
        time.sleep(0.5)
        self.assertEqual(len(self.calls("pw-play")), 1)
        self.assertEqual(len(self.alarms()), 1)

    def test_pause_between_plays(self):
        self.settings(sound=self.sound, soundPause=3)
        self.ring()
        wait_for(lambda: len(self.calls("pw-play")) >= 2, what="a second play")
        self.assertIn(["3"], self.calls("sleep"))

    @unittest.skipUnless(os.path.exists(DEFAULT_SOUND), "no freedesktop sound theme")
    def test_missing_sound_file_falls_back_to_the_default(self):
        self.settings(sound="~/gone.oga")
        self.ring()
        self.assertEqual(self.first_play(), ["--", DEFAULT_SOUND])

    def test_sound_path_may_start_with_tilde(self):
        shutil.copy(self.sound, os.path.join(self.home, "mine.oga"))
        self.settings(sound="~/mine.oga")
        self.ring()
        self.assertEqual(self.first_play(), ["--", os.path.join(self.home, "mine.oga")])

    def test_notification_wears_the_icon_setting(self):
        self.settings(sound=self.sound, icon="X")
        self.ring()
        [notification] = self.notifications()
        self.assertEqual(notification[notification.index("-g") + 1], "X")

    def test_dash_message_still_notifies(self):
        self.ring("5m -u call")
        [notification] = self.notifications()
        headline = notification[notification.index("-g") + 2]
        self.assertEqual(headline, "u call")


class RingLimitTest(NagTestCase):
    def test_unanswered_alarm_becomes_missed(self):
        self.settings(sound=self.sound, ringMinutes=1)
        self.ring("5m tea")
        missed = wait_for(lambda: [n for n in self.notifications() if "Missed: tea" in n],
                          timeout=15, what="the ring to time out")[0]
        self.assertEqual(self.alarms(), [])
        self.assertEqual(missed[missed.index("-r") + 1], NID)
        self.rings[0].wait(timeout=5)


def next_at(weekdays, hour, minute=0, after=None):
    after = after or time.time()
    for i in range(8):
        day = date.fromtimestamp(after) + timedelta(days=i)
        at = epoch(day, hour, minute)
        if at > after and day.isoweekday() in weekdays:
            return at


class RecurrenceTest(NagTestCase):
    def parse(self, text):
        result = self.nag("parse", text)
        self.assertTrue(result["ok"], (text, result))
        return result

    def test_phrasings(self):
        cases = {
            "every friday 15:00 standup": ([5], 15, "standup", "every Friday at 15:00"),
            "every Friday at 15 standup": ([5], 15, "standup", "every Friday at 15:00"),
            "every weekday 5pm leave": ([1, 2, 3, 4, 5], 17, "leave", "every weekday at 17:00"),
            "every workday at 9:30am": ([1, 2, 3, 4, 5], 9, "", "every weekday at 09:30"),
            "daily 9:00 water": ([1, 2, 3, 4, 5, 6, 7], 9, "water", "every day at 09:00"),
            "every day 9 water": ([1, 2, 3, 4, 5, 6, 7], 9, "water", "every day at 09:00"),
            "weekends 10:00 brunch": ([6, 7], 10, "brunch", "every weekend at 10:00"),
            "every mon, wed and fri 7:30 run": ([1, 3, 5], 7, "run", "every Mon, Wed and Fri at 07:30"),
            "every mon-fri 8am": ([1, 2, 3, 4, 5], 8, "", "every weekday at 08:00"),
            "17:00 every weekday leave": ([1, 2, 3, 4, 5], 17, "leave", "every weekday at 17:00"),
        }
        for text, (days, hour, message, phrase) in cases.items():
            result = self.parse(text)
            minute = 30 if ":30" in text else 0
            self.assertEqual(result["repeat"]["days"], days, text)
            self.assertEqual(result["at"], next_at(days, hour, minute), text)
            self.assertEqual((result["message"], result["atPhrase"]), (message, phrase), text)

    def test_a_repeat_needs_a_time(self):
        for text in ("every friday standup", "every 5m", "every"):
            self.assertFalse(self.nag("parse", text)["ok"], text)

    def test_every_in_the_message_is_just_words(self):
        result = self.parse("5m ask about every friday")
        self.assertIsNone(result["repeat"])
        self.assertEqual(result["message"], "ask about every friday")

    def test_a_day_without_every_is_once(self):
        self.assertIsNone(self.parse("fri 15:00 standup")["repeat"])

    def test_listed_with_its_rule_and_editable_text(self):
        self.set("every fri 15:00 standup")
        [alarm] = self.alarms()
        self.assertEqual((alarm["repeatLabel"], alarm["spec"]), ("Fri", "every fri 15:00 standup"))
        self.assertEqual(self.parse(alarm["spec"])["at"], alarm["at"])

    def test_firing_sets_the_next_occurrence(self):
        alarm_id = self.ring("every weekday 9:00 standup")
        first = json.load(open(os.path.join(self.root, "state", "nag", "ringing", alarm_id + ".json")))["at"]
        alarms = self.alarms()
        self.assertEqual([a["ringing"] for a in alarms], [True, False])
        self.assertEqual(alarms[1]["at"], next_at([1, 2, 3, 4, 5], 9, after=first))
        self.assertEqual(alarms[1]["repeatLabel"], "weekdays")

    def test_snooze_and_dismiss_leave_the_series(self):
        alarm_id = self.ring("every day 9:00 water")
        snoozed = self.nag("snooze", alarm_id)
        self.assertIsNone(snoozed["repeat"])
        self.assertEqual(sorted(bool(a["repeat"]) for a in self.alarms()), [False, True])
        self.nag("dismiss", snoozed["id"])
        [series] = self.alarms()
        self.assertEqual(series["repeatLabel"], "daily")

    def test_skip_moves_to_the_occurrence_after(self):
        alarm = self.set("every mon, thu 7:30 gym")
        skipped = self.nag("skip", alarm["id"])
        self.assertEqual(skipped["at"], next_at([1, 4], 7, 30, after=alarm["at"]))
        self.assertEqual([a["id"] for a in self.alarms()], [skipped["id"]])
        self.assertEqual(self.timers(), [f"nag-{skipped['id']}.timer"])

    def test_skip_refuses_a_one_shot(self):
        self.assertFalse(self.nag("skip", self.set("5m tea")["id"])["ok"])

    def test_cancel_removes_the_series(self):
        self.nag("cancel", self.set("every day 9:00 water")["id"])
        self.assertEqual(self.alarms(), [])

    def test_missed_occurrence_reports_and_moves_on(self):
        alarm_id = self.set("every day 9:00 water")["id"]
        self.reboot()
        self.move_alarm(alarm_id, int(time.time()) - 3 * 86400)
        [alarm] = self.alarms()
        self.assertEqual(alarm["at"], next_at(range(1, 8), 9))
        self.assertEqual(len([n for n in self.notifications() if "Missed: water" in n]), 1)


class EditTest(NagTestCase):
    def test_edit_replaces_the_alarm(self):
        alarm_id = self.set("5m tea")["id"]
        edited = self.nag("edit", alarm_id, "every fri 15:00 tea")
        [alarm] = self.alarms()
        self.assertEqual((alarm["id"], alarm["repeatLabel"]), (edited["id"], "Fri"))
        self.assertEqual(self.timers(), [f"nag-{edited['id']}.timer"])

    def test_edit_that_does_not_parse_keeps_the_alarm(self):
        alarm_id = self.set("5m tea")["id"]
        self.assertFalse(self.nag("edit", alarm_id, "soon tea")["ok"])
        self.assertEqual([a["id"] for a in self.alarms()], [alarm_id])

    def test_edit_a_ringing_alarm_reschedules_it(self):
        alarm_id = self.ring("5m tea")
        self.nag("edit", alarm_id, "10m tea")
        [alarm] = self.alarms()
        self.assertFalse(alarm["ringing"])
        self.assertIn(alarm["remaining"], ("10m", "9m"))


class DemoTest(NagTestCase):
    def test_demo_shows_invented_alarms_and_protects_real_ones(self):
        alarm_id = self.set("5m tea")["id"]
        self.nag("demo", "on")
        self.assertTrue(self.nag("demo")["demo"])
        self.assertEqual(len(self.alarms()), 3)
        self.assertTrue(self.nag("cancel", alarm_id)["demo"])
        self.assertTrue(self.nag("set", "1h call")["demo"])
        self.nag("demo", "off")
        self.assertEqual([a["id"] for a in self.alarms()], [alarm_id])


class AskTest(NagTestCase):
    def test_opens_the_panel_when_there_is_one(self):
        self.assertEqual(self.nag("ask", NAG_SUMMON="ok"), {"ok": True, "opened": "panel"})

    def test_falls_back_to_the_menu_prompt_and_confirms(self):
        result = self.nag("ask", NAG_MENU_INPUT="5m tea")
        self.assertEqual(result["message"], "tea")
        self.assertEqual([a["message"] for a in self.alarms()], ["tea"])
        [notification] = self.notifications()
        self.assertTrue(notification[2].startswith("Tea at "), notification)

    def test_menu_prompt_without_a_time_says_so(self):
        self.assertFalse(self.nag("ask", NAG_MENU_INPUT="tea")["ok"])
        [notification] = self.notifications()
        self.assertEqual(notification[2:4], ["No time in that", "tea"])


if __name__ == "__main__":
    unittest.main()
