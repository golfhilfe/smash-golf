// Smash Golf: searchable home-club picker.
// Attaches to the "Home club" inputs (#r-club on the join form, #p-club in the profile dialog).
// The input stays a plain text field, so a club that is not in the list can still be typed in.
// Club data lives in clubs.js (window.SG_CLUBS).
(function(){
"use strict";
const TARGETS = ["r-club","p-club"];
const MAX_RESULTS = 60;

const TXT = {
  en:{ near:"Near Vienna", SI:"Slovenia", AT:"Austria", DE:"Germany", IT:"Italy", all:"All",
       none:"No club found. Just keep typing: your own entry is saved as written.",
       hint:"Not in the list? Just type your club's name.", more:"{n} more, keep typing to narrow down", ph:"Search or type your club" },
  de:{ near:"Rund um Wien", SI:"Slowenien", AT:"Österreich", DE:"Deutschland", IT:"Italien", all:"Alle",
       none:"Kein Club gefunden. Einfach weiterschreiben: Ihr Eintrag wird so gespeichert.",
       hint:"Nicht in der Liste? Einfach den Clubnamen eintippen.", more:"{n} weitere, weitertippen zum Eingrenzen", ph:"Club suchen oder eintippen" },
  sl:{ near:"Okolica Dunaja", SI:"Slovenija", AT:"Avstrija", DE:"Nemčija", IT:"Italija", all:"Vsi",
       none:"Ni zadetkov. Kar pišite naprej: vnos se shrani, kot je napisan.",
       hint:"Kluba ni na seznamu? Preprosto vpišite ime.", more:"Še {n}, pišite naprej za ožji izbor", ph:"Poiščite ali vpišite klub" },
  it:{ near:"Vicino a Vienna", SI:"Slovenia", AT:"Austria", DE:"Germania", IT:"Italia", all:"Tutti",
       none:"Nessun circolo trovato. Continua a scrivere: il testo viene salvato così.",
       hint:"Non è in elenco? Scrivi semplicemente il nome del circolo.", more:"Altri {n}, continua a scrivere per restringere", ph:"Cerca o scrivi il circolo" }
};
const FLAG = { AT:"AT", SI:"SI", DE:"DE", IT:"IT" };
const SCOPES = ["all","near","SI","AT","DE","IT"];

function lang(){ const l=(document.documentElement.lang||"en").slice(0,2); return TXT[l]?l:"en"; }
function tr(k,vars){ let s=TXT[lang()][k]||TXT.en[k]; if(vars) for(const v in vars) s=s.replace("{"+v+"}",vars[v]); return s; }
const fold = s => String(s||"").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g,"").replace(/ß/g,"ss").replace(/([aou])e/g,"$1").replace(/[^a-z0-9]+/g," ").trim(); // "muenchen" finds "München"

// ---- data ----
let DATA=null;
function data(){
  if(DATA) return DATA;
  const src=window.SG_CLUBS||{};
  const all=[];
  ["SI","AT","DE","IT"].forEach(cc=>{
    (src[cc]||[]).forEach(row=>{
      const [name,town]=String(row).split("|").map(s=>s.trim());
      if(name) all.push({name, town:town||"", cc, key:fold(name+" "+(town||""))});
    });
  });
  const near=(src.near||[]).map(n=>all.find(c=>c.name===n)).filter(Boolean);
  DATA={all, near};
  return DATA;
}
function listFor(scope, q){
  const d=data();
  const words=fold(q).split(" ").filter(Boolean);
  let pool;
  if(!words.length){
    if(scope==="near") return [{head:tr("near"), items:d.near}];
    if(scope==="all") return [{head:tr("near"), items:d.near}, {head:tr("SI"), items:d.all.filter(c=>c.cc==="SI")}];
    return [{head:tr(scope), items:d.all.filter(c=>c.cc===scope)}];
  }
  pool = scope==="all" ? d.all : scope==="near" ? d.near : d.all.filter(c=>c.cc===scope);
  const hits=pool.filter(c=>words.every(w=>c.key.includes(w)));
  // rank: name starts with query, then word starts, then the rest; nearer countries first
  const q1=words.join(" "), order={SI:0,AT:1,DE:2,IT:3};
  const nearSet=new Set(d.near);
  const score=c=>{ const n=fold(c.name); return (nearSet.has(c)?0:10)+(n.startsWith(q1)?0:(" "+n).includes(" "+words[0])?1:2)*100+order[c.cc]; };
  hits.sort((a,b)=>score(a)-score(b)||a.name.localeCompare(b.name));
  return [{head:null, items:hits}];
}

// ---- styles (use the app's tokens) ----
const css=`
.cp-wrap{position:relative}
.cp-panel{position:absolute;z-index:40;left:0;right:0;top:calc(100% + 4px);background:var(--surface);color:var(--ink);border:1px solid var(--line);border-radius:10px;box-shadow:0 10px 28px rgba(6,17,31,.22);overflow:hidden;min-width:min(320px,calc(100vw - 32px))}
.cp-scopes{display:flex;gap:4px;padding:8px;border-bottom:1px solid var(--line);overflow-x:auto;background:var(--surface-2)}
.cp-scope{border:1px solid var(--line);background:var(--surface);border-radius:999px;padding:3px 10px;font-size:12px;font-weight:600;cursor:pointer;white-space:nowrap;color:var(--muted);-webkit-tap-highlight-color:transparent}
.cp-scope[aria-pressed="true"]{background:var(--fairway);border-color:var(--fairway);color:var(--fairway-ink)}
.cp-list{max-height:min(320px,45vh);overflow-y:auto;margin:0;padding:4px 0;list-style:none;overscroll-behavior:contain}
.cp-head{padding:8px 12px 4px;font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.cp-opt{display:flex;gap:8px;align-items:baseline;padding:7px 12px;cursor:pointer;line-height:1.3}
.cp-opt[aria-selected="true"],.cp-opt:hover{background:var(--surface-2);box-shadow:inset 3px 0 0 var(--flag)}
.cp-nm{font-weight:500;min-width:0;overflow-wrap:anywhere}
.cp-town{font-size:12px;color:var(--muted);margin-left:auto;white-space:nowrap;padding-left:8px}
.cp-cc{font-family:var(--f-mono);font-size:10px;font-weight:700;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 4px;flex:none}
.cp-note{padding:8px 12px;font-size:12px;color:var(--muted);border-top:1px solid var(--line)}
@media (max-width:520px){.cp-town{display:none}}
`;
function injectCss(){ if(document.getElementById("cp-css")) return; const s=document.createElement("style"); s.id="cp-css"; s.textContent=css; document.head.appendChild(s); }

// ---- widget ----
let uid=0;
function attach(input){
  if(!input || input.dataset.cpReady) return;
  input.dataset.cpReady="1";
  injectCss();
  const id="cp-"+(++uid);
  const field=input.parentElement; field.classList.add("cp-wrap");
  input.setAttribute("role","combobox");
  input.setAttribute("aria-autocomplete","list");
  input.setAttribute("aria-expanded","false");
  input.setAttribute("aria-controls",id+"-list");
  input.setAttribute("autocomplete","off");
  if(!input.getAttribute("data-i18n-ph")) input.placeholder=tr("ph");

  const panel=document.createElement("div"); panel.className="cp-panel"; panel.hidden=true;
  const scopes=document.createElement("div"); scopes.className="cp-scopes";
  const list=document.createElement("ul"); list.className="cp-list"; list.id=id+"-list"; list.setAttribute("role","listbox");
  const note=document.createElement("div"); note.className="cp-note";
  panel.append(scopes,list,note);
  field.appendChild(panel);

  let scope="all", opts=[], active=-1;

  function renderScopes(){
    scopes.replaceChildren(...SCOPES.map(s=>{
      const b=document.createElement("button"); b.type="button"; b.className="cp-scope"; b.textContent=tr(s);
      b.setAttribute("aria-pressed",String(s===scope));
      b.addEventListener("mousedown",e=>e.preventDefault()); // keep focus in the input
      b.addEventListener("click",()=>{ scope=s; renderScopes(); renderList(); list.scrollTop=0; input.focus(); });
      return b;
    }));
  }
  function renderList(){
    const groups=listFor(scope,input.value);
    const nodes=[]; opts=[]; active=-1;
    let total=0, shown=0;
    groups.forEach(g=>{
      total+=g.items.length;
      const cap = g.head ? g.items.length : MAX_RESULTS;
      const items=g.items.slice(0,cap); shown+=items.length;
      if(g.head && items.length){ const hd=document.createElement("li"); hd.className="cp-head"; hd.setAttribute("role","presentation"); hd.textContent=g.head; nodes.push(hd); }
      items.forEach(c=>{
        const li=document.createElement("li"); li.className="cp-opt"; li.setAttribute("role","option"); li.id=id+"-o"+opts.length;
        const cc=document.createElement("span"); cc.className="cp-cc"; cc.textContent=FLAG[c.cc];
        const nm=document.createElement("span"); nm.className="cp-nm"; nm.textContent=c.name;
        li.append(cc,nm);
        if(c.town){ const tw=document.createElement("span"); tw.className="cp-town"; tw.textContent=c.town; li.appendChild(tw); }
        li.addEventListener("mousedown",e=>e.preventDefault());
        li.addEventListener("click",()=>pick(c));
        opts.push({el:li,club:c}); nodes.push(li);
      });
    });
    list.replaceChildren(...nodes);
    if(!total) note.textContent=tr("none");
    else if(shown<total) note.textContent=tr("more",{n:total-shown});
    else note.textContent=tr("hint");
    input.removeAttribute("aria-activedescendant");
  }
  function setActive(i){
    if(!opts.length) return;
    if(active>=0) opts[active].el.setAttribute("aria-selected","false");
    active=(i+opts.length)%opts.length;
    const o=opts[active].el; o.setAttribute("aria-selected","true");
    input.setAttribute("aria-activedescendant",o.id); o.scrollIntoView({block:"nearest"});
  }
  function open(){ if(!panel.hidden) return; renderScopes(); renderList(); panel.hidden=false; input.setAttribute("aria-expanded","true"); }
  function close(){ panel.hidden=true; input.setAttribute("aria-expanded","false"); input.removeAttribute("aria-activedescendant"); }
  function pick(c){ input.value=c.name; input.dispatchEvent(new Event("change",{bubbles:true})); close(); }

  input.addEventListener("focus",open);
  input.addEventListener("click",open);
  input.addEventListener("input",()=>{ if(panel.hidden) open(); else renderList(); });
  input.addEventListener("blur",()=>setTimeout(close,120));
  input.addEventListener("keydown",e=>{
    if(e.key==="ArrowDown"){ e.preventDefault(); open(); setActive(active+1); }
    else if(e.key==="ArrowUp"){ e.preventDefault(); open(); setActive(active-1); }
    else if(e.key==="Enter" && !panel.hidden && active>=0){ e.preventDefault(); pick(opts[active].club); }
    else if(e.key==="Escape" && !panel.hidden){ e.preventDefault(); e.stopPropagation(); close(); }
  });
  // The form's reset() clears the value; just make sure the panel closes.
  if(input.form) input.form.addEventListener("reset",close);
}

function scan(){ TARGETS.forEach(id=>attach(document.getElementById(id))); }
// The profile dialog is built on demand, so watch for it.
document.addEventListener("focusin",e=>{ if(e.target && TARGETS.includes(e.target.id)) attach(e.target); }, true);
if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",scan); else scan();
window.ClubPicker={attach, data};
})();
