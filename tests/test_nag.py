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
    # A timer is a marker file; anything else runs now, like a transient service.
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
if ((timer)); then : >"$NAG_TEST/timers/$unit.timer"; else "${cmd[@]}" >/dev/null 2>&1 & fi
""",
    "systemctl": """
case $2 in
  list-units) [[ -e $NAG_TEST/timers/${@: -1} ]] && echo "${@: -1} loaded active waiting" ;;
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
        for name in ("calls.log", "dbus"):
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
        for proc in self.rings:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
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
        return sorted(os.listdir(os.path.join(self.root, "timers")))

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

    def test_alarm_whose_time_passed_unfired_is_dropped(self):
        alarm_id = self.set("5m tea")["id"]
        with open(self.alarm_file(alarm_id)) as f:
            doc = json.load(f)
        doc["at"] = int(time.time()) - 60
        with open(self.alarm_file(alarm_id), "w") as f:
            json.dump(doc, f)
        self.assertEqual(self.alarms(), [])

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
