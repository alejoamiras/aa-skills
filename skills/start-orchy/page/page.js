const PAGES = DATA.pages, ITEMS = DATA.items, SHOTS = DATA.shots, COLL = DATA.site.collection;
const ISSUE_URL = n => `https://github.com/${DATA.site.repo}/issues/${n}`;
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const byId = Object.fromEntries(ITEMS.map(i => [i.id, i]));
const CHOICE_KINDS = new Set(["visual","charter"]);
const needsChoice = it => CHOICE_KINDS.has(it.kind);
const pageItems = n => ITEMS.filter(i => i.page_no === n);

/* ---------- shots ---------- */
function shotRows(ref, option){
  const rows = SHOTS.filter(s => s.id === ref.id || s.parent === ref.id || (!option && s.option === "today" && s.id.startsWith(ref.id + "-")) || ((s.records||[]).includes(ref.rec) && (option ? s.option === option : s.option === "today")));
  const seen = new Set(); return rows.filter(r => { const k = r.light + "|" + r.dark + "|" + r.browser; if (seen.has(k)) return false; seen.add(k); return true; });
}
function fig(s){
  const a11y = s.a11y ? `<details class="a11y"><summary>What a screen reader gets</summary><pre>${esc(s.a11y)}</pre></details>` : "";
  const fx = s.browser === "firefox" ? " · Firefox" : "";
  const single = !(s.light && s.dark);
  const imgL = s.light ? `<img class="${single ? "one" : "l"}" src="shots/${esc(s.light)}" alt="${esc(s.caption)} (light theme${fx})" tabindex="0" data-cap="${esc(s.caption)}${fx}" loading="lazy">` : "";
  const vid = s.video ? `<video class="one vid" controls preload="metadata" src="shots/${esc(s.video)}"${s.light ? ` poster="shots/${esc(s.light)}"` : ""}>Your browser cannot play this clip.</video>` : "";
  const imgD = s.dark ? `<img class="${single ? "one" : "d"}" src="shots/${esc(s.dark)}" alt="${esc(s.caption)} (dark theme${fx})" tabindex="0" data-cap="${esc(s.caption)}${fx}" loading="lazy">` : "";
  return `<figure class="shot${single ? " single" : ""}"><div class="imgs">${vid}${imgL}${imgD}</div><figcaption>${esc(s.caption)}${fx}${single ? (s.light ? " (light only)" : " (dark only)") : ""}</figcaption>${a11y}</figure>`;
}
function pendingFig(ref){
  return `<div class="pending"><span class="profile">Shot not captured</span><span>${esc(ref.capture || ref.route || "")}</span>${ref.reason?`<span class="muted">${esc(ref.reason)}</span>`:""}</div>`;
}
function shotGroup(it, kind, label){
  const refs = (it.shots||[]).filter(s => s.kind === kind);
  if (!refs.length) return "";
  const seen = new Set(); const parts = [];
  for (const ref of refs) {
    if (seen.has(ref.id)) continue; seen.add(ref.id);
    const rows = shotRows({id: ref.id, rec: it.id});
    parts.push(rows.length ? rows.map(fig).join("") : pendingFig(ref));
  }
  return `<div class="shotgroup"><div class="profile">${label}</div><div class="shots">${parts.join("")}</div></div>`;
}
function beforeShots(it){
  return shotGroup(it, "before", "Today, as is") + shotGroup(it, "after", "As it ships") + shotGroup(it, "mockup", "Drawn, not built") + shotGroup(it, "page", "The page as drawn") + shotGroup(it, "compare", "Side by side");
}
function optionShots(it, key){
  const k = String(key).toLowerCase(); const rowOpt = id => String((SHOTS.find(r => r.id === id) || {}).option || "").toLowerCase();
  const refs = (it.shots||[]).filter(s => s.kind === "option" && (s.id.toLowerCase() === `o-${it.issue[0]}-${k}` || s.id.toLowerCase().endsWith(`-${k}`) || rowOpt(s.id) === k));
  const rows = refs.flatMap(ref => shotRows({id: ref.id, rec: it.id}, key));
  const seen = new Set(); const uniq = rows.filter(r => { const k = r.light; if (seen.has(k)) return false; seen.add(k); return true; });
  if (!uniq.length && !refs.length) return "";
  return `<div class="shots">${uniq.length ? uniq.map(fig).join("") : refs.map(pendingFig).join("")}</div>`;
}

