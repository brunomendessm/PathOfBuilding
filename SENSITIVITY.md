# Stat Sensitivity Analysis

Status: prototype, dev mode only (`F7`, `Shift+F7` for detail). No UI yet.

## The question it answers

Existing tooling answers "how much is this specific thing worth" — the tree power
report for passives, the compare tab for another build's items, the trade query
generator for craftable mods. None of them answer the question a player actually
asks when a build has many interacting scaling axes:

> I have several things I could scale. Which one should I put my next slot into?

This is acute on stackers and conversion builds, where the same character scales
through attributes, life, energy shield, crit and attack speed at once, and the
interactions make the answer impossible to reason out by hand.

## Why not "rank every mod in the game"

The first shape considered was: enumerate every modifier in the game, measure each
one's effect, sort by the chosen metric. It was rejected before implementation.

The tree power report works because **every passive node costs exactly one point**.
That shared denominator is what makes the ranking meaningful — sorting by gain is
sorting by efficiency.

A global mod ranking has no denominator. It would place a mythic-tier unique
modifier, a support gem that displaces another support gem, and a trivial ring
suffix in one list, sorted by a number that implies they are alternatives. The top
of that list would be dominated by whatever is rarest, which is not advice.

Ranking *axes* instead of *modifiers* sidesteps this: axes are dimensions, not
slots, so they do not compete for the same space, and the question "which
dimension carries this build" is well posed.

## How a measurement is taken

Each measurement injects a modifier into the player's mod database and runs a full
calculation pass, comparing the target metric against the unmodified build.

Injection goes through a new `override.extraMods` handled in `CalcSetup.initEnv`,
alongside the existing `override.conditions`. This deliberately reuses the full
init path via `calcs.getMiscCalculator`.

### Why not the fast calculator

`calcs.getCalculator` builds the environment once and wipes only a delta layer
between passes, which is much cheaper. It is unusable here. Its returned function
does:

```lua
wipeTable(env.modDB.mods)
wipeTable(env.modDB.conditions)
wipeTable(env.modDB.multipliers)
```

Some setup happens only during `initEnv` and lives in those tables. Energy Blade is
the clearest case: `initEnv` detects the skill and re-enters itself with
`AffectedByEnergyBlade` set in `modDB.conditions` (`CalcSetup.lua`), and that
condition is what materialises the weapon (`CalcSetup.lua`, weapon slot handling).
Wiping conditions between passes silently removes the weapon, so every pass after
the first measures a disarmed character.

Observed on the reference build: base pass 17,785,900 DPS, every subsequent pass
about 14,200 — a uniform -99.9% on every axis, including axes that can only
increase damage.

This is latent rather than live: `calcs.getNodeCalculator` uses the fast path and
has no callers, while the tree power report uses `getMiscCalculator`, which
re-inits and is therefore correct.

### Control pass

Because that failure produced plausible-looking numbers rather than an error, every
run begins with a pass that injects nothing and must reproduce the base value. A
divergence above 0.1% prints a warning ahead of the results stating they are not
trustworthy. Any future change that breaks environment reconstruction surfaces as a
warning instead of as a full set of confident, wrong numbers.

## Normalisation

Two axis kinds need different treatment, and neither number alone answers the
question.

**Pool axes** (strength, life, energy shield, …) hold a quantity, so a proportional
change is meaningful. These report **elasticity**: percent change in the metric per
percent change in the stat. It is unitless, so strength and energy shield are
directly comparable.

**Multiplier axes** (increased attack speed, more damage, …) have no pool to
normalise against, so they report the gain from one affix-sized step.

Elasticity answers the structural question — what carries this build. It does not
answer the practical one, because it normalises by what the build already has, and
one percent of a small pool is far cheaper to obtain than one percent of a large
one. So pool axes also report **gain from one real affix**, and the table is ordered
by that.

The two orderings genuinely disagree, which is why both are shown. On the reference
build, energy shield has the higher elasticity (1.87 vs 1.51) while strength wins
decisively per affix (6.37% vs 3.18%).

### Affix sizes come from the mod pool

The per-affix column takes the largest flat roll matching the axis from
`data.itemMods.Explicit`, and the report names the affix each number came from.

This started as assumed values, which was wrong to keep: the assumed size silently
decides the ranking between axes. Two judgement calls remain, both visible in the
output rather than buried:

- Mods with zero spawn weight everywhere are skipped, which excludes essence-only
  mods. They are obtainable, just not by random rolling.
- Hybrid affixes (`+X to Strength and Intelligence`) are excluded by an anchored
  pattern. For a str/int stacker these are plausibly competitive, so this is a
  known gap rather than a settled decision.

## Quantisation

This is the part that required the most iteration, and the part a reviewer should
scrutinise.

Many modifiers scale by integer division. `ModStore` floors it:

```lua
local mult = m_floor(base / (tag.div or 1) + 0.0001)
```

So `+30 to maximum Energy Shield per 100 Reserved Life` pays out in discrete jumps,
only when reserved life crosses a multiple of 100.

A single marginal derivative is meaningless on such an axis: the measured gain
depends entirely on where the sample happens to land relative to the next
threshold, and the sample size is arbitrary.

