/*
  Six screens, and none of them decide anything.

  Every value drawn here arrived in a message from the Lua side, already
  formatted. This file does no arithmetic on money or weight, holds no balance,
  and is never told why anything was refused -- only what line to print. There
  is deliberately nothing here to edit that would let somebody do something the
  server would not let them do, because the whole point of putting the rules on
  the server is that this file is on the player's own machine.

  Names, item labels and message bodies are written with textContent, never
  innerHTML. They are somebody's typing, and typing is not markup.
*/
'use strict';

(function () {
  // FiveM gives the page the name of the resource serving it. The resource is
  // named by its folder, which whoever installs this can rename, so it is
  // asked for rather than assumed.
  const RESOURCE = (typeof GetParentResourceName === 'function')
    ? GetParentResourceName()
    : 'nyr_underworld';

  const picker = document.getElementById('picker');
  const pockets = document.getElementById('pockets');
  const phone = document.getElementById('phone');
  const shop = document.getElementById('shop');
  const stash = document.getElementById('stash');
  const nearby = document.getElementById('nearby');
  const bank = document.getElementById('bank');
  const jobs = document.getElementById('jobs');
  const screens = [picker, pockets, phone, shop, stash, nearby, bank, jobs];
  const itemIcons = new Set(['water', 'burger', 'bandage', 'phone', 'lockpick', 'scrap', 'watch', 'passport']);
  function drawItemIcon(node, item) {
    node.querySelector('.item-icon use').setAttribute('href', '#item-' + (itemIcons.has(item) ? item : 'package'));
  }

  let waiting = false;

  // How many times the page has been closed. Pressing Counter and then Escape
  // before the counter answered closed the page and gave the mouse back to the
  // game, and then the answer arrived and put the shop up anyway: a panel over
  // the city with no cursor to close it with. An answer to a question asked
  // before the last close is for a screen nobody is looking at, and is dropped.
  let generation = 0;

  // ------------------------------------------------------------------- talk

  /* Ask the Lua side for something. It answers { ok, message, view } and never
     a refusal code, so there is no code here to branch on one. Null means there
     is nothing to do: a question already in flight, or an answer that arrived
     after the page closed. */
  async function ask(action, payload) {
    if (waiting) return null;
    const asked = generation;
    waiting = true;
    for (const screen of screens) screen.classList.add('waiting');
    try {
      const response = await fetch(`https://${RESOURCE}/${action}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(payload || {}),
      });
      const answer = await response.json();
      return asked === generation ? answer : null;
    } catch (err) {
      if (asked !== generation) return null;
      // The page could not reach its own resource. That is not a refusal and
      // pretending it is would be a lie about what happened.
      return { ok: false, message: 'The game did not answer.' };
    } finally {
      waiting = false;
      for (const screen of screens) screen.classList.remove('waiting');
    }
  }

  /* A list the Lua side sent, or an empty one. A Lua table with nothing in it
     cannot say it is a list and can arrive as {}, which has no .includes and
     cannot be walked: Around you threw on the first row with nothing to offer
     and drew three rows of seven. So no list is read here unless it is one. */
  function listOf(value) {
    return Array.isArray(value) ? value : [];
  }

  function sayOn(node, line, good) {
    if (!line) {
      node.hidden = true;
      node.textContent = '';
      return;
    }
    node.textContent = line;
    node.classList.toggle('good', good === true);
    node.hidden = false;
  }

  function show(screen) {
    for (const other of screens) other.hidden = other !== screen;
  }

  // ----------------------------------------------------------- asking twice
  //
  // Retiring somebody and buying a door cannot be undone, so each asks twice.
  // The two presses were any two clicks, and a double-click is two clicks: it
  // asked the question and answered it inside a fifth of a second, and retired
  // a character or bought a flat with no second thought in it. The question
  // also stayed asked for good, so a stray press minutes later was the answer.
  //
  // So a second press counts only once the question has been on screen long
  // enough to read, and a question nobody answers takes itself back. Both
  // numbers are about people, not rules: the server still decides whether
  // either thing may happen.
  const CONFIRM_AFTER_MS = 400;
  const CONFIRM_FOR_MS = 3000;
  const armed = new Map();   // button -> { at, timer, label }

  function asksTwice(button, act) {
    button.addEventListener('click', () => {
      const question = armed.get(button);
      if (!question) {
        unconfirm();
        armed.set(button, {
          at: Date.now(),
          label: button.textContent,
          timer: setTimeout(() => disarm(button), CONFIRM_FOR_MS),
        });
        button.classList.add('confirming');
        // The line under an armed button runs out in the time it stays armed.
        button.style.setProperty('--confirm-for', `${CONFIRM_FOR_MS}ms`);
        button.textContent = 'Sure?';
        return;
      }
      // The second click of the same double-click, not an answer.
      if (Date.now() - question.at < CONFIRM_AFTER_MS) return;
      disarm(button);
      act();
    });
  }

  function disarm(button) {
    const question = armed.get(button);
    if (!question) return;
    armed.delete(button);
    clearTimeout(question.timer);
    button.classList.remove('confirming');
    button.textContent = question.label;
  }

  /* Take back every question asked and not yet answered. */
  function unconfirm() {
    for (const button of [...armed.keys()]) disarm(button);
  }

  // ------------------------------------------------------------- the picker

  const list = document.getElementById('list');
  const rowTemplate = document.getElementById('row');
  const emptyLine = document.getElementById('empty');
  const count = document.getElementById('count');
  const message = document.getElementById('message');
  const form = document.getElementById('new-person');
  const first = document.getElementById('first');
  const last = document.getElementById('last');

  function say(line, good) { sayOn(message, line, good); }

  function handle(answer) {
    if (!answer) return;
    say(answer.message, answer.ok);
    if (answer.view) draw(answer.view);
  }

  function draw(view) {
    list.textContent = '';
    const people = Array.isArray(view.people) ? view.people : [];

    for (const person of people) {
      const row = rowTemplate.content.firstElementChild.cloneNode(true);
      row.querySelector('.name').textContent = person.name || '';
      row.querySelector('.note').textContent = person.note || '';
      row.querySelector('.money').textContent = person.money || '';
      if (person.playing) row.classList.add('playing');

      const play = row.querySelector('.play');
      play.textContent = person.playing ? 'Resume' : 'Play';
      play.addEventListener('click', () => {
        handle_then_close(ask('select', { character: person.character }));
      });

      // Retiring is the one thing here that cannot be undone, so it asks
      // twice. The second press is the answer; anything else takes it back.
      const retire = row.querySelector('.retire');
      asksTwice(retire, () => {
        ask('retire', { character: person.character }).then(handle);
      });

      list.appendChild(row);
    }

    emptyLine.hidden = people.length !== 0;
    // A count to read, not a rule. The form below stays available whatever
    // this says; whether another person can be made is the server's answer.
    count.textContent = typeof view.limit === 'number' && view.limit > 0
      ? `${view.used} of ${view.limit}`
      : '';
  }

  async function handle_then_close(pending) {
    const answer = await pending;
    handle(answer);
    if (answer && answer.ok) close();
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    unconfirm();
    // Sent as typed. Whether it is a name is decided by the server, which has
    // the pattern and refuses in its own words.
    handle_then_close(ask('create', {
      first_name: first.value,
      last_name: last.value,
    }).then((answer) => {
      if (answer && answer.ok) { first.value = ''; last.value = ''; }
      return answer;
    }));
  });

  // ------------------------------------------------------------- pockets
  //
  // A grid, because that is how somebody looks for a thing they own: by shape
  // and position, not by reading a list top to bottom.

  const grid = document.getElementById('grid');
  const slotTemplate = document.getElementById('slot');
  const pocketsEmpty = document.getElementById('pockets-empty');
  const pocketsMessage = document.getElementById('pockets-message');
  const carryAct = document.getElementById('carry-act');
  const carryName = document.getElementById('carry-name');
  const carryCount = document.getElementById('carry-count');

  let picked = null;

  function drawPockets(view) {
    grid.textContent = '';
    const items = Array.isArray(view.items) ? view.items : [];
    for (const row of items) {
      const slot = slotTemplate.content.firstElementChild.cloneNode(true);
      drawItemIcon(slot, row.item);
      slot.tabIndex = 0;
      slot.querySelector('.slot-label').textContent = row.label || row.item || '';
      slot.querySelector('.slot-stack').textContent = row.stack || '';
      if (picked && picked.item === row.item) slot.classList.add('picked');
      const choose = () => pick(row);
      slot.addEventListener('click', choose);
      slot.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          choose();
        }
      });
      grid.appendChild(slot);
    }

    pocketsEmpty.hidden = items.length !== 0;
    document.getElementById('pockets-slots').textContent =
      `${view.slots_used || 0} of ${view.slots || 0} slots`;
    document.getElementById('pockets-weight').textContent =
      `${view.weight || '0g'} of ${view.capacity || '0g'}`;

    // A proportion drawn, never a rule. Whether one more thing fits is
    // answered by the server refusing to put it there.
    const bar = document.getElementById('pockets-bar');
    const full = typeof view.full === 'number' ? Math.max(0, Math.min(100, view.full)) : 0;
    bar.style.width = `${full}%`;
    bar.classList.toggle('heavy', full >= 90);

    // Whatever was picked may have just been dropped.
    if (picked && !items.some((row) => row.item === picked.item)) unpick();
  }

  function pick(row) {
    picked = row;
    carryName.textContent = row.label || row.item;
    carryCount.value = '1';
    carryAct.hidden = false;
    for (const slot of grid.querySelectorAll('.slot')) {
      const label = slot.querySelector('.slot-label').textContent;
      slot.classList.toggle('picked', label === (row.label || row.item));
    }
  }

  function unpick() {
    picked = null;
    carryAct.hidden = true;
    for (const slot of grid.querySelectorAll('.slot')) slot.classList.remove('picked');
  }

  async function actOnCarried(action, payload) {
    if (!picked) return;
    const answer = await ask(action, payload);
    if (!answer) return;
    sayOn(pocketsMessage, answer.message, answer.ok);
    if (answer.view) drawPockets(answer.view);
  }

  document.getElementById('carry-cancel').addEventListener('click', unpick);

  document.getElementById('carry-form').addEventListener('submit', (event) => {
    event.preventDefault();
    // Sent as typed. Whether that many exist is the server's answer.
    actOnCarried('drop', { item: picked && picked.item, count: carryCount.value });
  });

  document.getElementById('carry-use').addEventListener('click', () => {
    actOnCarried('use', { item: picked && picked.item });
  });

  // --------------------------------------------------------------- phone

  const threadList = document.getElementById('threads');
  const threadTemplate = document.getElementById('thread-row');
  const messageList = document.getElementById('messages');
  const messageTemplate = document.getElementById('message-row');
  const phoneEmpty = document.getElementById('phone-empty');
  const phoneMessage = document.getElementById('phone-message');
  const conversationWith = document.getElementById('conversation-with');
  const conversationEmpty = document.getElementById('conversation-empty');
  const sendForm = document.getElementById('phone-send');

  let talkingTo = null;

  function drawPhone(view) {
    const inbox = view.inbox || { threads: [] };
    document.getElementById('phone-number').textContent = inbox.number || '';

    // Who is being read has to be known before the list is built, or the row
    // for the open conversation is drawn unmarked and nothing on screen says
    // which of them you are looking at.
    talkingTo = (view.thread && view.thread.with) || null;

    threadList.textContent = '';
    const threads = Array.isArray(inbox.threads) ? inbox.threads : [];
    for (const row of threads) {
      const node = threadTemplate.content.firstElementChild.cloneNode(true);
      node.querySelector('.thread-number').textContent = row.number || '';
      node.querySelector('.thread-last').textContent = row.last || '';
      node.querySelector('.thread-when').textContent = row.when || '';
      if (row.outgoing) node.classList.add('outgoing');
      if (row.number === talkingTo) node.classList.add('picked');
      node.addEventListener('click', () => openThread(row.number));
      node.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          openThread(row.number);
        }
      });
      threadList.appendChild(node);
    }
    phoneEmpty.hidden = threads.length !== 0;
    drawThread(view.thread);
  }

  function drawThread(thread) {
    messageList.textContent = '';
    if (!thread || !thread.with) {
      talkingTo = null;
      conversationWith.textContent = 'Nobody';
      conversationEmpty.textContent = 'Pick a number, or type one.';
      conversationEmpty.hidden = false;
      sendForm.hidden = true;
      return;
    }

    talkingTo = thread.with;
    conversationWith.textContent = thread.with;
    sendForm.hidden = false;

    const messages = Array.isArray(thread.messages) ? thread.messages : [];
    for (const row of messages) {
      const node = messageTemplate.content.firstElementChild.cloneNode(true);
      node.querySelector('.msg-body').textContent = row.body || '';
      node.querySelector('.msg-when').textContent = row.when || '';
      if (row.mine) node.classList.add('mine');
      messageList.appendChild(node);
    }
    conversationEmpty.textContent = 'Nothing said yet.';
    conversationEmpty.hidden = messages.length !== 0;
    // A conversation reads from the bottom, like every other one.
    messageList.scrollTop = messageList.scrollHeight;
  }

  async function openThread(number) {
    const answer = await ask('thread', { with: number });
    if (!answer) return;
    sayOn(phoneMessage, answer.message, answer.ok);
    if (answer.view) drawPhone(answer.view);
  }

  document.getElementById('phone-new').addEventListener('submit', (event) => {
    event.preventDefault();
    const to = document.getElementById('phone-to').value.trim();
    if (to) openThread(to);
  });

  sendForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const body = document.getElementById('phone-body');
    if (!talkingTo) return;
    const answer = await ask('send', { to: talkingTo, body: body.value });
    if (!answer) return;
    sayOn(phoneMessage, answer.message, answer.ok);
    if (answer.ok) body.value = '';
    if (answer.view) drawPhone(answer.view);
  });

  // ------------------------------------------------------------ the counter
  //
  // A price list is a table because that is what a price list is: rows of the
  // same three facts, read down a column.

  const priceBody = document.getElementById('prices');
  const priceTemplate = document.getElementById('price-row');
  const shopEmpty = document.getElementById('shop-empty');
  const shopMessage = document.getElementById('shop-message');
  const deal = document.getElementById('deal');
  const dealName = document.getElementById('deal-name');
  const dealCount = document.getElementById('deal-count');

  let atShop = null;
  let dealing = null;

  function drawShop(view) {
    document.getElementById('shop-name').textContent = view.name || 'Shop';
    document.getElementById('shop-state').textContent = view.shut ? 'Shut' : '';
    priceBody.textContent = '';
    const lines = Array.isArray(view.lines) ? view.lines : [];
    for (const row of lines) {
      const node = priceTemplate.content.firstElementChild.cloneNode(true);
      drawItemIcon(node, row.item);
      node.querySelector('.price-label').textContent = row.label || row.item || '';
      // A dash, not a zero. A shop that will not sell a thing has no price for
      // it, and printing $0.00 would say something untrue.
      node.querySelector('.price-buy').textContent = row.buy || '--';
      node.querySelector('.price-sell').textContent = row.sell || '--';
      node.querySelector('.price-stock').textContent = String(row.stock);
      if (row.bare) node.classList.add('bare');
      if (dealing && dealing.item === row.item) node.classList.add('picked');
      node.querySelector('.price-pick').addEventListener('click', () => pickDeal(row));
      priceBody.appendChild(node);
    }
    shopEmpty.hidden = lines.length !== 0;
    if (dealing && !lines.some((row) => row.item === dealing.item)) cancelDeal();
  }

  function pickDeal(row) {
    dealing = row;
    dealName.textContent = row.label || row.item;
    dealCount.value = '1';
    deal.hidden = false;
    for (const node of priceBody.querySelectorAll('.price')) {
      node.classList.toggle('picked',
        node.querySelector('.price-label').textContent === (row.label || row.item));
    }
  }

  function cancelDeal() {
    dealing = null;
    deal.hidden = true;
    for (const node of priceBody.querySelectorAll('.price')) node.classList.remove('picked');
  }

  async function trade(action) {
    if (!dealing || !atShop) return;
    // The buyer never says what anything costs. There is no price to send.
    const answer = await ask(action, { shop: atShop, item: dealing.item, count: dealCount.value });
    if (!answer) return;
    sayOn(shopMessage, answer.message, answer.ok);
    if (answer.view) drawShop(answer.view);
  }

  document.getElementById('deal-cancel').addEventListener('click', cancelDeal);
  document.getElementById('deal-form').addEventListener('submit', (event) => {
    event.preventDefault();
    trade('buy');
  });
  document.getElementById('deal-sell').addEventListener('click', () => trade('sell'));

  // --------------------------------------------------------------- a stash

  const here = document.getElementById('here');
  const there = document.getElementById('there');
  const hereEmpty = document.getElementById('here-empty');
  const thereEmpty = document.getElementById('there-empty');
  const stashMessage = document.getElementById('stash-message');
  const shift = document.getElementById('shift');
  const shiftName = document.getElementById('shift-name');
  const shiftCount = document.getElementById('shift-count');
  const shiftGo = document.getElementById('shift-go');

  let pocketsId = null;
  let stashId = null;
  let shifting = null;

  function fillSide(node, emptyLine, side, from, to) {
    node.textContent = '';
    const items = (side && Array.isArray(side.items)) ? side.items : [];
    for (const row of items) {
      const slot = slotTemplate.content.firstElementChild.cloneNode(true);
      drawItemIcon(slot, row.item);
      slot.tabIndex = 0;
      slot.querySelector('.slot-label').textContent = row.label || row.item || '';
      slot.querySelector('.slot-stack').textContent = row.stack || '';
      if (shifting && shifting.item === row.item && shifting.from === from) {
        slot.classList.add('picked');
      }
      const choose = () => pickShift(row, from, to);
      slot.addEventListener('click', choose);
      slot.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); choose(); }
      });
      node.appendChild(slot);
    }
    emptyLine.hidden = items.length !== 0;
  }

  function drawStash(view) {
    pocketsId = view.pockets_id || null;
    stashId = view.stash_id || null;
    document.getElementById('stash-address').textContent = view.address || '';
    fillSide(here, hereEmpty, view.here, pocketsId, stashId);
    fillSide(there, thereEmpty, view.there, stashId, pocketsId);
    document.getElementById('here-load').textContent =
      view.here ? `${view.here.weight} of ${view.here.capacity}` : '';
    document.getElementById('there-load').textContent =
      view.there ? `${view.there.weight} of ${view.there.capacity}` : '';
    const sides = [view.here, view.there];
    if (shifting && !sides.some((side) =>
        side && Array.isArray(side.items) && side.items.some((row) => row.item === shifting.item))) {
      cancelShift();
    }
  }

  function pickShift(row, from, to) {
    shifting = { item: row.item, label: row.label, from, to };
    shiftName.textContent = row.label || row.item;
    shiftGo.textContent = from === pocketsId ? 'Put down' : 'Pick up';
    shiftCount.value = '1';
    shift.hidden = false;
    for (const slot of document.querySelectorAll('#here .slot, #there .slot')) {
      slot.classList.remove('picked');
    }
    const side = from === pocketsId ? here : there;
    for (const slot of side.querySelectorAll('.slot')) {
      if (slot.querySelector('.slot-label').textContent === (row.label || row.item)) {
        slot.classList.add('picked');
      }
    }
  }

  function cancelShift() {
    shifting = null;
    shift.hidden = true;
    for (const slot of document.querySelectorAll('#here .slot, #there .slot')) {
      slot.classList.remove('picked');
    }
  }

  document.getElementById('shift-cancel').addEventListener('click', cancelShift);

  document.getElementById('shift-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!shifting) return;
    const answer = await ask('stow', {
      from: shifting.from, to: shifting.to,
      item: shifting.item, count: shiftCount.value,
    });
    if (!answer) return;
    sayOn(stashMessage, answer.message, answer.ok);
    if (answer.view) drawStash(answer.view);
  });

  // ------------------------------------------------------------ around you

  const around = document.getElementById('around');
  const placeTemplate = document.getElementById('place-row');
  const nearbyEmpty = document.getElementById('nearby-empty');
  const nearbyMessage = document.getElementById('nearby-message');

  function drawNearby(view) {
    around.textContent = '';
    const shops = Array.isArray(view.shops) ? view.shops : [];
    const places = Array.isArray(view.places) ? view.places : [];

    for (const row of shops) {
      const node = placeTemplate.content.firstElementChild.cloneNode(true);
      node.querySelector('.place-what').textContent = row.name || row.shop;
      // Words, from nui_state. The page printed the server's keys.
      node.querySelector('.place-where').textContent = row.where || '';
      if (row.shut) node.classList.add('shut');
      const go = node.querySelector('.place-go');
      go.textContent = 'Counter';
      // The page always offers the door. Whether it opens is the server's.
      go.addEventListener('click', async () => {
        const answer = await ask('shop', { shop: row.shop });
        if (!answer) return;
        sayOn(nearbyMessage, answer.message, answer.ok);
        if (answer.ok && answer.view) {
          atShop = row.shop;
          cancelDeal();
          show(shop);
          drawShop(answer.view);
          sayOn(shopMessage, null);
        }
      });
      around.appendChild(node);
    }

    for (const row of places) {
      const node = placeTemplate.content.firstElementChild.cloneNode(true);
      node.querySelector('.place-what').textContent = row.address || row.place;
      node.querySelector('.place-where').textContent = row.where || '';

      // What it costs, where a player can see it. This screen is the only
      // thing that ever says an address exists, and it used to say the name
      // and not the price -- so a flat on the market looked exactly like one
      // somebody already lived in, and the only door it offered was the one
      // that was locked.
      const price = node.querySelector('.place-price');
      const buy = node.querySelector('.place-buy');
      // Absent is an older server, which offered the door and nothing else.
      const offers = (row.offers === undefined || row.offers === null) ? null : listOf(row.offers);
      if (offers !== null && offers.includes('purchase') && row.price) {
        price.textContent = row.price;
        price.hidden = false;
        buy.hidden = false;
        // Money that cannot be got back, so it asks twice -- the same as
        // retiring somebody. The second press is the answer.
        asksTwice(buy, async () => {
          // The address, and nothing else. What it costs is what the city is
          // asking, and a page edited to send a smaller number sends a field
          // this action does not take and is refused for it.
          const answer = await ask('purchase', { place: row.place });
          if (!answer) return;
          sayOn(nearbyMessage, answer.message, answer.ok);
          if (answer.view) drawNearby(answer.view);
        });
      }

      // Only what the view says this row may offer. The page used to draw a
      // Go in on every place it was given, which on a seeded city meant four
      // rows out of seven carrying a button property.enter refuses every time.
      const go = node.querySelector('.place-go');
      const mayEnter = offers === null || offers.includes('enter');
      go.hidden = !mayEnter;
      go.textContent = 'Go in';
      go.addEventListener('click', async () => {
        const answer = await ask('enter', { place: row.place });
        if (!answer) return;
        sayOn(nearbyMessage, answer.message, answer.ok);
        if (answer.ok && answer.view) {
          cancelShift();
          show(stash);
          drawStash(answer.view);
          sayOn(stashMessage, null);
        }
      });
      around.appendChild(node);
    }

    nearbyEmpty.hidden = (shops.length + places.length) !== 0;
  }

  // --------------------------------------------------------------- closing

  document.getElementById('close').addEventListener('click', close);
  for (const button of document.querySelectorAll('.close-screen')) {
    button.addEventListener('click', close);
  }

  document.addEventListener('keyup', (event) => {
    if (event.key === 'Escape') close();
  });

  /* Close whatever is up. There is one focus to give back and one message to
     send, however many screens this page has. */
  function close() {
    generation += 1;
    for (const screen of screens) screen.hidden = true;
    unconfirm();
    unpick();
    cancelDeal();
    cancelShift();
    atShop = null;
    say(null);
    for (const node of [pocketsMessage, phoneMessage, shopMessage, stashMessage, nearbyMessage]) {
      sayOn(node, null);
    }
    fetch(`https://${RESOURCE}/close`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: '{}',
    }).catch(() => {});
  }

  // ----------------------------------------------------------------- bank

  const bankNumber = document.getElementById('bank-number');
  const bankBalance = document.getElementById('bank-balance');
  const bankCounter = document.getElementById('bank-counter');
  const bankAmount = document.getElementById('bank-amount');
  const bankOpen = document.getElementById('bank-open');
  const bankLines = document.getElementById('bank-lines');
  const bankEmpty = document.getElementById('bank-empty');
  const bankMessage = document.getElementById('bank-message');
  const bankLine = document.getElementById('bank-line');
  let atBranch = null;

  function drawBank(view) {
    bankNumber.textContent = view.number || '';
    bankBalance.textContent = view.balance || '';
    // An account this person does not have is a thing to draw and a reason to
    // offer opening one, not a missing screen.
    bankOpen.hidden = view.open === true;
    bankCounter.hidden = view.open !== true;

    bankLines.textContent = '';
    const lines = listOf(view.lines);
    for (const row of lines) {
      const node = bankLine.content.firstElementChild.cloneNode(true);
      node.querySelector('.place-what').textContent = row.label || row.reason || 'Moved';
      node.querySelector('.place-where').textContent = row.reference || '';
      node.querySelector('.place-price').textContent = row.amount;
      if (!row.incoming) node.classList.add('out');
      bankLines.appendChild(node);
    }
    bankEmpty.hidden = lines.length !== 0;
  }

  // The page never says what it is worth, only how much to move. Whether the
  // money is there is the ledger's answer, not this input's. What was typed goes
  // as typed: dollars, turned into cents in nui_state where a spec reads it, and
  // never rounded here -- 200.50 cut to 200 is fifty cents nobody asked to lose.
  function amountAsked() {
    const typed = (bankAmount.value || '').trim();
    return typed === '' ? null : typed;
  }

  async function bankDo(action) {
    if (!atBranch) return;
    const payload = { branch: atBranch };
    if (action !== 'account') {
      const amount = amountAsked();
      if (amount === null) { sayOn(bankMessage, 'How much?', false); return; }
      payload.amount = String(amount);
    }
    const answer = await ask(action, payload);
    if (!answer) return;
    sayOn(bankMessage, answer.message, answer.ok);
    if (answer.ok) bankAmount.value = '';
    if (answer.view) drawBank(answer.view);
  }

  bankOpen.addEventListener('click', () => bankDo('account'));
  document.getElementById('bank-deposit').addEventListener('click', () => bankDo('deposit'));
  document.getElementById('bank-withdraw').addEventListener('click', () => bankDo('withdraw'));

  // ----------------------------------------------------------------- work

  const jobsList = document.getElementById('jobs-list');
  const jobsEmpty = document.getElementById('jobs-empty');
  const jobsDoing = document.getElementById('jobs-doing');
  const jobsShift = document.getElementById('jobs-shift');
  const jobsMessage = document.getElementById('jobs-message');
  const jobRow = document.getElementById('job-row');

  function drawJobs(view) {
    jobsList.textContent = '';
    jobsDoing.textContent = view.working ? `On a shift: ${view.working_label || view.working}` : '';
    jobsShift.hidden = !view.working;

    const employers = listOf(view.employers);
    for (const employer of employers) {
      for (const job of listOf(employer.jobs)) {
        const node = jobRow.content.firstElementChild.cloneNode(true);
        node.querySelector('.place-what').textContent = job.label;
        node.querySelector('.place-where').textContent = job.where || employer.name || '';
        node.querySelector('.place-price').textContent = job.pay;
        if (!employer.hiring || job.waiting) node.classList.add('shut');
        // The row is always offered. Whether this person may take it on is
        // work.start refusing, which is the rule every screen here keeps.
        node.querySelector('.job-take').addEventListener('click', async () => {
          const answer = await ask('clockon',
            { employer: employer.employer, job: job.job });
          if (!answer) return;
          sayOn(jobsMessage, answer.message, answer.ok);
          if (answer.view) drawJobs(answer.view);
        });
        jobsList.appendChild(node);
      }
    }
    jobsEmpty.hidden = employers.length !== 0;
  }

  async function shiftDo(action) {
    const answer = await ask(action, {});
    if (!answer) return;
    sayOn(jobsMessage, answer.message, answer.ok);
    if (answer.view) drawJobs(answer.view);
  }

  document.getElementById('jobs-finish').addEventListener('click', () => shiftDo('clockoff'));
  document.getElementById('jobs-abandon').addEventListener('click', () => shiftDo('walkoff'));

  // ------------------------------------------------------------- being told

  window.addEventListener('message', (event) => {
    const data = event.data || {};
    if (data.type === 'picker') {
      show(picker);
      say(data.message || null, data.ok);
      draw(data.view || { people: [] });
      // Focus the first empty box so somebody with no people can just type.
      if (data.view && data.view.empty) setTimeout(() => first.focus(), 60);
    } else if (data.type === 'pockets') {
      show(pockets);
      unpick();
      drawPockets(data.view || {});
      sayOn(pocketsMessage, data.message || null, data.ok);
    } else if (data.type === 'phone') {
      show(phone);
      drawPhone(data.view || {});
      sayOn(phoneMessage, data.message || null, data.ok);
    } else if (data.type === 'shop') {
      show(shop);
      atShop = data.shop || atShop;
      cancelDeal();
      drawShop(data.view || {});
      sayOn(shopMessage, data.message || null, data.ok);
    } else if (data.type === 'stash') {
      show(stash);
      cancelShift();
      drawStash(data.view || {});
      sayOn(stashMessage, data.message || null, data.ok);
    } else if (data.type === 'bank') {
      show(bank);
      atBranch = data.branch || atBranch;
      drawBank(data.view || {});
      sayOn(bankMessage, data.message || null, data.ok);
    } else if (data.type === 'jobs') {
      show(jobs);
      drawJobs(data.view || {});
      sayOn(jobsMessage, data.message || null, data.ok);
    } else if (data.type === 'nearby') {
      show(nearby);
      drawNearby(data.view || {});
      sayOn(nearbyMessage, data.message || null, data.ok);
    } else if (data.type === 'hide') {
      // Closed from the Lua side, by a key: the same as Escape for anything
      // still being answered.
      generation += 1;
      for (const screen of screens) screen.hidden = true;
      unconfirm();
      unpick();
      cancelDeal();
      cancelShift();
      say(null);
      for (const node of [pocketsMessage, phoneMessage, shopMessage, stashMessage,
                          nearbyMessage, bankMessage, jobsMessage]) {
        sayOn(node, null);
      }
    } else if (data.type === 'message') {
      say(data.message || null, data.ok);
    }
  });
})();
