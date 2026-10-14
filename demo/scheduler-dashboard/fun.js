"use strict";

// "Customer impact": a light-hearted panel for the hackathon demo. It polls
// the same metrics endpoints as dashboard.js on its own, so the two files
// stay independent.
(() => {
  const root = document.getElementById("fun");
  if (!root) return;

  const SIDES = [
    { key: "current", name: "Current", url: "/current/scheduler/metrics", color: "var(--current)" },
    { key: "central", name: "Central", url: "/central/scheduler/metrics", color: "var(--central)" },
  ];
  const POLL_MS = 1000;
  const DOLLARS_PER_VCPU_MINUTE = 0.002;
  const MAX_GAP_SECONDS = 600; // longer server-clock gaps (restart, clock jump) are skipped
  const ANGRY_SHARE = 0.2;
  const MOODS = {
    happy: { emoji: "😀", label: "happy" },
    meh: { emoji: "😐", label: "meh" },
    angry: { emoji: "😡", label: "angry" },
  };
  const TWEET_KEEP = 8;
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

  // Fictional tweets are [handle, text] on made-up handles. Real tweets are
  // quoted verbatim as objects marked `real: true`, and get a "Real tweet"
  // badge in the feed.
  const TWEETS = {
    happy: [
      ["@ci_goblin", "Pushed, reached for my coffee, and CI was green before the mug left the counter. Ubicloud runners have ruined my break schedule."],
      ["@yaml_whisperer", "My workflow file is still cursed, but at least the runner picked it up instantly."],
      ["@flaky_test_fairy", "Runner came up so fast my flaky test didn't have time to get nervous. All green."],
      ["@rebase_raccoon", "Rebased, pushed, merged. The runner was waiting for ME. Role reversal."],
      ["@pipeline_possum", "Queue time: 3 seconds. I blinked and missed it."],
      ["@green_check_gremlin", "Collecting green checkmarks like trading cards today."],
      ["@lint_lord", "The linter yelled at me in record time. Fast feedback, even when it hurts."],
      ["@semver_sloth", "Even I, a sloth, can't keep up with how fast these runners start."],
      ["@cache_miss_moth", "Cache miss, cold start, still done before standup ended. Who even am I."],
      ["@monorepo_moose", "Our 40-job matrix fanned out instantly. I swear I heard the runners cheer."],
      ["@hotfix_hedgehog", "Hotfix shipped in 4 minutes flat. The incident channel barely had time to get dramatic."],
      ["@docker_dumpling", "Image built, tests passed, PR merged. My tea is still too hot to drink."],
      ["@commit_crab", "Runner picked up my job sideways-fast. Respect, from one crab to another."],
      ["@null_pointer_pal", "No waiting, no flakes, no drama. Is this what peace feels like?"],
      ["@devops_dingo", "Told the team CI takes 20 minutes. It took 3. Now they think I lie."],
      ["@kernel_kiwi", "Ubicloud runner booted faster than my laptop wakes from sleep."],
      ["@artifact_otter", "Uploaded artifacts, holding paws with my green build. Lovely day."],
      ["@tabs_not_spaces", "Finally something in this repo that's fast AND uncontroversial."],
      ["@cron_job_crow", "Nightly build ran at night. On time. Groundbreaking."],
      ["@runner_rabbit", "Queued at 9:00:00, running at 9:00:02. I can live with that."],
      ["@segfault_squid", "My code crashed instantly, which means the runner started instantly. Silver linings."],
      ["@merge_queue_mole", "Merge queue moving like a well-oiled conveyor belt today."],
      ["@standup_skipper", "CI finished before my turn at standup. Got to say 'merged' instead of 'waiting on CI'."],
      ["@sudo_sandwich", "sudo make me a green build. Done. Instantly."],
      ["@diff_dragon", "Big diff, tiny wait. The dream."],
      ["@branch_badger", "30-vCPU runner, zero queue. My compile flew."],
      ["@ci_goblin", "Pushed a typo fix and got a green check before I could regret the commit message."],
      ["@yaml_whisperer", "Indentation right on the first try AND an instant runner. Buying a lottery ticket."],
      ["@webhook_wombat", "Webhook fired, runner appeared, job done. Like magic, but with logs."],
      ["@test_matrix_tapir", "Ran the full matrix on every runner size we have. Still home for dinner."],
      ["@deploy_duckling", "Friday deploy. CI was so fast I didn't even have time to get scared."],
      ["@pr_pelican", "Reviewer approved, CI already green. Merged within the same sip of coffee."],
      ["@green_check_gremlin", "Refreshing the PR page out of habit. No need. It's already green."],
      ["@bisect_beaver", "Bisected 12 commits, each CI run under a minute. Found the bug before lunch."],
      {
        real: true, name: "J🫪E", handle: "@0x_Osprey", replyTo: "@altanBLN",
        text: "Currently using GitHub Actions + Ubicloud which is the most economical for my (relatively) small workloads but will be evaluating weekly over the next month or two and come back if I change my mind",
      },
      {
        real: true, name: "Caleb LeNoir", handle: "@caleblenoir", replyTo: "@janwilmake",
        text: "We just switched our runners to ubicloud and it cut our costs by about 90% without having to make any other changes. Pipelines are running more quickly too.",
      },
    ],
    meh: [
      ["@semver_sloth", "Runner took a minute and a bit. Enough time to read one more forum thread."],
      ["@pipeline_possum", "CI is 'thinking about it'. Same, CI. Same."],
      ["@flaky_test_fairy", "Waiting on a runner. Using the time to rename variables I'll rename back later."],
      ["@lint_lord", "Queue's a little slow today. Refilled my water bottle like a responsible adult."],
      ["@cache_miss_moth", "Job queued 90 seconds. Not mad, just staring at the spinner."],
      ["@rebase_raccoon", "Runner's coming, probably. I'll rebase again in the meantime, for fun."],
      ["@docker_dumpling", "Spinner, spinner on the wall, when will my runner start at all."],
      ["@kernel_kiwi", "Long enough wait to check the weather. Short enough to not need a jacket."],
      ["@commit_crab", "My job is queued. I am queued. We are all queued."],
      ["@monorepo_moose", "Half the matrix is running, half is waiting. Schrödinger's build."],
      ["@null_pointer_pal", "Status: queued. Mood: politely tapping foot."],
      ["@devops_dingo", "Two minutes to get a runner. Not great, not terrible."],
      ["@tabs_not_spaces", "While I wait for CI, a gentle reminder that tabs are correct."],
      ["@hotfix_hedgehog", "Waiting on CI for a one-line hotfix. It's a very important line."],
      ["@cron_job_crow", "Queue is a bit busy. Big launch day for somebody, apparently."],
      ["@artifact_otter", "Runner's on its way. Using the time to write a commit message with actual words."],
      ["@runner_rabbit", "Queued long enough that I started a second branch. Now I have two problems."],
      ["@yaml_whisperer", "Watching 'Waiting for a runner' like it's a cooking show."],
      ["@ci_goblin", "CI's taking a minute. Opened my editor, closed it, opened it again."],
      ["@merge_queue_mole", "Merge queue moving at the speed of a polite crowd leaving a theater."],
      ["@standup_skipper", "My build is 'queued'. Telling standup it's 'in progress'. Technically true."],
      ["@segfault_squid", "Runner wait long enough to make toast. Not long enough to butter it."],
      ["@diff_dragon", "Slightly slow queue. Good time to re-read my own diff and find two typos."],
      ["@branch_badger", "Big runners take a bit longer to show up. Fair. Big things are slow."],
      ["@webhook_wombat", "Queued. Doing breathing exercises. In for 4, out for 'please start'."],
      ["@deploy_duckling", "CI is fine. I'm fine. Everything is a reasonable amount of fine."],
      ["@test_matrix_tapir", "Matrix half done. Like a crossword I'm not allowed to finish."],
      ["@pr_pelican", "Reviewer is waiting on CI, CI is waiting on a runner, I'm waiting on lunch."],
      ["@bisect_beaver", "Bisecting slowly today. The bug isn't going anywhere, and neither am I."],
      ["@sudo_sandwich", "Queue's a little long. Sandwich it is."],
      ["@green_check_gremlin", "Yellow dot. Not red. Not green. Just vibes."],
      ["@kernel_kiwi", "Runner pending. Cleaning up my desktop icons for the first time since spring."],
      ["@lint_lord", "Took a while, but it ran. Lowered my expectations and met them exactly."],
    ],
    angry: [
      ["@flaky_test_fairy", "Waited so long for a runner that my PR went stale and someone else fixed the bug."],
      ["@ci_goblin", "Coffee brewed, poured, drunk and regretted. Job still queued."],
      ["@yaml_whisperer", "Rewrote this YAML three times while waiting. Now it's worse and still queued."],
      ["@rebase_raccoon", "By the time my runner started, main had moved 40 commits. Rebasing. Again."],
      ["@pipeline_possum", "Playing dead until my job leaves the queue. Might be a while."],
      ["@semver_sloth", "Even I think this queue is slow. Let that sink in."],
      ["@monorepo_moose", "One job of my matrix finished. The other 39 are 'waiting for a runner'. Send help."],
      ["@hotfix_hedgehog", "Hotfix waiting on CI longer than the outage it's fixing."],
      ["@devops_dingo", "Queue time is now longer than my build time. Something is upside down."],
      ["@docker_dumpling", "Started a sourdough starter while waiting for CI. It's rising faster than my runner."],
      ["@lint_lord", "Queued so long the linter rules changed underneath me."],
      ["@null_pointer_pal", "My runner is a null pointer. It points to nothing. Forever."],
      ["@cache_miss_moth", "10 minutes waiting for a 30-vCPU runner while small jobs cut in line. Rude."],
      ["@kernel_kiwi", "Dear Ubicloud, I could have compiled this on my laptop. Twice. With the fan screaming."],
      ["@commit_crab", "Pinched the refresh button so many times it filed a complaint."],
      ["@tabs_not_spaces", "CI is queued. My patience has been converted to spaces."],
      ["@cron_job_crow", "Nightly build finished the next afternoon. Calling it a 'daily' now."],
      ["@artifact_otter", "My artifacts expired before my job even started."],
      ["@runner_rabbit", "Where is my runner. It's been so long I've started naming the spinner."],
      ["@segfault_squid", "Queued so long my test fixtures need updating for the new year."],
      ["@merge_queue_mole", "Merge queue is now a merge museum. Exhibits from this morning on display."],
      ["@standup_skipper", "Said 'waiting on CI' at standup. Then at the next standup. Same build."],
      ["@diff_dragon", "Breathing fire at a yellow dot. It remains yellow."],
      ["@branch_badger", "My 30-vCPU job is starving while 2-vCPU jobs zoom past. I'd like to speak to the scheduler."],
      ["@webhook_wombat", "The webhook arrived. The runner did not. Long-distance relationship."],
      ["@deploy_duckling", "Wanted to deploy before the weekend. CI said: what weekend?"],
      ["@test_matrix_tapir", "Matrix build queued so long I've memorized every job name in it."],
      ["@pr_pelican", "Reviewer approved, went on vacation, came back. Still waiting on CI."],
      ["@bisect_beaver", "Bisect needs 7 runs. At this queue speed I'll find the bug next quarter."],
      ["@sudo_sandwich", "sudo start my runner. Permission denied by the laws of physics, apparently."],
      ["@green_check_gremlin", "I was promised green checks. I have received an hourglass."],
      ["@ci_goblin", "My PR has waited so long it's developing merge conflicts out of boredom."],
      ["@yaml_whisperer", "Whispered sweet nothings to the queue. It did not listen."],
      {
        real: true, name: "Conner Swann", handle: "@YourBuddyConner",
        text: "Ubicloud? More like \"Ubetter have another cloud provider on standby\"",
      },
    ],
  };

  for (const mood of Object.keys(TWEETS)) {
    TWEETS[mood] = TWEETS[mood].map((t) => (Array.isArray(t) ? { handle: t[0], text: t[1] } : t));
  }

  // ---------------------------------------------------------------- dom

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function who(side) {
    const w = el("span", "fun-who");
    const key = el("i");
    key.style.background = side.color;
    w.append(key, side.name);
    return w;
  }

  root.replaceChildren();
  const head = el("div", "card-head");
  head.append(el("h2", null, "Customer impact"));
  const grid = el("div", "fun-grid");
  root.append(head, grid);

  const moneyPanel = el("div", "fun-panel");
  const moodPanel = el("div", "fun-panel");
  const tweetPanel = el("div", "fun-panel fun-tweets");
  grid.append(moneyPanel, moodPanel, tweetPanel);

  moneyPanel.append(el("h4", null, "Money made"));
  const moneyPair = el("div", "fun-pair");
  moneyPanel.append(moneyPair);

  moodPanel.append(el("h4", null, "Customer mood"));
  const moodPair = el("div", "fun-pair");
  moodPanel.append(moodPair);

  tweetPanel.append(el("h4", null, "Customer chatter"));
  const feedPair = el("div", "fun-pair");
  tweetPanel.append(feedPair);

  const view = {};
  for (const side of SIDES) {
    const money = el("div", "fun-side");
    const rate = el("span", "fun-rate", "—");
    const total = el("span", "fun-total", "—");
    money.append(who(side), total, rate);
    moneyPair.append(money);

    const mood = el("div", "fun-side");
    const big = el("span", "fun-big", MOODS.happy.emoji);
    big.setAttribute("role", "img");
    const top = el("div", "fun-mood-top");
    top.append(big);
    mood.append(who(side), top);
    moodPair.append(mood);

    const chatter = el("div", "fun-side");
    const feed = el("ol", "fun-feed");
    feed.setAttribute("aria-label", `Customer tweets about ${side.name}`);
    chatter.append(who(side), feed);
    feedPair.append(chatter);

    view[side.key] = { rate, total, big, feed };
  }

  // ---------------------------------------------------------------- state

  const state = {};
  for (const side of SIDES) {
    state[side.key] = {
      lastGen: null, // server clock (ms) of the last sample
      lastRate: 0, // $/min at the last sample
      total: 0, // dollars integrated up to lastGen
      // Displayed total eases from `from` to `to` over one poll interval.
      anim: { from: 0, to: 0, start: 0, dur: POLL_MS },
      mix: { happy: 0, meh: 0, angry: 0 },
      ok: false,
    };
  }

  // ---------------------------------------------------------------- money

  const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
  const fmtUsd = (v) => usd.format(v);

  function updateMoney(key, m, now) {
    const s = state[key];
    const gen = Date.parse(m.generated_at);
    const rate = (Number(m.fleet?.vcpus_used) || 0) * DOLLARS_PER_VCPU_MINUTE;
    if (Number.isFinite(gen)) {
      if (s.lastGen != null) {
        const dt = (gen - s.lastGen) / 1000;
        // Trapezoid between the two samples, in server seconds, so a mock
        // running faster than real time still earns the right amount.
        if (dt > 0 && dt <= MAX_GAP_SECONDS) s.total += ((s.lastRate + rate) / 2) * (dt / 60);
      }
      s.lastGen = gen;
    }
    s.lastRate = rate;
    s.anim = { from: displayed(s, now), to: s.total, start: now, dur: POLL_MS };
    view[key].rate.textContent = `${fmtUsd(rate)} / min`;
  }

  function displayed(s, now) {
    const a = s.anim;
    if (reducedMotion.matches) return a.to;
    const f = Math.min(1, Math.max(0, (now - a.start) / a.dur));
    return a.from + (a.to - a.from) * f;
  }

  function renderMoney(now) {
    for (const side of SIDES) {
      const s = state[side.key];
      view[side.key].total.textContent = s.ok || s.total ? fmtUsd(displayed(s, now)) : "—";
    }
  }

  function frame() {
    renderMoney(performance.now());
    if (!reducedMotion.matches) requestAnimationFrame(frame);
  }

  // ---------------------------------------------------------------- mood

  // Bucket bounds are [10, 30, 60, 120, 300, 600, 1800, 3600, null].
  function moodMix(m) {
    const counts = m.waiting?.age_histogram?.counts;
    const mix = { happy: 0, meh: 0, angry: 0 };
    if (!Array.isArray(counts)) return mix;
    counts.forEach((n, i) => {
      n = Number(n) || 0;
      if (i <= 2) mix.happy += n;
      else if (i === 3) mix.meh += n;
      else mix.angry += n;
    });
    return mix;
  }

  function overall(mix) {
    const total = mix.happy + mix.meh + mix.angry;
    if (!total) return "happy";
    if (mix.angry / total > ANGRY_SHARE) return "angry";
    return ["happy", "meh", "angry"].reduce((best, k) => (mix[k] > mix[best] ? k : best), "happy");
  }

  function renderMood(key) {
    const s = state[key];
    const v = view[key];
    const mood = overall(s.mix);
    v.big.textContent = MOODS[mood].emoji;
    v.big.setAttribute("aria-label", `Customers are ${MOODS[mood].label}`);
  }

  // ---------------------------------------------------------------- tweets

  // A tweet for one side, picked by that side's current mood mix.
  function pickTweet(key) {
    const feed = view[key].feed;
    const mix = state[key].mix;
    const total = mix.happy + mix.meh + mix.angry;
    const w = total ? mix : { happy: 1, meh: 0, angry: 0 };
    let r = Math.random() * (w.happy + w.meh + w.angry);
    let mood = "happy";
    for (const k of ["happy", "meh", "angry"]) {
      if ((r -= w[k]) < 0) {
        mood = k;
        break;
      }
    }
    const shown = new Set([...feed.children].map((li) => li.dataset.text));
    const pool = TWEETS[mood].filter((t) => !shown.has(t.text));
    const list = pool.length ? pool : TWEETS[mood];
    return { mood, tweet: list[Math.floor(Math.random() * list.length)] };
  }

  function addTweet(key) {
    const feed = view[key].feed;
    if (state[key].ok) {
      const { mood, tweet } = pickTweet(key);
      const li = el("li", `fun-tweet mood-${mood}`);
      li.dataset.text = tweet.text;
      const face = el("span", "fun-tweet-face", MOODS[mood].emoji);
      face.setAttribute("aria-hidden", "true");
      const body = el("div");
      const by = el("div", "fun-tweet-by");
      if (tweet.real) {
        li.classList.add("real");
        by.append(el("b", null, tweet.name), el("span", null, tweet.handle), el("span", "fun-real", "Real tweet"));
        if (tweet.replyTo) by.append(el("span", "fun-reply", `replying to ${tweet.replyTo}`));
      } else {
        by.append(el("b", null, tweet.handle));
      }
      body.append(by, el("p", null, tweet.text));
      li.append(face, body);
      feed.prepend(li);
      while (feed.children.length > TWEET_KEEP) feed.lastElementChild.remove();
    }
    setTimeout(() => addTweet(key), 2000 + Math.random() * 1000);
  }

  // ---------------------------------------------------------------- poll

  async function poll(side) {
    try {
      const r = await fetch(side.url, { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const m = await r.json();
      const now = performance.now();
      const s = state[side.key];
      s.ok = true;
      updateMoney(side.key, m, now);
      s.mix = moodMix(m);
      renderMood(side.key);
      if (reducedMotion.matches) renderMoney(now);
    } catch {
      state[side.key].ok = false;
    }
  }

  function tick() {
    for (const side of SIDES) poll(side);
  }

  tick();
  setInterval(tick, POLL_MS);
  // Staggered, so the two feeds don't tick in lockstep.
  setTimeout(() => addTweet("current"), 800);
  setTimeout(() => addTweet("central"), 1900);
  requestAnimationFrame(frame);
  reducedMotion.addEventListener?.("change", () => {
    if (!reducedMotion.matches) requestAnimationFrame(frame);
    else renderMoney(performance.now());
  });
})();
