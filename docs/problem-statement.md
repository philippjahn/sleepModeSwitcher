# Problem statement: SleepModeSwitcher

Result of a problem-grill session (Empathise → Define), 2026-11-04/05.
No solution work yet: this captures the problem, its evidence status, and what to check next.

## Target

- An **AI engineer** at our company who runs **Claude Code / agent sessions of 20–90 min** locally on a
  self-administered Apple Silicon MacBook.
- **Moment:** a meeting starts or it is time to commute, mid-run. The MacBook goes into the bag: lid closed,
  on battery, no external display.

## Customer insight

> *"I carry my MacBook half-open to meetings because, with deadlines tight, I can't afford to come back to a
> stalled agent, and since tools like caffeinate silently failed me, I only trust what I can see is still
> running and connected."*

## Evidence status

- **Validated:** one colleague asked for the app and was let down by `caffeinate`. Plus the builder's own
  experience (n = 1 + self).
- **Hypothesis (assumed, not heard from end-users):**
  - the half-open-laptop habit
  - time pressure as the main driver
  - that losing Wi-Fi really stops runs in practice
  - how often it happens
  - that more than one colleague has the problem
  - that wasted tokens from restarted runs are a real cost

## Alternative

- **`caffeinate`:** looks like it works but does not override lid-close sleep. The failure is found out only
  after coming back, and trust is gone.
- **Half-open laptop:** awkward, exposed, drains battery, does not fit in a bag.
- **Amphetamine-type apps, remote/cloud agents:** not tried by the colleague.
- **Dedicated lid-closed tools already exist.** See [Competitor scan](#competitor-scan).

## Competitor scan

**Important:** several tools may already solve the core problem. Before building more, check whether they do
and where a real gap is left. Findings come from the products' own READMEs and store pages, gathered
2026-11-05, and are **not yet verified hands-on**.

| Tool | Mechanism | Notable claims | Relevance |
|---|---|---|---|
| [StayAwake](https://github.com/TY-teo/StayAwake) | `pmset -a disablesleep 1` via privileged helper, SwiftUI | Explicitly targets Claude Code / Codex / Cursor runs with the lid closed | **Direct competitor, same target** |
| [LidAwake](https://github.com/TurboKach/LidAwake) | `pmset disablesleep`, menu bar | Aimed at Claude Code / Codex terminal jobs. Live status line, blanks internal screen, notarized, Sparkle updates | **Direct competitor, same target** |
| [Puer](https://github.com/startsevdev/puer) | `pmset -a disablesleep`, daemon | Mentions AI agents. Delay timer clears the flag | Direct competitor |
| [Sleepless](https://github.com/Aboudjem/Sleepless) ([site](https://aboudjem.github.io/Sleepless/)) | `pmset -a disablesleep 1`, MIT | Auto-off timer, battery-floor cutoff, reverts on reboot / Low Power Mode | Direct competitor; similar safety features to ours |
| [Coffee](https://awesome.ecosyste.ms/projects/github.com%2Fpehqge%2Fcoffee), [KeepAwake](https://github.com/Abhinav-ranish/KeepAwake), [Awake](https://github.com/yatindma/Awake) | `pmset disablesleep` toggles | One-click menu bar toggles | Simpler equivalents |
| [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) | Closed-Display Mode (+ script since 5.3) | Most established. Reported unreliable on Apple Silicon when the power source changes | Indirect; credibility gap on battery |
| `caffeinate`, KeepingYouAwake | Power assertions | Cannot override lid-close sleep | Not a solution (confirmed by the colleague's experience) |

**What this means for the problem:**

- The **"stay awake with the lid closed"** part is **largely solved** by free, open-source tools, some of them
  explicitly marketed at the same AI-agent target.
- **Possible remaining gap (hypothesis):** none of the tools scanned mention
  **network/Wi-Fi survival** (warning before you leave the connected network) or **temperature-based auto-off**.
  Those match the "certainty: awake **and** connected" part of the insight. Verify by installing the top 3
  (StayAwake, LidAwake, Sleepless).
- **Superiority is therefore unproven.** The exit test passed on the insight, but against these competitors
  superiority now depends on the connectivity / certainty layer, not on keeping the Mac awake.
- **Discoverability question:** if these tools exist, why didn't the colleague find them? (Not searched?
  Didn't trust unsigned tools? Didn't know the problem had a solution?) That is itself an insight to check.

## Root cause

- **Symptom:** the agent stalls while the engineer is away.
- **Root cause:** the failure is **invisible at the moment of leaving**. Nothing tells them whether the run
  will survive (Mac awake + network connected), so they check by eye with the half-open laptop.

## Relevant parties and constraints

- **Decider:** the engineer alone. They have admin rights on their own Mac, so there is no IT gate.
- **Manager:** benefits from the throughput but has no say.
- **Constraints:**
  - heat and battery in a closed bag
  - theft risk of an awake Mac
  - passwordless sudoers entry needed for `pmset`
- **In scope:** short absences (15 min–2 h), lid closed, on battery, self-administered Apple Silicon MacBook.
  The question to answer is "is it alive + connected".
- **Out of scope:** overnight / multi-hour runs, cloud/remote agents, IT-managed fleets, Intel/Windows,
  monitoring whether the agent's task itself succeeds.

## Value

- **Engineer:**
  - meetings and commutes become agent time
  - no more carrying the laptop half-open
  - peace of mind instead of checking
  - fewer "came back to nothing" moments under deadline
- **Organisation:**
  - more output per engineer hour
  - fewer wasted runs and tokens (hypothesis)
  - shows the team's AI-tooling skill
- **Planet:** marginal. Fewer restarted runs save a little compute; an awake Mac in a bag uses battery.

## How might we…

1. …give engineers certainty, at the moment they close the lid, that their agent run will survive the walk to
   the meeting?
2. …warn them before they leave that the network will drop and stop the agent?
3. …make "still running" visible without the laptop being open?

## Open questions (to check with end-users)

- Ask the colleague: *"Tell me about the last time you left while an agent was running. What did you do?"*
  Ask about past behaviour, not hypotheticals.
- Does anyone mention time pressure on their own, without being prompted?
- How often does it happen per week, and how many AI engineers have it? Observe 3–5 for a week.
- Is losing Wi-Fi a real cause of stopped runs, or only a theoretical one?
- How worried are they about heat, battery and theft with the lid closed in a bag?
- **Competitors:**
  - Did the colleague know about StayAwake / LidAwake / Sleepless?
  - If shown them, would they still want ours, and why?
  - Install the top 3 and check whether they cover Wi-Fi warning and thermal auto-off.
