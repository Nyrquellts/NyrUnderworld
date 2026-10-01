/*
  The drawn page, run without a browser: adapter/nui/app.js, unmodified,
  against a small fake DOM built from the real adapter/nui/index.html.

    node tools/page_check.js

  Run by spec/nui_spec.lua, so the suite runs it. Each check prints "ok" or
  "FAIL" and a name; any failure exits 1.

  Why it exists: the page is JavaScript, and every defect in it passed the Lua
  suite, which cannot run a line of it. A double-click retired a character and
  bought a flat, and an answer that arrived after Escape put a shop on screen
  with the mouse already given back to the game. Both are about what the page
  does with time and with an answer arriving late, which is exactly what a fake
  DOM with a clock and held requests can arrange.

  What it cannot see: layout, colour, focus inside the game, or anything Lua
  does. Those need the preview or a connected client.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const VOID = new Set(['meta', 'link', 'input', 'br', 'img', 'hr']);

// --------------------------------------------------------------------- dom

class ClassList {
  constructor(el) { this.el = el; }
  get names() { return (this.el.attrs.class || '').split(/\s+/).filter(Boolean); }
  write(names) { this.el.attrs.class = [...new Set(names)].join(' '); }
  add(...names) { this.write([...this.names, ...names]); }
  remove(...names) { this.write(this.names.filter((n) => !names.includes(n))); }
  contains(name) { return this.names.includes(name); }
  toggle(name, force) {
    const on = force === undefined ? !this.contains(name) : Boolean(force);
    if (on) this.add(name); else this.remove(name);
    return on;
  }
}

class Node {
  constructor(tag, attrs) {
    this.tag = tag;
    this.attrs = attrs || {};
    this.children = [];
    this.parent = null;
    this.listeners = {};
    this.style = {
      properties: {},
      setProperty(name, value) { this.properties[name] = String(value); },
      removeProperty(name) { delete this.properties[name]; },
    };
    this.classList = new ClassList(this);
    this.text = '';
    this.scrollTop = 0;
    this.scrollHeight = 0;
    this.tabIndex = -1;
    this.dataset = {};
    if (tag === 'input') this.valueText = this.attrs.value || '';
    if (tag === 'template') this.content = new Node('#fragment');
  }
  get isElement() { return !this.tag.startsWith('#'); }
  get id() { return this.attrs.id; }
  get hidden() { return 'hidden' in this.attrs; }
  set hidden(value) { if (value) this.attrs.hidden = ''; else delete this.attrs.hidden; }
  get disabled() { return 'disabled' in this.attrs; }
  set disabled(value) { if (value) this.attrs.disabled = ''; else delete this.attrs.disabled; }
  get value() { return this.valueText; }
  set value(value) { this.valueText = String(value); }
  get className() { return this.attrs.class || ''; }
  set className(value) { this.attrs.class = String(value); }
  get firstElementChild() { return this.children.find((c) => c.isElement) || null; }
  get textContent() { return this.text + this.children.map((c) => c.textContent).join(''); }
  set textContent(value) { this.children = []; this.text = String(value); }
  setAttribute(key, value) { this.attrs[key] = String(value); }
  getAttribute(key) { return key in this.attrs ? this.attrs[key] : null; }
  removeAttribute(key) { delete this.attrs[key]; }
  hasAttribute(key) { return key in this.attrs; }
  appendChild(child) {
    if (child.parent) child.parent.children = child.parent.children.filter((c) => c !== child);
    child.parent = this;
    this.children.push(child);
    return child;
  }
  append(...nodes) { for (const node of nodes) this.appendChild(node); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  focus() { focused.node = this; }
  blur() { if (focused.node === this) focused.node = null; }
  contains(other) { for (let at = other; at; at = at.parent) if (at === this) return true; return false; }
  closest(selector) {
    for (let at = this; at && at.isElement; at = at.parent) if (matchesGroup(at, selector)) return at;
    return null;
  }
  matches(selector) { return matchesGroup(this, selector); }
  cloneNode(deep) {
    const copy = new Node(this.tag, { ...this.attrs });
    copy.text = this.text;
    if (this.tag === 'input') copy.valueText = this.valueText;
    if (deep) for (const child of this.children) copy.appendChild(child.cloneNode(true));
    if (deep && this.content) for (const child of this.content.children) copy.content.appendChild(child.cloneNode(true));
    return copy;
  }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); }
  dispatch(type, extra) {
    const event = Object.assign({ type, target: this, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() {} }, extra || {});
    for (const fn of this.listeners[type] || []) fn(event);
    return event;
  }
  click() { return this.dispatch('click'); }
  *descendants() {
    for (const child of this.children) {
      if (!child.isElement) continue;
      yield child;
      yield* child.descendants();
    }
  }
  querySelectorAll(selector) {
    const out = [];
    for (const el of this.descendants()) if (matchesGroup(el, selector, this)) out.push(el);
    return out;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

const focused = { node: null };

function matchesCompound(el, compound) {
  const m = compound.match(/^([a-zA-Z][\w-]*|\*)?((?:[.#][\w-]+|\[[\w-]+\])*)$/);
  if (!m) throw new Error('page_check: selector not supported: ' + compound);
  if (m[1] && m[1] !== '*' && el.tag !== m[1].toLowerCase()) return false;
  for (const bit of (m[2].match(/[.#][\w-]+|\[[\w-]+\]/g) || [])) {
    if (bit[0] === '#' && el.attrs.id !== bit.slice(1)) return false;
    if (bit[0] === '.' && !el.classList.contains(bit.slice(1))) return false;
    if (bit[0] === '[' && !(bit.slice(1, -1) in el.attrs)) return false;
  }
  return true;
}

function matchesGroup(el, selector, root) {
  return selector.split(',').map((s) => s.trim()).some((group) => {
    const parts = group.split(/\s+/);
    if (!matchesCompound(el, parts[parts.length - 1])) return false;
    let i = parts.length - 2;
    for (let at = el.parent; i >= 0 && at && at !== (root ? root.parent : null); at = at.parent) {
      if (at.isElement && matchesCompound(at, parts[i])) i--;
    }
    return i < 0;
  });
}

function parse(html) {
  const doc = new Node('#document');
  const stack = [doc];
  const tokens = /<!--[\s\S]*?-->|<!DOCTYPE[^>]*>|<\/([a-zA-Z][\w-]*)\s*>|<([a-zA-Z][\w-]*)((?:\s+[^\s=>\/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(\/?)>|([^<]+)/g;
  let m;
  while ((m = tokens.exec(html))) {
    const top = stack[stack.length - 1];
    const into = top.tag === 'template' ? top.content : top;
    if (m[1]) {
      const name = m[1].toLowerCase();
      for (let i = stack.length - 1; i > 0; i--) if (stack[i].tag === name) { stack.length = i; break; }
    } else if (m[2]) {
      const tag = m[2].toLowerCase();
      const attrs = {};
      const pairs = /([^\s=>\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
      let a;
      while ((a = pairs.exec(m[3] || ''))) attrs[a[1]] = a[2] ?? a[3] ?? a[4] ?? '';
      const el = new Node(tag, attrs);
      into.appendChild(el);
      if (!VOID.has(tag) && !m[4]) stack.push(el);
      if (tag === 'script' || tag === 'style') {
        const close = html.indexOf(`</${tag}`, tokens.lastIndex);
        tokens.lastIndex = close < 0 ? html.length : close;
      }
    } else if (m[5] && m[5].trim()) {
      const text = new Node('#text');
      text.text = m[5].replace(/\s+/g, ' ');
      into.appendChild(text);
    }
  }
  return doc;
}

// -------------------------------------------------------------------- page

/* One page, booted fresh. Every fetch is held until a check answers it, and
   time only moves when a check moves it, so the order of events is exactly the
   order written down. */
