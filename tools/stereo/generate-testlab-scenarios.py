"""Generate the testlab failure-case scenarios (testlab/darktide_testlab/touch_*.tsv).

Same format as touch_repeat.tsv: "# grip=touch" (rotations are raw Touch grips),
then one key per line:
    t left_xyz left_xyzw right_xyz right_xyzw primary block left_grip right_grip special
in camera/body-local metres (x right, y forward, z up) and xyzw quaternions.
The replay interpolates linearly between keys, so smooth motion is sampled
every STEP seconds. Every input is released on the final key.

    python tools/stereo/generate-testlab-scenarios.py [--check]

--check verifies the committed files match instead of writing them.
"""
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2] / "testlab" / "darktide_testlab"
HEADER = "# t left_xyz left_xyzw right_xyz right_xyzw primary block left_grip right_grip special"
LEFT = "-0.25 0.3 -0.35 0.70710678 0 0 0.70710678"  # the resting support hand of touch_repeat
RIGHT_Y, RIGHT_Z, RIGHT_Q = 0.45, -0.3, "0 0 0 1"   # touch_repeat's swing plane and grip
SIDE = 0.6       # the right hand swings between x=-0.6 and x=+0.6
SWING = 0.35     # seconds per swing, as touch_repeat
STEP = 0.025     # key spacing along smooth motion
REST = 1.6       # still at the end, so the last attack finishes inside the run


class Track:
    def __init__(self, x):
        self.keys = []
        self.x = x
        self.buttons = {"primary": 0, "block": 0, "left_grip": 0, "right_grip": 0, "special": 0}

    def key(self, t):
        t = round(t, 3)
        if self.keys and t <= self.keys[-1][0]:
            raise ValueError(f"keys must increase: {t}")
        b = self.buttons
        self.keys.append((t, f"{t:.3f} {LEFT} {self.x:.4f} {RIGHT_Y} {RIGHT_Z} {RIGHT_Q} "
                             f"{b['primary']} {b['block']} {b['left_grip']} {b['right_grip']} {b['special']}"))

    def set(self, t, **buttons):
        """Change buttons at t; the hand stays where it is."""
        self.buttons.update(buttons)
        self.key(t)

    def hold(self, t):
        self.key(t)

    def swing(self, t, to):
        """One real-speed swing as touch_repeat: constant speed between two keys."""
        self.key(t)
        self.x = to
        self.key(t + SWING)
        return t + SWING

    def continuous(self, t, swings):
        """Back and forth with no pause at the reversals: x follows a cosine,
        one half period per swing, so the hand only slows to turn."""
        start = self.x
        total = swings * SWING
        steps = int(round(total / STEP))
        for i in range(steps + 1):
            u = i * STEP
            self.x = start * math.cos(math.pi * u / SWING)
            self.key(t + u)
        return t + total

    def text(self, comments):
        lines = ["# grip=touch"] + [f"# {c}" if c else "#" for c in comments] + [HEADER]
        lines += [line for _, line in self.keys]
        return "\n".join(lines) + "\n"


LEFT_Q = "0.70710678 0 0 0.70710678"   # touch_repeat's support grip


def pumping(walk, amplitude, height, hertz, seconds, right_swings=False, lead=0.5):
    """Arm-pump jogging (VR StrideS): both hands swing forward and back,
    opposite each other, at the sides, after `lead` seconds standing still
    (walking starts from standing; a run that starts mid-motion can leave the
    stroke detector settling). right_swings: the left hand rests and the right
    hand makes touch_repeat's real swings instead."""
    lines = []
    t = 0.0
    omega = 2 * math.pi * hertz
    swing_t = [0.6 + 1.5 * i for i in range(4)] if right_swings else []
    while t <= seconds + 1e-9:
        if right_swings:
            lx, ly, lz = -0.25, 0.3, -0.35
            x = -SIDE
            for i, start in enumerate(swing_t):
                a, b = (-SIDE, SIDE) if i % 2 == 0 else (SIDE, -SIDE)
                if t >= start + SWING:
                    x = b
                elif t >= start:
                    x = a + (b - a) * (t - start) / SWING
                    break
                else:
                    break
            rx, ry, rz = x, RIGHT_Y, RIGHT_Z
        else:
            phase = math.sin(omega * (t - lead)) if t > lead else 0.0
            rx, ry, rz = 0.25, 0.3 + amplitude * phase, -0.4 + height * phase
            lx, ly, lz = -0.25, 0.3 - amplitude * phase, -0.4 - height * phase
        lines.append(f"{t:.3f} {lx:.4f} {ly:.4f} {lz:.4f} {LEFT_Q} {rx:.4f} {ry:.4f} {rz:.4f} {RIGHT_Q} 0 0 0 0 0")
        t = round(t + STEP, 3)
    end = round(t - STEP, 3)
    lines.append(f"{end + REST:.3f} " + lines[-1].split(" ", 1)[1])
    head = ["# grip=touch"] + ([f"# walk={walk}"] if walk else [])
    return head, lines