/* ---------- item renderers ---------- */
const fold = (it, parts) => it.brief ? `<details class="more full"><summary>Full detail</summary><div class="body">${parts.filter(Boolean).join("")}</div></details>` : parts.filter(Boolean).join("");
const linksLine = it => it.links?.length ? `<p class="small"><b>Read:</b> ${it.links.map(l => `<a href="${esc(l.href)}" target="_blank" rel="noopener">${esc(l.label)}</a>`).join(" · ")}</p>` : "";
const nowLine = it => it.brief?.now ? `<p class="small muted"><b>Until you answer:</b> ${esc(it.brief.now)}</p>` : "";
const notesBox = it => it.render_notes?.length ? `<div class="notes"><div class="eyebrow">What ${esc(DATA.site.product)} really showed</div><ul>${it.render_notes.map(n => `<li>${esc(n)}</li>`).join("")}</ul></div>` : "";
const replyBox = it => it.reply ? `<div class="reply"><div class="eyebrow">Your note, answered (${esc(it.reply.at)})</div>${it.reply.note ? `<blockquote>${esc(it.reply.note)}</blockquote>` : ""}${it.reply.answer.split("\n\n").map(p => `<p>${esc(p)}</p>`).join("")}${it.reply.then ? `<p class="then"><b>Now:</b> ${esc(it.reply.then)}</p>` : ""}</div>` : "";
const premiseBox = it => it.premise ? `<div class="caveat"><div class="eyebrow">Premise check</div><p>${esc(it.premise)}</p></div>` : "";
const issueLinks = it => (it.issue||[]).map(n => `<a href="${ISSUE_URL(n)}" target="_blank" rel="noopener">#${n}</a>`).join(" ");
const holdChip = it => it.hold ? `<a class="hchip" href="#hold-${esc(it.hold)}" title="Merge hold">${esc(it.hold)}</a>` : "";
function ctlApprove(it){
  return `<div class="ctl" id="ctl-${it.id}">
    <div class="row"><button type="button" class="ghost act" data-id="${it.id}" data-choice="approve" aria-pressed="true">Approve</button><button type="button" class="ghost act" data-id="${it.id}" data-choice="change" aria-pressed="false">Change (with a note)</button></div>
    <textarea id="note-${it.id}" placeholder="What should differ. A change without a note is not recorded."></textarea>
    <div class="row"><button type="button" class="ghost save" data-id="${it.id}">Save</button><span class="saveline" id="line-${it.id}"></span></div>
  </div>`;
}
function itemApprove(it){
  const after = it.after_shot_in_pr ? `<p class="small muted">The after shot comes with the PR; the proposal above is the whole change.</p>` : "";
  return `<article class="item${it.hold?" held":""}" id="item-${it.id}" data-id="${it.id}" data-kind="approve">
    <div class="ihead"><span class="id">${it.id}</span><h3><span class="kchip k-approve">Approve</span>${esc(it.title)}${holdChip(it)}</h3><div class="issues">${issueLinks(it)}<span>· ${esc(it.lane)}</span></div></div>
    ${it.brief ? `<div class="proposal"><span class="eyebrow">Proposal</span><p>${esc(it.brief.ask)}</p></div>${nowLine(it)}${linksLine(it)}` : `<p class="surface"><b>Where.</b> ${esc(it.surface)}</p><div class="proposal"><span class="eyebrow">Proposal</span><p>${esc(it.proposal)}</p></div>`}
    ${replyBox(it)}${beforeShots(it)}${after}
    ${it.brief ? fold(it, [`<p class="surface"><b>Where.</b> ${esc(it.surface)}</p>`, `<div class="proposal"><span class="eyebrow">Proposal, in full</span><p>${esc(it.proposal)}</p></div>`, notesBox(it), premiseBox(it), `<div class="basis"><b>Basis.</b> ${esc(it.rule_or_precedent)}</div>`]) : `${notesBox(it)}${premiseBox(it)}<div class="basis"><b>Basis.</b> ${esc(it.rule_or_precedent)}</div>`}
    ${ctlApprove(it)}
  </article>`;
}
function itemCheck(it){
  return `<article class="item" id="item-${it.id}" data-id="${it.id}" data-kind="check">
    <div class="ihead"><span class="id">${it.id}</span><h3><span class="kchip k-check">Manual check</span>${esc(it.title)}</h3><div class="issues">${issueLinks(it)}<span>· ${esc(it.lane)}</span></div></div>
    ${it.brief ? `<div class="proposal"><span class="eyebrow">What to do</span><p>${esc(it.brief.ask)}</p></div>` : ""}
    ${replyBox(it)}${fold(it, [`<p class="surface"><b>Where.</b> ${esc(it.surface)}</p>`, `<div class="proposal"><span class="eyebrow">${it.brief ? "In full" : "What to do"}</span><p>${esc(it.proposal)}</p></div>`, `<div class="basis"><b>Why you.</b> ${esc(it.rule_or_precedent)}</div>`])}
    <div class="ctl" id="ctl-${it.id}">
      <label class="eyebrow" for="res-${it.id}">Result</label><textarea id="res-${it.id}" placeholder="What happened, in a sentence or two."></textarea>
      <label class="eyebrow" for="next-${it.id}">Next step (optional)</label><input class="txt" id="next-${it.id}" placeholder="Leave empty to let the orchestrator propose it.">
      <div class="row"><button type="button" class="act" data-id="${it.id}" data-choice="result">Record result</button><span class="saveline" id="line-${it.id}"></span></div>
    </div>
  </article>`;
}
function optionCard(it, o, withShots){
  const isRec = it.recommend?.id === o.id;
  const build = o.build ? `<details class="more"><summary>What was built for this shot</summary><div class="body"><pre>${esc(o.build)}</pre></div></details>` : "";
  return `<article class="opt${isRec?" rec":""}" data-id="${it.id}" data-key="${esc(o.id)}">
    <div class="head"><span class="key">${esc(o.id)}</span>${isRec?'<span class="chip rec">Recommended</span>':""}<span class="chip chosen chosen-chip" hidden>Chosen</span></div>
    <div class="body">${it.brief?.options?.[o.id] ? `<p>${esc(it.brief.options[o.id])}</p><details class="more"><summary>Full detail</summary><div class="body"><p>${esc(o.text)}</p></div></details>` : `<p>${esc(o.text)}</p>`}${build}</div>
    ${withShots ? optionShots(it, o.id) : ""}
    <div class="actions"><button type="button" class="ghost act" data-id="${it.id}" data-choice="${esc(o.id)}" aria-pressed="false">Choose ${esc(o.id)}</button></div>
  </article>`;
}
function readCard(it){
  return `<article class="opt read" data-id="${it.id}" data-key="read"><div class="head"><span class="key">Read</span><span class="chip chosen chosen-chip" hidden>Chosen</span></div><div class="body"><p>Not your call, or not now: the orchestrator reads this item after you sign the page, decides it from your earlier answers and the rules, and reports the call back to you (or re-asks with pictures when it cannot). A note gives it a direction.</p></div><div class="actions"><button type="button" class="ghost act" data-id="${it.id}" data-choice="read" aria-pressed="false">Read option</button></div></article>`;
}
function itemVisual(it){
  const asis = it.buttons.includes("As is") ? `<article class="opt" data-id="${it.id}" data-key="asis"><div class="head"><span class="key">As is</span><span class="chip chosen chosen-chip" hidden>Chosen</span></div><div class="body"><p>Leave the screen as it is today. The issue closes as not planned with this answer quoted.</p></div><div class="actions"><button type="button" class="ghost act" data-id="${it.id}" data-choice="asis" aria-pressed="false">Choose As is</button></div></article>` : "";
  return `<article class="item rec-open${it.hold?" held":""}" id="item-${it.id}" data-id="${it.id}" data-kind="visual">
    <div class="ihead"><span class="id">${it.id}</span><h3><span class="kchip k-visual">Choose</span>${esc(it.title)}${holdChip(it)}</h3><div class="issues">${issueLinks(it)}<span>· ${esc(it.lane)}</span></div></div>
    ${it.brief ? `<div class="proposal"><span class="eyebrow">Question</span><p>${esc(it.brief.ask)}</p></div>${nowLine(it)}${linksLine(it)}` : `<p class="surface"><b>Where.</b> ${esc(it.surface)}</p>`}
    ${replyBox(it)}${beforeShots(it)}${it.brief ? "" : notesBox(it)}
    <div class="options">${it.options.map(o => optionCard(it, o, true)).join("")}${asis}${readCard(it)}</div>
    <div class="recbox"><span class="eyebrow">Recommended: ${esc(it.recommend.id)}</span><p>${esc(it.brief?.pick?.why ?? it.recommend.why)}</p></div>
    ${it.brief ? fold(it, [`<p class="surface"><b>Where.</b> ${esc(it.surface)}</p>`, notesBox(it), `<div class="basis"><b>Why, in full.</b> ${esc(it.recommend.why)}</div>`, `<div class="basis"><b>Basis.</b> ${esc(it.rule_or_precedent)}</div>`]) : `<div class="basis"><b>Basis.</b> ${esc(it.rule_or_precedent)}</div>`}
    <div class="ctl" id="ctl-${it.id}"><textarea id="note-${it.id}" placeholder="A condition, a copy change, or why you chose differently (optional)."></textarea>
    <div class="row"><button type="button" class="ghost save" data-id="${it.id}">Save note</button><span class="saveline" id="line-${it.id}"></span></div></div>
  </article>`;
}
function itemCharter(it){
  const applies = it.applies_to?.length ? `<p class="small muted">Decides: ${it.applies_to.map(n => `<a href="${ISSUE_URL(n)}" target="_blank" rel="noopener">#${n}</a>`).join(" ")}</p>` : "";
  const diff = it.change_from_triage ? `<details class="more"><summary>What changed after review</summary><div class="body"><p>${esc(it.change_from_triage)}</p></div></details>` : "";
  return `<article class="item rec-open" id="item-${it.id}" data-id="${it.id}" data-kind="charter">
    <div class="ihead"><span class="id">${it.id}</span><h3><span class="kchip k-charter">Policy</span>${esc(it.title)}</h3></div>
    <div class="proposal"><span class="eyebrow">Question</span><p>${esc(it.question)}</p></div>
    <div class="options">${it.options.map(o => optionCard(it, o, false)).join("")}</div>
    <div class="recbox"><span class="eyebrow">Recommended: ${esc(it.recommend.id)}</span><p>${esc(it.recommend.why)}</p></div>
    ${applies}${diff}
    <div class="ctl" id="ctl-${it.id}"><textarea id="note-${it.id}" placeholder="A condition or a different rule (optional)."></textarea>
    <div class="row"><button type="button" class="ghost save" data-id="${it.id}">Save note</button><span class="saveline" id="line-${it.id}"></span></div></div>
  </article>`;
}
function vetoRow(it){
  const chip = it.list === "confirm" ? `<span class="kchip k-confirm">Confirm · visible</span>` : `<span class="kchip k-veto">Panel call</span>`;
  return `<div class="veto" id="item-${it.id}" data-id="${it.id}" data-kind="veto">
    <span class="id">${it.id}</span>
    <div class="line">${chip}<b>${esc(it.title)}</b> <span class="muted">${issueLinks(it)}</span><p>${esc(it.brief?.ask ?? it.line)}</p>${beforeShots(it)}${it.brief ? fold(it, [`<p>${esc(it.line)}</p>`, notesBox(it), `<div class="basis">${esc(it.rule_or_precedent)}</div>`]) : `<div class="basis">${esc(it.rule_or_precedent)}</div>${notesBox(it)}`}</div>
    <div class="ctl"><div class="row"><button type="button" class="ghost act" data-id="${it.id}" data-choice="strike" aria-pressed="false">Strike</button><input class="txt" id="note-${it.id}" placeholder="Why, or what instead (required to strike)."><span class="saveline" id="line-${it.id}"></span></div></div>
  </div>`;
}
const renderItem = it => ({approve: itemApprove, check: itemCheck, visual: itemVisual, charter: itemCharter})[it.kind]?.(it) ?? "";