function boot() {
  const html = fs.readFileSync(path.join(ROOT, 'adapter/nui/index.html'), 'utf8');
  const doc = parse(html);
  const byId = (id) => {
    for (const el of doc.descendants()) if (el.attrs.id === id) return el;
    return null;
  };
  const clock = { now: 1000000 };
  const timers = [];
  let timerId = 0;
  const document = {
    getElementById: byId,
    querySelectorAll: (s) => doc.querySelectorAll(s),
    querySelector: (s) => doc.querySelector(s),
    createElement: (tag) => new Node(tag.toLowerCase()),
    get activeElement() { return focused.node; },
    documentElement: new Node('html'),
    body: doc,
    listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    key(type, key) { for (const fn of this.listeners[type] || []) fn({ type, key, preventDefault() {}, target: doc }); },
  };
  const windowListeners = {};
  const requests = [];
  const window = {
    addEventListener(type, fn) { (windowListeners[type] = windowListeners[type] || []).push(fn); },
    send(data) { for (const fn of windowListeners.message || []) fn({ data }); },
  };
  function fetch(url, opts) {
    const request = { action: String(url).split('/').pop(), payload: JSON.parse((opts && opts.body) || '{}') };
    request.promise = new Promise((resolve) => {
      request.answer = (value) => resolve({ json: async () => value });
    });
    requests.push(request);
    // Closing is answered at once, the way nui.lua's close callback answers.
    if (request.action === 'close') request.answer({ ok: true });
    return request.promise;
  }
  const FakeDate = class extends Date {
    constructor(...args) { super(...(args.length ? args : [clock.now])); }
    static now() { return clock.now; }
  };
  const context = vm.createContext({
    document, window, fetch, console, JSON, Promise, Array, Set, Map, WeakMap, Math, String,
    Number, Object, Boolean, Error, Date: FakeDate,
    performance: { now: () => clock.now },
    requestAnimationFrame: (fn) => setTimeoutFake(() => fn(clock.now), 16),
    setTimeout: (fn, ms) => setTimeoutFake(fn, ms),
    clearTimeout: (id) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); },
  });
  function setTimeoutFake(fn, ms) {
    timerId += 1;
    timers.push({ id: timerId, at: clock.now + Math.max(0, ms || 0), fn });
    return timerId;
  }
  context.window.document = document;
  vm.runInContext(fs.readFileSync(path.join(ROOT, 'adapter/nui/app.js'), 'utf8'), context, { filename: 'app.js' });

  const page = {
    doc, byId, document, window, requests, clock,
    flush: async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); },
    /* Move time on, running every timer that falls due on the way. */
    wait: async (ms) => {
      const until = clock.now + ms;
      for (;;) {
        timers.sort((a, b) => a.at - b.at);
        const next = timers[0];
        if (!next || next.at > until) break;
        timers.shift();
        clock.now = Math.max(clock.now, next.at);
        next.fn();
        await page.flush();
      }
      clock.now = until;
      await page.flush();
    },
    visible: () => ['picker', 'pockets', 'phone', 'shop', 'stash', 'nearby', 'bank', 'jobs']
      .filter((id) => byId(id) && !byId(id).hidden),
    asked: (action) => requests.filter((r) => r.action === action),
    pending: (action) => requests.filter((r) => r.action === action && !r.answered),
    answer: async (request, value) => { request.answered = true; request.answer(value); await page.flush(); },
  };
  return page;
}

