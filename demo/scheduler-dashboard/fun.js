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
  const TWEET_KEEP = 50; // scrollable history per feed

  // Fictional tweets are [handle, text] on made-up handles. Real tweets are
  // quoted verbatim as objects marked `real: true`, and get a "Real tweet"
  // badge in the feed.
  const TWEETS = {
    happy: [
      ["@ci_goblin", "CI went green so fast I accused it of lying and made it run again. Green again. I am being gaslit by competence."],
      ["@yaml_whisperer", "Runner picked up my job before I finished typing git push. Is it reading my mind. Should I be worried. Not worried. Merged."],
      ["@rebase_raccoon", "Pushed at 2:59am. Green at 2:59am. The raccoons and I are celebrating in the dumpster behind the office."],
      ["@pipeline_possum", "Faked my death to avoid waiting on CI and it finished before I could even lie down."],
      ["@lint_lord", "The runner booted so fast the linter didn't have time to judge me. First time in years. I feel free."],
      ["@flaky_test_fairy", "My flaky test passed 10 times in a row. Either Ubicloud fixed physics or I'm dreaming. Don't wake me."],
      ["@monorepo_moose", "Fanned out 200 jobs and they all started at once. I heard angels. The angels were also on 30 vCPUs."],
      ["@docker_dumpling", "Build finished before my kettle clicked. I am now drinking cold water out of spite. Worth it."],
      ["@devops_dingo", "Told my manager CI takes 20 minutes so I could get coffee. It took 2. I am now trapped at my desk with no excuses."],
      ["@kernel_kiwi", "Ubicloud runner booted faster than my laptop wakes from sleep. Selling the laptop. I live on the runner now."],
      ["@green_check_gremlin", "Hoarding green checkmarks in a jar under my bed. Got 47 today. I will not be taking questions."],
      ["@hotfix_hedgehog", "Shipped the hotfix before the incident channel finished posting 👀. They're upset they didn't get to panic."],
      ["@semver_sloth", "As a sloth I have never been fast at anything. Today my CI was. I'm crying in slow motion."],
      ["@cache_miss_moth", "Cache miss, cold boot, still green before standup. I don't know who I am anymore and I love it."],
      ["@null_pointer_pal", "Zero queue time. Zero flakes. Zero drama. I keep looking for the catch like I'm reading the terms and conditions."],
      ["@commit_crab", "Pushed 14 commits titled 'fix'. All green instantly. CI has no idea how bad the code is and I intend to keep it that way."],
      ["@artifact_otter", "Uploaded artifacts and they came back faster than I sent them. The runner has time travel. Do not tell legal."],
      ["@tabs_not_spaces", "CI so fast I didn't have time to start a tabs vs spaces war in the PR comments. Everyone was civil. Unsettling."],
      ["@cron_job_crow", "The nightly build ran at night. On time. I went outside and screamed at the moon with joy."],
      ["@runner_rabbit", "Queued 9:00:00, running 9:00:01. That one second was the longest of my life and also the shortest."],
      ["@segfault_squid", "My code segfaulted instantly, which means the runner started instantly. Never been so happy to crash."],
      ["@merge_queue_mole", "Merge queue moving like a buttered water slide. Wheeeeee."],
      ["@standup_skipper", "Said 'it's merged' at standup instead of 'waiting on CI'. The room went silent. Someone clapped. I wept."],
      ["@sudo_sandwich", "sudo make me a green build. It did. Didn't even have to say please. Said please anyway. Out of respect."],
      ["@branch_badger", "30-vCPU runner, zero queue. My Rust compile finished and for the first time in my life I saw the sun."],
      ["@webhook_wombat", "Webhook fired, runner appeared, job done, all before my cat finished knocking my mug off the desk."],
      ["@deploy_duckling", "Deployed at 4:59pm on a Friday because CI was so fast I felt invincible. Still invincible. Do not jinx me."],
      ["@pr_pelican", "Reviewer approved, CI already green, merged within one sip of coffee. Choked on the sip out of shock."],
      ["@bisect_beaver", "Bisected 12 commits, each run under a minute. Found the bug, the bug's parents and the bug's childhood home."],
      ["@diff_dragon", "Massive diff, tiny wait. I am the dragon now. Hoard of green checks: complete."],
      ["@test_matrix_tapir", "Ran the entire matrix on every runner size and was still home for dinner. My family doesn't recognize me."],
      ["@ci_goblin", "CI bill went down so much finance called to ask if we'd stopped shipping. We hadn't. We're shipping MORE."],
      ["@yaml_whisperer", "Indentation right on the first try AND an instant runner. Buying a lottery ticket and a cape."],
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
      ["@semver_sloth", "Runner took a minute and a half. Enough time to read one forum post and get mad about it."],
      ["@pipeline_possum", "CI is 'thinking'. Same, CI. Same."],
      ["@flaky_test_fairy", "Waiting on a runner. Renamed every variable. Will rename them back. This is my life now."],
      ["@lint_lord", "Queue's a bit slow. Drank water. Hydrated. Furious about being hydrated."],
      ["@cache_miss_moth", "Job queued 90 seconds. Not mad. Just staring at the spinner like it owes me money."],
      ["@rebase_raccoon", "Runner's coming. Probably. Rebased again for fun. It was not fun."],
      ["@docker_dumpling", "Spinner, spinner on the wall, who's the slowest queue of all."],
      ["@kernel_kiwi", "Waited long enough to check the weather. Not long enough to need a jacket. Medium vibes."],
      ["@commit_crab", "My job is queued. I am queued. My lunch is queued. We are all just queued."],
      ["@monorepo_moose", "Half the matrix is running, half is waiting. Schrödinger's build. Opening the box feels risky."],
      ["@null_pointer_pal", "Status: queued. Mood: politely tapping foot at 140 bpm."],
      ["@devops_dingo", "Two minutes to get a runner. Not great, not terrible. Long enough to start quoting TV shows."],
      ["@tabs_not_spaces", "While I wait for CI, a reminder that tabs are correct and I will die on this hill. In about a minute."],
      ["@hotfix_hedgehog", "Waiting on CI for a one-line hotfix. It's a very important line. It's a semicolon."],
      ["@cron_job_crow", "Queue's busy. Somebody out there is launching a startup. Hope it's worth my 90 seconds."],
      ["@artifact_otter", "Runner's on its way. Wrote a commit message with actual words in the meantime. Growth."],
      ["@runner_rabbit", "Queued long enough to start a second branch. Now I have two problems and zero runners."],
      ["@yaml_whisperer", "Watching 'Waiting for a runner' like a nature documentary. The runner approaches. Slowly. Majestically."],
      ["@ci_goblin", "CI's taking a minute. Opened my editor, closed it, stared into the void. The void said 'queued'."],
      ["@merge_queue_mole", "Merge queue moving at the speed of a polite crowd leaving a theater. Someone's looking for their coat."],
      ["@standup_skipper", "Build is 'queued'. Told standup it's 'in progress'. Technically a queue is a process."],
      ["@segfault_squid", "Runner wait long enough to make toast. Not long enough to butter it. Dry toast. Dry life."],
      ["@diff_dragon", "Slow-ish queue. Re-read my own diff. Found two typos and one existential crisis."],
      ["@branch_badger", "Big runners take a bit longer to show up. Fair. I also take a while to show up."],
      ["@webhook_wombat", "Queued. Breathing exercises. In for 4, hold for 4, out for 'please start'."],
      ["@deploy_duckling", "CI is fine. I'm fine. Everything is a reasonable amount of fine. Ask me again in 60 seconds."],
      ["@test_matrix_tapir", "Matrix half done. Like a crossword where someone keeps hiding the pen."],
      ["@pr_pelican", "Reviewer waiting on CI, CI waiting on a runner, me waiting on lunch. The circle of life."],
      ["@bisect_beaver", "Bisecting slowly today. The bug isn't going anywhere and neither am I. We're roommates now."],
      ["@sudo_sandwich", "Queue's a little long. Sandwich time. The sandwich, unlike CI, arrived instantly."],
      ["@green_check_gremlin", "Yellow dot. Not red. Not green. Yellow is a vibe. I am learning to accept yellow."],
      ["@kernel_kiwi", "Runner pending. Cleaned my desktop for the first time since 2019. Found a folder called final_final_v3."],
      ["@lint_lord", "Took a while, but it ran. Lowered my expectations and met them exactly. Personal best."],
    ],
    angry: [
      ["@flaky_test_fairy", "Waited so long for a runner my PR got stale, then moldy, then grew legs and walked off."],
      ["@ci_goblin", "Coffee brewed, poured, drunk, regretted and re-brewed. Job still queued. I am now 40% coffee by volume."],
      ["@yaml_whisperer", "Rewrote my YAML three times while waiting. Now it's worse, longer and still queued. I'm speaking to it in tongues."],
      ["@rebase_raccoon", "By the time my runner started, main had moved 40 commits, two reorgs and a company rebrand."],
      ["@pipeline_possum", "Playing dead until my job leaves the queue. Wake me next fiscal year."],
      ["@semver_sloth", "I'm a SLOTH and I think this queue is slow. Let that sink in. Slowly. Like me. Like the queue."],
      ["@monorepo_moose", "1 of my 40 jobs finished. The other 39 are 'waiting for a runner'. I've started naming them like pets."],
      ["@hotfix_hedgehog", "Hotfix waiting on CI longer than the outage it fixes. The outage is now fixing itself out of boredom."],
      ["@devops_dingo", "Queue time is longer than my build time. Up is down. Left is right. CI is a myth."],
      ["@docker_dumpling", "Started a sourdough starter while waiting. It has risen, been baked, eaten and digested. Still queued."],
      ["@lint_lord", "Queued so long the lint rules changed. Then changed back. Then the linter retired."],
      ["@null_pointer_pal", "My runner is a null pointer. It points to nothing. It references the void. The void references back."],
      ["@cache_miss_moth", "10 minutes for a 30-vCPU runner while tiny 2-vCPU jobs cut the line like they own the place. Class warfare."],
      ["@kernel_kiwi", "Could have compiled this on my laptop. Twice. With the fan screaming like a jet engine. Seriously considering it."],
      ["@commit_crab", "Pinched the refresh button so many times it filed a restraining order."],
      ["@tabs_not_spaces", "CI is queued. My patience has been converted to spaces. Four of them. Per indent. Forever."],
      ["@cron_job_crow", "Nightly build finished the next afternoon. Renaming it 'eventually build'."],
      ["@artifact_otter", "My artifacts expired before my job started. They died waiting. Holding a small funeral at 3pm."],
      ["@runner_rabbit", "Where is my runner. I have named the loading spinner Kevin. Kevin and I are very close now."],
      ["@segfault_squid", "Queued so long my test fixtures need updating for the new year. Happy new year from the queue."],
      ["@merge_queue_mole", "Merge queue is now a merge museum. Admission is free. Exhibits from this morning on display."],
      ["@standup_skipper", "Said 'waiting on CI' at standup. And the next standup. And the retro. They made it a team value."],
      ["@diff_dragon", "Breathing fire at a yellow dot. It remains yellow. It is fireproof. I fear it."],
      ["@branch_badger", "My 30-vCPU job is starving while 2-vCPU jobs zoom past. I would like to speak to the scheduler's manager."],
      ["@webhook_wombat", "The webhook arrived. The runner did not. I'm in a long-distance relationship with my own CI."],
      ["@deploy_duckling", "Wanted to deploy before the weekend. CI said: what weekend? I am now spiritually at the office."],
      ["@test_matrix_tapir", "Matrix queued so long I memorized every job name and composed a sea shanty about them."],
      ["@pr_pelican", "Reviewer approved, went on vacation, came back tanned. Still waiting on CI."],
      ["@bisect_beaver", "Bisect needs 7 runs. At this pace I'll find the bug next year. The bug will have kids by then."],
      ["@sudo_sandwich", "sudo start my runner. Permission denied by the laws of physics, apparently."],
      ["@green_check_gremlin", "I was promised green checks. I have received an hourglass. I am going feral."],
      ["@ci_goblin", "My PR waited so long it developed merge conflicts out of pure boredom, and then a personality."],
      ["@yaml_whisperer", "Whispered sweet nothings to the queue. It left me on read."],
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

  // One column per side, like the rest of the page: money and mood up top,
  // that side's customer chatter below.
  const view = {};
  for (const side of SIDES) {
    const col = el("div", "fun-col");
    const stats = el("div", "fun-stats");

    const money = el("div", "fun-stat");
    const total = el("span", "fun-total", "—");
    money.append(el("span", "fun-label", "Money made · last minute"), total);

    const mood = el("div", "fun-stat");
    const big = el("span", "fun-big", MOODS.happy.emoji);
    big.setAttribute("role", "img");
    const word = el("span", "fun-mood-word", "Happy");
    const moodRow = el("div", "fun-mood-row");
    moodRow.append(big, word);
    mood.append(el("span", "fun-label", "Customer mood"), moodRow);
    stats.append(money, mood);

    const feed = el("ol", "fun-feed");
    feed.setAttribute("aria-label", `Customer tweets about ${side.name}`);

    col.append(who(side), stats, el("span", "fun-label", "Customer chatter"), feed);
    grid.append(col);
    view[side.key] = { total, big, word, feed };
  }

  // ---------------------------------------------------------------- state

  const state = {};
  for (const side of SIDES) {
    state[side.key] = {
      earnings: [], // [server ms, $/min] samples covering the last minute
      mix: { happy: 0, meh: 0, angry: 0 },
      ok: false,
    };
  }

  // ---------------------------------------------------------------- money

  const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
  const fmtUsd = (v) => usd.format(v);
  const WINDOW_MS = 60 * 1000;

  // Dollars earned over the last minute of server time: the $/min rate
  // (vCPUs in use × price) integrated between samples, trapezoid-style, so a
  // mock running faster than real time still earns the right amount.
  function updateMoney(key, m) {
    const s = state[key];
    const gen = Date.parse(m.generated_at);
    if (!Number.isFinite(gen)) return;
    const rate = (Number(m.fleet?.vcpus_used) || 0) * DOLLARS_PER_VCPU_MINUTE;
    const pts = s.earnings;
    if (pts.length && (gen <= pts.at(-1)[0] || gen - pts.at(-1)[0] > MAX_GAP_SECONDS * 1000)) pts.length = 0;
    pts.push([gen, rate]);
    const from = gen - WINDOW_MS;
    // Keep one sample at or before the window start to interpolate from.
    while (pts.length > 2 && pts[1][0] <= from) pts.shift();

    let dollars = 0;
    for (let i = 1; i < pts.length; i++) {
      let [t0, r0] = pts[i - 1];
      const [t1, r1] = pts[i];
      if (t1 <= from) continue;
      if (t0 < from) {
        r0 += ((r1 - r0) * (from - t0)) / (t1 - t0);
        t0 = from;
      }
      dollars += ((r0 + r1) / 2) * ((t1 - t0) / 60000);
    }
    view[key].total.textContent = fmtUsd(dollars);
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
    v.word.textContent = MOODS[mood].label[0].toUpperCase() + MOODS[mood].label.slice(1);
    v.big.setAttribute("aria-label", `Customers are ${MOODS[mood].label}`);
  }

  // ---------------------------------------------------------------- tweets

  // A tweet for one side, picked by that side's current mood mix.
  // A tweet for one side, in that side's overall mood right now (the same
  // mood its big face shows), so the chatter flips as the mood does.
  function pickTweet(key) {
    const feed = view[key].feed;
    const mood = overall(state[key].mix);
    // Avoid repeating anything among the last few tweets on screen.
    const recent = new Set([...feed.children].slice(0, 10).map((li) => li.dataset.text));
    const pool = TWEETS[mood].filter((t) => !recent.has(t.text));
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
      // Someone scrolled down to read older tweets: keep their place.
      const reading = feed.scrollTop > 4;
      const before = feed.scrollHeight;
      feed.prepend(li);
      if (reading) feed.scrollTop += feed.scrollHeight - before;
      while (feed.children.length > TWEET_KEEP) feed.lastElementChild.remove();
    }
    setTimeout(() => addTweet(key), 4000 + Math.random() * 2000);
  }

  // ---------------------------------------------------------------- poll

  async function poll(side) {
    try {
      const r = await fetch(side.url, { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const m = await r.json();
      const s = state[side.key];
      s.ok = true;
      updateMoney(side.key, m);
      s.mix = moodMix(m);
      renderMood(side.key);
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
})();