### Detection

Every run reports the build's stepped scaling sources by scanning the mod database
for `PerStat` tags with a divisor above 1, along with the distance to each next
threshold. That distance is directly actionable — it is the cheapest available gain
on that axis.

### Aligned sampling

Each axis is swept over five sample points rather than measured once, which is what
distinguishes a genuine curve from a staircase. Where an axis is quantised, the
sample points are multiples of its own quantum, so every sample sits the same
distance past a threshold and the marginal yields become comparable.

The quantum is derived two ways:

- **Direct**: the modifier keys off the axis stat itself, so its divisor is already
  in the injected units. Several combine as a least common multiple. Strength has
  `+1 Energy Shield per 10 Strength` and `+1 Mana per 4 Strength`, giving 20.
- **Indirect**: the modifier keys off a stat the axis only moves through a chain.
  Adding maximum life raises life reserved, which is what The Ivory Tower reads. The
  transfer ratio depends on the build's reservations, so it is **measured with a
  probe** rather than assumed, and the effective quantum is `divisor / ratio`.

Effect on the reference build:

| Axis | Before alignment | After |
| --- | --- | --- |
| Life | unreadable staircase | linear |
| Mana | irregular (2.00x spread) | linear |
| Intelligence | irregular (2.57x spread) | clean diminishing return (x0.49) |
| Dexterity | reported as no measurable effect | 0.98% per affix |

The dexterity row is the important one. Its samples had been too small to cross a
single threshold, so the tool was reporting a real axis as irrelevant — a false
negative, which is the worst failure mode for a tool meant to inform decisions.

### Trend classification refuses to guess

Comparing only the first and last sample renders a bouncing sequence as a confident
trend. Classification now requires the marginal yield to move consistently in one
direction, and reports `IRREGULAR` with the observed spread otherwise. A direction
change alone is not enough to reject a trend, since small samples carry rounding
noise; the spread must also exceed 1.25x.

Validated against sequences where the answer is known independently: more-damage
multipliers and flat increased-damage stay monotonic and classify as trends, crit
chance correctly flattens to nothing against a 100% cap, while strength,
intelligence and mana bounced before alignment and were flagged.

## Known limitations

**Engine-level floors are invisible.** Detection only finds quantisation expressed
as a modifier. The calculation engine also floors in places that never reach the mod
database:

- `CalcPerform`: strength's melee bonus is `m_floor(Str / 5)`
- `CalcOffence`: Energy Blade floors the weapon damage it derives from energy shield

The second cannot be aligned away at all. The floor lands on a derived value whose
relationship to the injected stat is fractional, so no choice of sample points fixes
it. Strength on an Energy Blade build stays `IRREGULAR`, and that is the honest
answer rather than a defect. Both are documented in the source so the reported list
of step sources does not read as exhaustive.

**Small samples are noisy.** Quantisation contributes a roughly fixed absolute error,
so it weighs more on smaller injections. On the reference build strength's smallest
sample yields 16,070 per point against about 19–20k for the rest, and that one point
accounts for nearly all its reported spread. Down-weighting small samples would clean
up the trends but would also blind the threshold detection that surfaced dexterity,
so the trade-off is unresolved rather than silently taken.

**Unexplained threshold on dexterity.** +20 and +40 produce exactly zero, +60 produces
179,683, +80 produces the same. Neither listed step source accounts for a jump of
that size, particularly with the build dealing no physical damage. Not diagnosed.

**Multiplier axes are not aligned.** Only pool axes get a quantum, so
`Increased Life` still classifies as irregular — it feeds the same reserved-life
thresholds through a percentage rather than a flat amount.

**Metric is fixed** to `TotalDPS`, so defensive axes cannot be compared.

**The run is synchronous** and blocks the UI for a few seconds. A shippable version
needs a coroutine, as the tree power report does.

**Report strings are in Portuguese**, from prototyping. These need translating before
any upstream submission.

## Cost

Roughly 200 full calculation passes: about 23 axes at five sample points, plus one
affix measurement per pool axis, one probe per indirect quantum, and one control
pass. The tree power report performs comparable work across thousands of nodes, so
the order of magnitude is established; the difference is only that this has no
coroutine yet.

## Validation

Beyond the control pass, three independent checks:

- A 10% `more` multiplier yields exactly +10.00% of the metric, which it must by
  definition.
- Flat increased-damage axes hold to five significant figures across the sweep
  (21,272.4 / 21,274.3 / 21,273.0 / 21,274.2 / 21,273.8 per unit), showing the noise
  on other axes comes from the build rather than from the method.
- Every axis reporting no measurable effect is explainable: dexterity-only physical
  damage on a lightning build, cast speed on an attack build, armour and evasion
  against a damage metric.

The full spec suite passes. `TestTradeQueryCurrency_spec.lua` fails intermittently on
this repo regardless of these changes: `TradeQuery:GetTotalPriceString` iterates
`pairs()` over a hash table despite the variable being named `sorted_price`, so the
order is non-deterministic and the test asserts a fixed one. Reproduced on a clean
`upstream/dev` worktree, passing on one run and failing on the next. Worth a separate
issue, and it also means users see the total price in a non-deterministic order.