// ------------------------------------------------------------------ checks

const PEOPLE = { used: 2, limit: 3, people: [
  { character: 'chr_jane', name: 'Jane Doe', money: '$500.00', playing: false },
  { character: 'chr_john', name: 'John Roe', money: '$12,000.00', playing: false }] };

const FOR_SALE = { shops: [{ shop: 'shp_robs', name: "Rob's Liquor", offers: ['shop'] }], places: [
  { place: 'prp_apt28', address: 'Integrity Way, Apt 28', kind: 'apartment', for_sale: true,
    price: '$2,500.00', offers: ['purchase', 'enter'] }] };

const COUNTER = { name: "Rob's Liquor", state: 'open', shut: false,
  lines: [{ item: 'water', label: 'Bottle of Water', buy: '$2.50', sell: '$1.00', stock: 40 }] };

const STASH = { here: { items: [] }, there: { items: [] }, pockets_id: 'chr_1', stash_id: 'prp:prp_apt28',
  address: 'Integrity Way, Apt 28' };

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const checks = [];
function check(name, fn) { checks.push({ name, fn }); }

// --------------------------------------------- a list that arrived as {}

// A Lua table with nothing in it has no way to say it is a list, and the JSON
// encoder in this repository writes it as {}. The views the store page was
// baked from have `offers: {}` on every row with nothing to offer, and
// `row.offers.includes` threw on the first of them: Around you drew three rows
// of seven. Whether the game's own encoder does the same is unmeasured, so the
// page reads every list as a list only if it is one.

check('Around you draws every row when one has nothing to offer', async () => {
  const page = boot();
  const views = JSON.parse(fs.readFileSync(path.join(ROOT, 'docs/store-page/views.json'), 'utf8'));
  const expected = (views.nearby.shops || []).length + (views.nearby.places || []).length;
  page.window.send({ type: 'nearby', ok: true, view: views.nearby });
  const drawn = page.doc.querySelectorAll('#around .place').length;
  assert(drawn === expected, `Around you drew ${drawn} rows of ${expected}`);
});

