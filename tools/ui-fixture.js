/* Development fixture only. Injected by preview.py; never loaded by FiveM.
   The views are shaped the way adapter/nui_state.lua builds them, words and
   all, so the preview draws what a player would. */
(() => {
  const pockets = {items:[{item:'water',label:'Bottle of Water',count:3,stack:'3'},{item:'burger',label:'Burger',count:2,stack:'2'},{item:'bandage',label:'Bandage',count:1}],slots_used:3,slots:20,weight:'1.8kg',capacity:'20kg',full:9};
  const picker = {people:[{character:'demo_jane',name:'Jane Mercer',money:'$500.00',playing:true},{character:'demo_eli',name:'Eli Navarro',money:'$245.00',playing:false,note:'in hospital'}],used:2,limit:3};
  const counter = {name:'Corner shop',state:'open',lines:[{item:'water',label:'Bottle of Water',buy:'$3.00',sell:'$1.00',stock:40},{item:'burger',label:'Burger',buy:'$8.00',sell:'$3.00',stock:12},{item:'bandage',label:'Bandage',buy:'$15.00',stock:0,bare:true}]};
  const nearby = {shops:[{shop:'demo_shop',name:'Corner shop',where:'Shop',offers:['shop']}],places:[
    {place:'demo_home',address:'An apartment on the block',kind:'apartment',mine:true,may_enter:true,where:'Yours',offers:['enter']},
    {place:'demo_flat',address:'Alta Street, Apt 57',kind:'apartment',for_sale:true,price:'$3,200.00',where:'Apartment · for sale',offers:['purchase','enter']},
    {place:'demo_branch',address:'Pillbox Hill Branch',kind:'bank',where:'Bank branch',offers:[]}]};
  const bank = {open:true,number:'NYR-EEEF-A6GE',balance:'$390.00',state:'open',lines:[
    {sequence:1,amount:'$450.00',incoming:true,reason:'deposit',label:'Paid in'},
    {sequence:2,amount:'-$60.00',incoming:false,reason:'withdrawal',label:'Taken out'}]};
  const jobs = {employers:[
    {employer:'demo_post',name:'Postal OP',hiring:true,jobs:[{job:'delivery',label:'Delivery Driver',pay:'$120.00',minutes:12,ready_in:0,where:'Postal OP · 12 min'}]},
    {employer:'demo_docks',name:'Vespucci Docks',hiring:true,jobs:[{job:'crates',label:'Crate Loader',pay:'$150.00',minutes:20,ready_in:6,waiting:'6 min',where:'Vespucci Docks · 20 min · ready in 6 min'}]}]};
  const fixtures = {
    picker:{type:'picker',view:picker},
    pockets:{type:'pockets',view:pockets},
    phone:{type:'phone',view:{inbox:{number:'555-014200',threads:[{number:'555-014201',last:'Meet me by the corner shop.',when:'day 1, 20:14',outgoing:false},{number:'555-014202',last:'Your keys are ready.',when:'day 1, 18:32',outgoing:false}]}}},
    shop:{type:'shop',shop:'demo_shop',view:counter},
    stash:{type:'stash',view:{here:pockets,there:{items:[{item:'water',label:'Bottle of Water',count:6,stack:'6'}],slots_used:1,slots:40,weight:'3kg',capacity:'100kg',full:3},pockets_id:'demo_pockets',stash_id:'demo_stash',address:'An apartment on the block'}},
    nearby:{type:'nearby',view:nearby},
    bank:{type:'bank',branch:'demo_branch',view:bank},
    jobs:{type:'jobs',view:jobs}
  };
  const log = [];
  window.fetch = async (url, opts) => {
    const action = String(url).split('/').pop();
    const payload = JSON.parse(opts?.body || '{}');
    log.push({action,payload});
    parent.postMessage({type:'fixture-request',request:{action,payload}},location.origin);
    let view;
    if(action==='retire') { picker.people=picker.people.filter(p=>p.character!==payload.character); picker.used=picker.people.length; view=picker; }
    if(action==='thread') {
      fixtures.phone.view.thread={with:payload.with||payload.number||'555-014201',messages:[{body:'Meet me by the corner shop.',when:'day 1, 20:14',mine:false},{body:'On my way.',when:'day 1, 20:15',mine:true}]};
      view=fixtures.phone.view;
    }
    if(action==='send') {
      fixtures.phone.view.thread.messages.push({body:payload.body,when:'preview',mine:true});
      view=fixtures.phone.view;
    }
    if(action==='shop' || action==='buy' || action==='sell') view=counter;
    if(action==='enter') view=fixtures.stash.view;
    if(action==='deposit' || action==='withdraw' || action==='account') view=bank;
    if(action==='clockon') view=Object.assign({},jobs,{working:'delivery',working_label:'Delivery Driver'});
    if(action==='clockoff' || action==='walkoff') view=jobs;
    if(action==='purchase') view=nearby;
    return {json:async()=>({ok:true,message:'Preview response — no game state changed.',view})};
  };
  window.addEventListener('load',()=>{
    const params=new URLSearchParams(location.search);
    const screen=params.get('screen')||'picker';
    if(params.get('icons')==='all') {
      pockets.items=[['water','Bottle of Water'],['burger','Burger'],['bandage','Bandage'],['phone','Phone'],['lockpick','Lockpick'],['scrap','Scrap Metal'],['watch','Gold Watch'],['passport','Passport'],['custom','Custom item']].map(([item,label])=>({item,label,count:1}));
      pockets.slots_used=pockets.items.length;
    }
    window.postMessage(fixtures[screen]||fixtures.picker,location.origin);
  });
})();
