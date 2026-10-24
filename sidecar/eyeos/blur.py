"""Blink-to-unblur: the screen goes soft while you stare without blinking; a full blink clears it, a half blink only
half (screen blur raises blink rate: Crnovrsanin et al., CHI 2014). Pure state; the server decides when it's allowed."""


def ramp(stare_s, start_s, full_s):
    """0 before start_s, 1 from full_s, smoothstep between."""
    if full_s <= start_s:
        return 1.0 if stare_s >= start_s else 0.0
    x = min(1.0, max(0.0, (stare_s - start_s) / (full_s - start_s)))
    return x * x * (3 - 2 * x)


class StareBlur:
    def __init__(self):
        self.level = 0.0
        self.carry = 0.0  # what a half blink left behind, until the next full blink

    def on_dip(self, kind):
        if kind == "blink":
            self.carry = self.level = 0.0
        elif kind == "incomplete":
            self.carry = self.level = self.level * 0.5

    def update(self, stare_s, allowed, start_s, full_s, strength):
        if not allowed:
            self.carry = self.level = 0.0
        else:
            self.level = max(self.carry, strength * ramp(stare_s or 0.0, start_s, full_s))
        return round(self.level, 3)