check('a row from a server that does not say what it offers still offers its door', async () => {
  // The other reading of "no list": absent is an older server, and offering the
  // door then is the behaviour that shipped. Empty is nothing to offer.
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: { shops: [], places: [
    { place: 'prp_1', address: '12 Grove', kind: 'apartment' },
    { place: 'prp_2', address: 'Pillbox Hill Branch', kind: 'bank', offers: {} }] } });
  const [older, branch] = page.doc.querySelectorAll('#around .place');
  assert(!older.querySelector('.place-go').hidden, 'a row from an older server lost its door');
  assert(branch.querySelector('.place-go').hidden, 'a row with nothing to offer offered a door');
  assert(branch.querySelector('.place-buy').hidden, 'a row with nothing to offer offered to sell');
});

check('a bank with nothing moved through it says so when the lines arrive as {}', async () => {
  const page = boot();
  page.window.send({ type: 'bank', ok: true, branch: 'prp_1',
    view: { open: true, number: 'NYR-1', balance: '$0.00', lines: {}, empty: true } });
  assert(!page.byId('bank-empty').hidden, 'an account with no lines did not say so');
});

check('a job board whose lists arrive as {} still draws', async () => {
  const page = boot();
  page.window.send({ type: 'jobs', ok: true, view: { employers: {}, empty: true } });
  assert(!page.byId('jobs-empty').hidden, 'a board with nobody hiring did not say so');
  page.window.send({ type: 'jobs', ok: true, view: { employers: [
    { employer: 'emp_1', name: 'Postal OP', hiring: true, jobs: {} },
    { employer: 'emp_2', name: 'Sanitation LS', hiring: true,
      jobs: [{ job: 'refuse', label: 'Refuse Collection', minutes: 15, pay: '$90.00' }] }] } });
  assert(page.doc.querySelectorAll('#jobs-list .place').length === 1, 'the job after an empty employer was not drawn');
});

// ------------------------------------------------------ asking twice

check('a double-click on Retire retires nobody', async () => {
  const page = boot();
  page.window.send({ type: 'picker', ok: true, view: PEOPLE });
  const retire = page.doc.querySelectorAll('#list .retire')[1];
  retire.click();
  await page.wait(80);
  retire.click();
  await page.flush();
  assert(page.asked('retire').length === 0, 'two clicks 80 ms apart retired somebody');
  assert(retire.classList.contains('confirming'), 'the second half of a double-click took the question back');
});

check('Retire pressed again once the question has been read retires them', async () => {
  const page = boot();
  page.window.send({ type: 'picker', ok: true, view: PEOPLE });
  const retire = page.doc.querySelectorAll('#list .retire')[1];
  retire.click();
  await page.wait(600);
  retire.click();
  await page.flush();
  const asked = page.asked('retire');
  assert(asked.length === 1, `pressing again after 600 ms sent ${asked.length} retire requests`);
  assert(asked[0].payload.character === 'chr_john', 'the retire named the wrong person');
});

check('an armed button carries how long it stays armed, for the line that runs out', async () => {
  // The countdown under an armed button is CSS, timed by --confirm-for. Set from
  // the number that takes the question back, so the two cannot disagree.
  const page = boot();
  page.window.send({ type: 'picker', ok: true, view: PEOPLE });
  const retire = page.doc.querySelectorAll('#list .retire')[1];
  retire.click();
  assert(retire.style.properties['--confirm-for'] === '3000ms',
    `an armed Retire said it would wait ${retire.style.properties['--confirm-for']}`);
});

check('while the server is asked every screen is marked waiting, and after it is not', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  const screens = page.doc.querySelectorAll('main');
  assert(screens.length >= 8 && screens.every((s) => s.classList.contains('waiting')),
    'a screen was not marked waiting while the server was asked');
  await page.answer(page.pending('shop')[0], { ok: true, view: COUNTER });
  assert(screens.every((s) => !s.classList.contains('waiting')), 'a screen was left waiting after the answer');
});

check('an armed Retire nobody confirms takes itself back', async () => {
  const page = boot();
  page.window.send({ type: 'picker', ok: true, view: PEOPLE });
  const retire = page.doc.querySelectorAll('#list .retire')[1];
  retire.click();
  await page.wait(3500);
  assert(!retire.classList.contains('confirming'), 'Retire was still armed three and a half seconds later');
  assert(retire.textContent.trim() === 'Retire', `an unarmed Retire reads "${retire.textContent}"`);
  retire.click();
  await page.flush();
  assert(page.asked('retire').length === 0, 'a press after the question lapsed retired somebody');
  assert(retire.classList.contains('confirming'), 'a press after the question lapsed did not ask again');
});