/* ---------- page 0 info blocks ---------- */
function rulesBlock(){
  const sr = DATA.standing.map(r => `<div class="rule"><span class="id">${esc(r.id)}</span><p>${esc(r.rule)}</p><span class="cite">From ${esc(r.from)} · ${esc(r.citation)}</span></div>`).join("");
  const h = DATA.holds.merge_holds.map(r => `<div class="rule hold" id="hold-${esc(r.id)}"><span class="id">${esc(r.id)}</span><p><b>${esc(r.what)}</b> ${esc(r.rule)}</p><span class="cite">${(r.issues||[]).map(n => `<a href="${ISSUE_URL(n)}" target="_blank" rel="noopener">#${n}</a>`).join(" ")}${r.gates?.length?` · gates ${esc(r.gates.join(", "))}`:""}</span></div>`).join("");
  const g = DATA.holds.execution_gates.map(r => `<div class="rule"><span class="id">${esc(r.id)}</span><p>${esc(r.rule)}</p></div>`).join("");
  const rs = DATA.holds.reservations.map(r => `<div class="rule"><span class="id">${esc(r.id)}</span><p>${esc(r.rule)}</p><span class="cite">${esc(r.file||"")}${r.lanes?.length?` · ${esc(r.lanes.join(", "))}`:""}</span></div>`).join("");
  const na = DATA.noAsk.map(n => `<div class="rule"><span class="id"><a href="${ISSUE_URL(n.issue)}" target="_blank" rel="noopener">#${n.issue}</a></span><p>${esc(n.decision)}</p><span class="cite">${esc(n.rule)}</span></div>`).join("");
  return `
  <div class="pagehead" style="margin-top:8px"><h3>Standing rules the run already has</h3><p class="muted small">Nothing to answer: these come from your earlier sign-offs and the repo's rules. Listed so you can strike one in the page note.</p></div><div class="rules">${sr}</div>
  <div class="pagehead"><h3>Merge holds</h3><p class="muted small">What no arc merges without the answer named here. The items they cover carry the hold's tag.</p></div><div class="rules">${h}</div>
  <div class="pagehead"><h3>Execution gates</h3></div><div class="rules">${g}</div>
  <div class="pagehead"><h3>Lane reservations</h3><p class="muted small">Ordering between lanes that touch the same files.</p></div><div class="rules">${rs}</div>
  <div class="pagehead"><h3>Decided by rule, not asked</h3><p class="muted small">${DATA.noAsk.length} issue${DATA.noAsk.length === 1 ? "" : "s"} a recorded answer or a repo rule already settles. Each gets the decision below written in; say so in the page note if one should be asked instead.</p></div><div class="rules">${na}</div>`;
}

/* ---------- page sections ---------- */
function pageSection(p){
  const its = pageItems(p.no);
  const main = its.filter(i => i.kind !== "veto").map(renderItem).join("");
  const vetos = its.filter(i => i.kind === "veto");
  const vetoBlock = vetos.length ? `<div class="pagehead"><h3>Panel calls on this page</h3><p class="muted small">Accepted with your signed message unless struck. "Confirm" rows are visible changes the panel wants you to see; the others are moderate.</p></div><div class="vetolist">${vetos.map(vetoRow).join("")}</div>` : "";
  const n = its.length, choices = its.filter(needsChoice).length;
  const meta = [`wave ${p.wave}`, `lanes: ${p.lanes.join(", ")}`, p.issues?.length ? `issues: ${p.issues.map(x => "#"+x).join(" ")}` : "", `${n} items`].filter(Boolean).map(esc).join(" · ");
  return `<section class="page" id="page-${p.no}" data-page="${p.no}">
    <div class="pagehead"><div class="num">PAGE ${p.no} · ${choices ? `${choices} choice${choices>1?"s":""} to make · ` : ""}${n - choices} item${n - choices === 1 ? "" : "s"} approved when you sign</div><h2>${esc(p.name)}</h2><p>${esc(p.brief_intro ?? p.intro)}</p>${p.brief_intro ? `<details class="more"><summary>Full intro</summary><div class="body"><p>${esc(p.intro)}</p></div></details>` : ""}<div class="meta">${meta}</div></div>
    ${main}${p.no === 0 ? rulesBlock() : ""}${vetoBlock}
    <div class="signoff" id="signoff-${p.no}">
      <div class="eyebrow">Sign page ${p.no}</div>
      <div class="grid" id="sgrid-${p.no}"></div>
      <textarea id="except-${p.no}" placeholder="Optional: 'except ...' for anything on this page you want held back or changed beyond the item notes."></textarea>
      <div class="actions"><button type="button" class="big sign" data-page="${p.no}">Sign page ${p.no}</button><span class="saveline" id="sline-${p.no}"></span></div>
    </div>
  </section>`;
}
document.getElementById("pages").innerHTML = PAGES.map(pageSection).join("");
document.getElementById("toc").innerHTML = PAGES.map(p => `<a href="#page-${p.no}" id="toc-${p.no}"><span class="pn">P${p.no}</span><span>${esc(p.name)}</span><span class="st"></span></a>`).join("");

/* ---------- theme control + lightbox ---------- */
const segBtns = [...document.querySelectorAll(".seg button")];
function setMode(m){ if (m === "page") delete document.documentElement.dataset.shots; else document.documentElement.dataset.shots = m; segBtns.forEach(b => b.setAttribute("aria-pressed", String(b.dataset.mode === m))); try { localStorage.setItem("shots-mode", m) } catch {} }
segBtns.forEach(b => b.addEventListener("click", () => setMode(b.dataset.mode)));
try { const m = localStorage.getItem("shots-mode"); if (m && ["page","light","dark","both"].includes(m)) setMode(m) } catch {}
const lb = document.getElementById("lb"), lbImg = document.getElementById("lb-img"), lbCap = document.getElementById("lb-cap");
function openLb(img){ lbImg.src = img.src; lbImg.alt = img.alt; lbCap.textContent = img.dataset.cap || ""; lb.showModal(); }
document.addEventListener("click", e => { const img = e.target.closest("figure.shot img"); if (img) openLb(img); });
document.addEventListener("keydown", e => { if (e.key === "Enter" && e.target.matches("figure.shot img")) openLb(e.target); });
document.getElementById("lb-close").addEventListener("click", () => lb.close());
lb.addEventListener("click", e => { if (e.target === lb) lb.close(); });

/* ---------- state + render ---------- */
const state = { choices: {}, signoffs: {} };
let db = null, uid = null, writable = true, loaded = false;
const line = (id, text, err) => { const el = document.getElementById(id); if (!el) return; el.textContent = text; el.classList.toggle("err", !!err); };
const banner = document.getElementById("store-banner");
const showBanner = t => { banner.textContent = t; banner.classList.remove("hide"); };
const fmt = iso => { try { return new Date(iso).toLocaleString(undefined, {dateStyle:"medium", timeStyle:"short"}) } catch { return iso } };
const label = (it, c) => c === "read" ? "Read option (the orchestrator decides)" : c === "asis" ? "As is" : c === "approve" ? "Approve" : c === "change" ? "Change" : c === "strike" ? "Struck" : c === "result" ? "Result recorded" : `Option ${c}`;
const defaultLabel = it => it.kind === "approve" ? "Approve" : it.kind === "veto" ? "Accepted" : "Open";
const effective = it => state.choices[it.id]?.choice ?? (needsChoice(it) ? null : (it.kind === "approve" ? "approve" : "accept"));

function renderItemState(it){
  const a = state.choices[it.id], el = document.getElementById(`item-${it.id}`); if (!el) return;
  const noteEl = document.getElementById(`note-${it.id}`);
  if (a && noteEl && typeof a.note === "string" && document.activeElement !== noteEl) noteEl.value = a.note;
  if (it.kind === "approve") {
    el.classList.toggle("changed", a?.choice === "change"); el.classList.toggle("answered", a?.choice === "approve");
    el.querySelectorAll("button.act").forEach(b => b.setAttribute("aria-pressed", String((a?.choice ?? "approve") === b.dataset.choice)));
    line(`line-${it.id}`, a ? `${label(it, a.choice)}${a.note ? " · " + a.note : ""} · ${fmt(a.at)}` : "Approved when you sign this page.");
  } else if (it.kind === "veto") {
    el.classList.toggle("struck", a?.choice === "strike");
    el.querySelector("button.act")?.setAttribute("aria-pressed", String(a?.choice === "strike"));
    line(`line-${it.id}`, a ? `Struck · ${a.note || ""} · ${fmt(a.at)}` : "");
  } else if (it.kind === "check") {
    const r = document.getElementById(`res-${it.id}`), nx = document.getElementById(`next-${it.id}`);
    if (a && r && document.activeElement !== r) r.value = a.result || ""; if (a && nx && document.activeElement !== nx) nx.value = a.next_step || "";
    el.classList.toggle("answered", !!a); el.classList.toggle("rec-open", !a);
    line(`line-${it.id}`, a ? `Recorded ${fmt(a.at)}.` : "Not recorded yet; the page can be signed without it, the check is yours whenever.");
  } else {
    el.classList.toggle("answered", !!a); el.classList.toggle("rec-open", !a);
    el.querySelectorAll(".opt").forEach(card => { const on = !!a && card.dataset.key === a.choice; card.classList.toggle("chosen", on); card.querySelector(".chosen-chip").hidden = !on; card.querySelector("button.act").setAttribute("aria-pressed", String(on)); });
    line(`line-${it.id}`, a ? `Chosen ${label(it, a.choice)}${a.note ? " · " + a.note : ""}${a.viaRecommendAll ? " (recommendation taken)" : ""} · ${fmt(a.at)}` : "Not chosen yet.");
  }
}
function pageStatus(p){
  const its = pageItems(p.no), open = its.filter(i => needsChoice(i) && !state.choices[i.id]);
  const s = state.signoffs[p.no];
  const stale = s && its.some(i => (state.choices[i.id]?.choice ?? null) !== (s.choices?.[i.id] ?? null));
  return { open, signed: !!s && !stale && open.length === 0, stale: !!stale, s };
}
function renderPage(p){
  const its = pageItems(p.no), st = pageStatus(p);
  document.getElementById(`sgrid-${p.no}`).innerHTML = its.map(i => { const c = state.choices[i.id]; const v = c ? label(i, c.choice) : defaultLabel(i); return `<div><span class="eyebrow">${i.id}</span><span class="${c||needsChoice(i)?"":"muted"}">${esc(v)}</span></div>`; }).join("");
  const btn = document.querySelector(`button.sign[data-page="${p.no}"]`);
  btn.disabled = st.open.length > 0 || !db || !writable || !loaded;
  const ex = document.getElementById(`except-${p.no}`); if (st.s && typeof st.s.except === "string" && !st.s.except_resolved && document.activeElement !== ex && !ex.value) ex.value = st.s.except;
  const box = document.getElementById(`signoff-${p.no}`); box.classList.toggle("done", st.signed);
  if (st.s) line(`sline-${p.no}`, st.stale ? `Signed ${fmt(st.s.at)}, but an answer changed since. Sign again to update the record.` : st.open.length ? `Signed ${fmt(st.s.at)}, but ${st.open.map(i => i.id).join(", ")} was added since. Choose it, then sign again.` : `Signed ${fmt(st.s.at)}${st.s.except ? " · except: " + st.s.except : ""}.`, st.stale || st.open.length > 0);
  else line(`sline-${p.no}`, st.open.length ? `Choose ${st.open.map(i => i.id).join(", ")} first.` : "Signing approves every item on this page as shown above.");
  const t = document.getElementById(`toc-${p.no}`); t.classList.toggle("signed", st.signed); t.classList.toggle("open", !st.signed);
  const onSign = its.filter(i => !needsChoice(i)).length, tail = onSign ? ` · ${onSign} approved on sign` : "";
  t.querySelector(".st").textContent = st.signed ? "signed" : st.open.length ? `${st.open.length} to choose${tail}` : `ready to sign${tail}`;
}
function renderAll(){
  ITEMS.forEach(renderItemState); PAGES.forEach(renderPage);
  const choiceItems = ITEMS.filter(needsChoice), made = choiceItems.filter(i => state.choices[i.id]).length;
  const signed = PAGES.filter(p => pageStatus(p).signed).length;
  const checks = ITEMS.filter(i => i.kind === "check"), checksDone = checks.filter(i => state.choices[i.id]).length;
  const hide = !!document.getElementById("hide-signed")?.checked;
  PAGES.forEach(p => { const sg = pageStatus(p).signed; document.getElementById(`page-${p.no}`).hidden = hide && sg; document.getElementById(`toc-${p.no}`).hidden = hide && sg; });
  const hiddenN = hide ? PAGES.filter(p => pageStatus(p).signed).length : 0; const hs = document.getElementById("hidden-signed"); if (hs) { hs.textContent = hiddenN ? `${hiddenN} signed page${hiddenN === 1 ? "" : "s"} hidden; untick "Hide signed pages" to see them.` : ""; hs.hidden = !hiddenN; }
  document.getElementById("cnt").textContent = `${made} of ${choiceItems.length} choices made · ${checksDone} of ${checks.length} manual checks recorded · ${signed} of ${PAGES.length} pages signed`;
  const canWrite = db && writable && loaded;
  document.getElementById("take-recs").disabled = !canWrite || made === choiceItems.length;
  document.getElementById("sign-all").disabled = !canWrite || choiceItems.some(i => !state.choices[i.id]) || signed === PAGES.length;
  document.getElementById("final-line").textContent = signed === PAGES.length ? "Every page is signed. The orchestrator writes each decision into its issue and starts wave 1." : `${PAGES.length - signed} page${PAGES.length - signed === 1 ? "" : "s"} still unsigned.`;
}
(function(){ const cb = document.getElementById("hide-signed"); if (!cb) return; let saved = null; try { saved = localStorage.getItem("hide-signed"); } catch {} cb.checked = saved === null ? true : saved === "1"; cb.addEventListener("change", () => { try { localStorage.setItem("hide-signed", cb.checked ? "1" : "0"); } catch {} renderAll(); }); })();
renderAll();

/* ---------- writes ---------- */
const busy = new Set();
async function write(docId, data, lineId){
  if (!db) { line(lineId, "Answers can't be saved from this view.", true); return false; }
  // a write before the first snapshot would sign or answer over answers this view has not seen yet
  if (!loaded) { line(lineId, "Still loading the saved answers; try again in a moment.", true); return false; }
  if (busy.has(docId)) { line(lineId, "Still saving the last answer; try again in a moment.", true); return false; }
  busy.add(docId);
  try { if (data === null) await db.doc(`${COLL}/${docId}`).delete(); else await db.doc(`${COLL}/${docId}`).set(data); return true; }
  catch (e) { line(lineId, `Couldn't save: ${e?.code||""} ${e?.message||e}`.trim(), true); return false; }
  finally { busy.delete(docId); }
}
const base = it => ({ page: DATA.page, page_no: it.page_no, id: it.id, kind: it.kind, issue: it.issue || null, at: new Date().toISOString(), by: uid });
async function saveChoice(it, choice, extra = {}){
  const note = document.getElementById(`note-${it.id}`)?.value.trim() ?? "";
  if (it.kind === "approve" && choice === "change" && !note) { line(`line-${it.id}`, "A change needs a note saying what should differ.", true); return; }
  if (it.kind === "veto" && choice === "strike" && !note) { line(`line-${it.id}`, "Say why, or what instead, to strike it.", true); return; }
  if (it.kind === "approve" && choice === "approve" && !note) { line(`line-${it.id}`, "Clearing…"); await write(`choice-${it.id}`, null, `line-${it.id}`); return; }
  line(`line-${it.id}`, "Saving…");
  await write(`choice-${it.id}`, { ...base(it), choice, note, ...extra }, `line-${it.id}`);
}
async function signPage(p){
  const its = pageItems(p.no), choices = {}, notes = {};
  const taken_all = [];
  its.forEach(i => { const c = state.choices[i.id]; choices[i.id] = c?.choice ?? null; if (c?.note) notes[i.id] = c.note; if (c?.viaRecommendAll) taken_all.push(i.id); });
  const except = document.getElementById(`except-${p.no}`).value.trim();
  line(`sline-${p.no}`, "Recording…");
  return write(`signoff-P${p.no}`, { page: DATA.page, page_no: p.no, name: p.name, head: DATA.head, choices, notes, taken_all, except, changed: its.filter(i => state.choices[i.id]).length, at: new Date().toISOString(), by: uid }, `sline-${p.no}`);
}
document.addEventListener("click", async e => {
  const act = e.target.closest("button.act");
  if (act) {
    const it = byId[act.dataset.id], c = act.dataset.choice;
    if (it.kind === "veto" && c === "strike" && state.choices[it.id]?.choice === "strike") { line(`line-${it.id}`, "Restoring…"); await write(`choice-${it.id}`, null, `line-${it.id}`); return; }
    if (it.kind === "check") { const result = document.getElementById(`res-${it.id}`).value.trim(), next_step = document.getElementById(`next-${it.id}`).value.trim(); if (!result) { line(`line-${it.id}`, "Write the result first.", true); return; } await saveChoice(it, "result", { result, next_step }); return; }
    await saveChoice(it, c); return;
  }
  const sv = e.target.closest("button.save");
  if (sv) { const it = byId[sv.dataset.id]; const cur = state.choices[it.id]; if (needsChoice(it) && !cur) { line(`line-${it.id}`, "Choose an option first; the note saves with it.", true); return; } await saveChoice(it, cur?.choice ?? "approve"); return; }
  const sg = e.target.closest("button.sign");
  if (sg) { await signPage(PAGES.find(p => p.no === Number(sg.dataset.page))); return; }
  if (e.target.id === "take-recs") {
    // Resumable: only items without a recorded choice are written. A write that hangs or fails is retried
    // three times with a bound, so one stuck call cannot stop the whole run silently.
    const open = ITEMS.filter(i => needsChoice(i) && !state.choices[i.id]);
    const total = open.length; let done = 0, failed = 0;
    const btn = e.target; btn.disabled = true;
    const progress = (err) => line("final-line", `Taking ${total} recommendation${total === 1 ? "" : "s"}… ${done} of ${total} saved${failed ? `, ${failed} failed` : ""}`, err);
    const setBounded = (docId, data, ms) => Promise.race([db.doc(`${COLL}/${docId}`).set(data).then(() => true), new Promise(r => setTimeout(() => r(false), ms))]).catch(() => false);
    const save = async it => {
      line(`line-${it.id}`, "Saving…");
      for (let attempt = 1; attempt <= 3; attempt++) {
        if (await setBounded(`choice-${it.id}`, { ...base(it), choice: it.recommend.id, note: "", viaRecommendAll: true }, 15000)) return true;
        await new Promise(r => setTimeout(r, 700 * attempt));
      }
      line(`line-${it.id}`, "Couldn't save after three tries; press the button again to retry.", true);
      return false;
    };
    progress(false);
    const queue = open.slice();
    await Promise.all(Array.from({ length: 2 }, async () => { while (queue.length) { const it = queue.shift(); (await save(it)) ? done++ : failed++; progress(false); } }));
    line("final-line", failed ? `${done} of ${total} saved; ${failed} didn't save. Press the button again to retry those.` : `${done} of ${total} recommendations saved. Sign the pages when ready.`, !!failed);
    renderAll();
    return;
  }
  if (e.target.id === "sign-all") {
    const todo = PAGES.filter(p => !pageStatus(p).signed);
    line("final-line", `Signing ${todo.length} page${todo.length === 1 ? "" : "s"}…`);
    for (const p of todo) await signPage(p);
  }
});

/* ---------- store ---------- */
(async () => {
  const [d, u] = await Promise.all([claude.use("db"), claude.use("user")]);
  const off = () => document.querySelectorAll("button.act, button.save, button.sign, #take-recs, #sign-all").forEach(b => b.disabled = true);
  if (!d) { showBanner("This view can't reach the page's store (signed out, or the store is unavailable). You can read everything, but answers won't save here. Open the page signed in on claude.ai to answer."); off(); return; }
  db = d;
  if (u) {
    try { uid = await u.id(); } catch {}
    try { if ((await u.isOwner()) === false) { writable = false; showBanner("Only the owner can record answers on this page."); off(); } } catch {}
  }
  db.collection(COLL).onSnapshot(snap => {
    const choices = {}, signoffs = {};
    snap.docs.forEach(doc => { const id = doc.id, v = doc.data(); if (id.startsWith("choice-")) choices[id.slice(7)] = v; else if (id.startsWith("signoff-P")) signoffs[Number(id.slice(9))] = v; });
    state.choices = choices; state.signoffs = signoffs; loaded = true; renderAll();
  }, err => showBanner(`Store error: ${err?.code||""} ${err?.message||""}`.trim()));
  renderAll();
})();