def continuous(lead):
    track = Track(-SIDE)
    track.hold(0.0)
    end = track.continuous(lead, 8)
    track.hold(end + REST)
    return track


def scenarios():
    out = {}

    track = continuous(0.35)
    out["touch_continuous.tsv"] = track.text([
        "Eight swings back and forth with no pause at the reversals, after the 0.35 s rest",
        "touch_repeat starts with: the right hand runs x=-0.6..+0.6 m as a cosine, 0.35 s per",
        "swing (peak 5.4 m/s), so it is below the 0.35 m/s stroke stop speed for only ~15 ms",
        "at each turn. touch_repeat (1.15 s still between the same swings) is the control.",
        "Run:  run touch_continuous.tsv auto gesture       (contact presses, the mission default)",
        "      run touch_continuous.tsv auto gesture-swing (a press on every stroke)",
        "      a duration_scale of 1.5 gives 0.525 s swings. damage_summary: presses vs attacks",
        "vs attacks_damaged; damage_press rows name each dropped or empty press.",
    ])

    track = continuous(0.1)
    out["touch_switch_continuous.tsv"] = track.text([
        "touch_continuous started straight after a weapon switch, swinging from 0.1 s.",
        "A run cannot switch weapons (it aborts on any wielded-slot change), so switch first",
        "and start the run at once, as live tracking restarts its runtime on the switch back:",
        "  send-testlab-command.ps1 -Command wield -Arguments secondary  (wait for wield_complete)",
        "  send-testlab-command.ps1 -Command wield -Arguments primary",
        "  send-testlab-command.ps1 -Command run -Arguments 'touch_switch_continuous.tsv auto gesture'",
        "The run starts ~0.1-0.3 s after the wield press, inside the melee draw. If run answers",
        "'wield melee weapon before running', the slot had not changed yet: send run again.",
        "Compare its damage_summary with touch_continuous.",
    ])

    track = Track(-SIDE)
    track.hold(0.0)
    t = 0.5
    for i, to in enumerate((SIDE, -SIDE, SIDE)):
        track.set(t, primary=1)            # trigger down: the charge starts, hand still
        track.swing(t + 1.0, to)           # charged; the swing releases the heavy
        track.set(t + 1.6, primary=0)      # trigger up after the swing
        t += 3.0
    track.hold(t - 3.0 + 1.6 + REST)
    out["touch_heavy_release.tsv"] = track.text([
        "Three heavies: the trigger held 1.0 s to charge with the hand still, then a real-speed",
        "swing (alternating sides) while it is still held releases the heavy; the trigger is",
        "let go 0.25 s after the swing. 3.0 s per cycle.",
        "Run in gesture-heavy: only there is the trigger the heavy charge, as it always is in",
        "live tracking (plain gesture reads it as push follow-up intent only).",
        "  run touch_heavy_release.tsv auto gesture-heavy",
        "The trigger is the attack button (22 October): held past the swing it charges again,",
        "and the let-go 0.25 s later fires that charge too, so a cycle may add a second press.",
        "Expect every press answered (presses_no_attack=0) and 3 damaging heavy attacks.",
    ])

    track = Track(-SIDE)
    track.hold(0.0)
    t = 0.5
    for held in (0.25, 0.8, 1.6):
        track.set(t, primary=1)
        track.set(t + held, primary=0)     # let go without any swing
        t += held + 1.5
    t = track.swing(t, SIDE) + 1.5          # then ordinary swings: does attacking still work?
    t = track.swing(t, -SIDE)
    track.hold(t + REST)
    out["touch_trigger_release.tsv"] = track.text([
        "The trigger held 0.25 s, 0.8 s and 1.6 s with the hand still, each let go without a",
        "swing, 1.5 s apart; then two ordinary swings without the trigger, to show whether",
        "attacking still works after them.",
        "  run touch_trigger_release.tsv auto gesture-heavy",
        "Stock route (the trigger is the attack button, 22 October): each let-go fires the",
        "charge in place (a tap a light, a hold a heavy): expect presses_no_attack=0 and the two",
        "swings still damaging (fewer is a lockout). Physical route: each let-go cancels,",
        "expect cancelled=3 cancelled_attacked=0 (an attack after a cancel is a leak).",
    ])

    track = Track(-SIDE)
    track.hold(0.0)
    track.hold(0.4)
    track.set(0.4 + 0.001, special=1)
    track.set(0.5, special=0)
    end = track.continuous(0.8, 8)
    track.hold(end + REST)
    out["touch_special_continuous.tsv"] = track.text([
        "The weapon special pressed for 0.1 s at 0.4 s (rev, activation, special attack or bash,",
        "whatever the weapon's special is), then touch_continuous's eight swings with no pause",
        "at the reversals from 0.8 s.",
        "  run touch_special_continuous.tsv auto gesture",
        "Compare its damage_summary with touch_continuous; damage_attack rows show whether the",
        "special started a native attack of its own (press_kind=special).",
    ])
    def stride(name, walk, amplitude, height, hertz, comments, right_swings=False):
        head, lines = pumping(walk, amplitude, height, hertz, 6.0, right_swings)
        out[name] = "\n".join(head + [f"# {c}" if c else "#" for c in comments] + [HEADER] + lines) + "\n"

    peak = 2 * math.pi * 1.4 * math.hypot(0.2, 0.08)
    stride("touch_stride_jog.tsv", 1.6, 0.2, 0.08, 1.4, [
        "Arm-pump jogging while walking at 1.6 m/s (VR StrideS; user, 23 October: a jog read",
        f"as slow swings): both hands swing forward and back, opposite, 1.4 Hz, peak {peak:.1f} m/s.",
        "Expect stroke_filtered rows (reason=stride) and no presses: a stride is not an attack.",
        "  run touch_stride_jog.tsv auto gesture",
    ])
    stride("touch_stride_pump_still.tsv", 0, 0.2, 0.08, 1.4, [
        "touch_stride_jog's arm pumps standing still: the control. Not walking, the stride",
        "filter does not apply; presses here show the jog motion would otherwise attack.",
        "  run touch_stride_pump_still.tsv auto gesture",
    ])
    stride("touch_stride_swing.tsv", 1.6, 0, 0, 1, [
        "Real swings while walking at 1.6 m/s: the left hand rests, the right hand makes four of",
        "touch_repeat's swings (3.4 m/s), 1.5 s apart. Expect every swing pressed and damaging.",
        "  run touch_stride_swing.tsv auto gesture",
    ], right_swings=True)
    hard = 2 * math.pi * 1.8 * math.hypot(0.3, 0.1)
    stride("touch_stride_hard.tsv", 1.6, 0.3, 0.1, 1.8, [
        "Hard arm pumps while walking at 1.6 m/s: opposite hands as touch_stride_jog but 1.8 Hz",
        f"and wider, peak {hard:.1f} m/s, above the 2.5 m/s stride limit (user: sometimes you swing",
        "hard while walking). Expect presses: a fast swing always attacks.",
        "  run touch_stride_hard.tsv auto gesture",
    ])

    # Swings while the character really moves (user, 24 October: worn swings
    # registered 85% standing, 57-65% running). touch_continuous's eight swings
    # from 0.35 s; each "# move=" line drives the stock move inputs.
    def moving(name, segments, comments):
        track = continuous(0.35)
        moves = [f"move={f:g},{r:g},{a:.3f},{b:.3f}" + (",sprint" if s else "") for f, r, a, b, s in segments]
        out[name] = track.text(moves + comments)

    end = 0.35 + 8 * SWING
    moving("touch_move_walk.tsv", [(0.5, 0, 0.35, end, False)], [
        "touch_continuous walking forward at half stick (a far target, 4 m, comes into reach).",
        "  step: touch_move_walk.tsv|far-anchored|gesture|auto|<name>",
    ])
    moving("touch_move_run.tsv", [(1, 0, 0.35, end, False)], [
        "touch_continuous running forward at full stick toward a far target (4 m).",
        "  step: touch_move_run.tsv|far-anchored|gesture|auto|<name>",
    ])
    moving("touch_move_sprint.tsv", [(1, 0, 0.35, end, True)], [
        "touch_continuous sprinting forward toward a far target (4 m).",
        "  step: touch_move_sprint.tsv|far-anchored|gesture|auto|<name>",
    ])
    third = 0.35 + 8 * SWING / 3
    moving("touch_move_strafe.tsv", [(0, 0.7, 0.35, third, False), (0, -0.7, third, 0.35 + 16 * SWING / 3, False),
                                     (0, 0.7, 0.35 + 16 * SWING / 3, end, False)], [
        "touch_continuous strafing right, left, right at 0.7 stick across a target 1.5 m ahead.",
        "  step: touch_move_strafe.tsv|single-anchored|gesture|auto|<name>",
    ])
    moving("touch_move_back.tsv", [(-0.6, 0, 0.35, end, False)], [
        "touch_continuous backing away at 0.6 stick from a close target (0.9 m).",
        "  step: touch_move_back.tsv|close-anchored|gesture|auto|<name>",
    ])
    return out


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for name, text in scenarios().items():
        path = ROOT / name
        if check:
            current = path.read_text(encoding="utf-8").replace("\r\n", "\n") if path.exists() else None
            if current != text:
                stale.append(name)
        else:
            path.write_text(text, encoding="utf-8", newline="\n")
            keys = sum(1 for line in text.splitlines() if not line.startswith("#"))
            print(f"wrote {path.relative_to(ROOT.parents[1])} keys={keys} seconds={text.splitlines()[-1].split()[0]}")
    if stale:
        print("stale: " + ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