check('a question taken back by something else starts again from the beginning', async () => {
  const page = boot();
  page.window.send({ type: 'picker', ok: true, view: PEOPLE });
  const [first, second] = page.doc.querySelectorAll('#list .retire');
  second.click();
  await page.wait(100);
  // Arming another takes the first back ...
  first.click();
  await page.wait(700);
  // ... so this press asks again rather than retiring John.
  second.click();
  await page.flush();
  assert(page.asked('retire').length === 0, 'a Retire whose question had been taken back retired somebody');
  assert(second.classList.contains('confirming'), 'the press did not ask again');
  assert(!first.classList.contains('confirming'), 'two people were asked about at once');
});

check('a double-click on Buy buys nothing', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  const buy = page.doc.querySelectorAll('#around .place-buy').find((b) => !b.hidden);
  assert(buy && !buy.hidden, 'the door for sale drew no Buy');
  buy.click();
  await page.wait(50);
  buy.click();
  buy.dispatch('dblclick');
  await page.flush();
  assert(page.asked('purchase').length === 0, 'a double-click bought a flat');
  await page.wait(500);
  buy.click();
  await page.flush();
  const asked = page.asked('purchase');
  assert(asked.length === 1, `pressing Buy again after the question sent ${asked.length} purchases`);
  assert(JSON.stringify(asked[0].payload) === '{"place":"prp_apt28"}', 'the purchase sent more than the address');
});

check('an armed Buy nobody confirms takes itself back', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  const buy = page.doc.querySelectorAll('#around .place-buy').find((b) => !b.hidden);
  buy.click();
  await page.wait(3500);
  assert(!buy.classList.contains('confirming'), 'Buy was still armed three and a half seconds later');
  buy.click();
  await page.flush();
  assert(page.asked('purchase').length === 0, 'a press after the question lapsed bought a flat');
});

// --------------------------------------------------- an answer after closing

check('a counter that answers after Escape does not come up', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  const counter = page.pending('shop')[0];
  assert(counter, 'Counter asked for nothing');
  page.document.key('keyup', 'Escape');
  await page.flush();
  assert(page.visible().length === 0, 'Escape left a screen up');
  await page.answer(counter, { ok: true, view: COUNTER });
  assert(page.visible().length === 0,
    `an answer after Escape put ${JSON.stringify(page.visible())} on screen, with the mouse already given back`);
});

check('a counter that answers after the key closed the page does not come up', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  const counter = page.pending('shop')[0];
  page.window.send({ type: 'hide' });
  await page.answer(counter, { ok: true, view: COUNTER });
  assert(page.visible().length === 0, `an answer after hide put ${JSON.stringify(page.visible())} on screen`);
});

check('a door that answers after Escape does not come up', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  const go = page.doc.querySelectorAll('#around .place-go')[1];
  go.click();
  await page.flush();
  const entering = page.pending('enter')[0];
  assert(entering, 'Go in asked for nothing');
  page.document.key('keyup', 'Escape');
  await page.answer(entering, { ok: true, view: STASH });
  assert(page.visible().length === 0, `an answer after Escape put ${JSON.stringify(page.visible())} on screen`);
});

check('a late answer does not draw over the next screen opened', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  const counter = page.pending('shop')[0];
  page.document.key('keyup', 'Escape');
  page.window.send({ type: 'pockets', ok: true, view: { items: [] } });
  await page.answer(counter, { ok: true, view: COUNTER });
  assert(JSON.stringify(page.visible()) === '["pockets"]',
    `the pockets were replaced by ${JSON.stringify(page.visible())} when an old answer arrived`);
});

check('the counter still opens when it answers while the page is up', async () => {
  // The other half, so the checks above cannot pass by opening nothing ever.
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  await page.answer(page.pending('shop')[0], { ok: true, view: COUNTER });
  assert(JSON.stringify(page.visible()) === '["shop"]', `Counter opened ${JSON.stringify(page.visible())}`);
});

check('after a late answer is dropped the page can still ask', async () => {
  const page = boot();
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  const counter = page.pending('shop')[0];
  page.document.key('keyup', 'Escape');
  await page.answer(counter, { ok: true, view: COUNTER });
  page.window.send({ type: 'nearby', ok: true, view: FOR_SALE });
  page.doc.querySelector('#around .place-go').click();
  await page.flush();
  assert(page.asked('shop').length === 2, 'the page stopped asking after an answer was dropped');
});

// --------------------------------------------------------------------- run

(async () => {
  let failed = 0;
  for (const { name, fn } of checks) {
    try {
      await fn();
      console.log(`ok   ${name}`);
    } catch (err) {
      failed += 1;
      console.log(`FAIL ${name}: ${err && err.message ? err.message : err}`);
    }
  }
  console.log(`${checks.length - failed} of ${checks.length} page checks passed`);
  process.exit(failed ? 1 : 0);
})();
