/* Fix problems panel. Works read-only when the report is opened as a saved file. */
(function(){
var data=JSON.parse(document.getElementById('pctk-data').textContent);
var strings=data.strings||{};
var sparkollen=data.theme==='Sparkollen';
var cfg=window.PCTK||null;
var live=!!cfg&&location.protocol.indexOf('http')===0;
var canFix=live&&(cfg.admin||cfg.dryRun);
var panel=document.getElementById('fix-panel');
/* Translates English text for the active theme; extra arguments fill {0}, {1}, ... */
function t(text){var s=Object.prototype.hasOwnProperty.call(strings,text)?strings[text]:text,a=arguments;
 return s.replace(/\{(\d+)\}/g,function(m,i){var v=a[+i+1];return v==null?m:v})}
var groups=[
 {id:'recommended',title:t('Recommended'),text:t('Safe changes that help most computers. A restore point is created first, so everything can be undone.')},
 {id:'startup',title:t('Stop apps from starting with Windows'),text:t('The apps still work when you open them yourself. Pre-selected apps are rarely needed at startup. Unsure about an app? Leave it unticked.'),bulk:true},
 {id:'programs',title:t('Remove unwanted programs'),text:t('An uninstall window opens for each program. Follow its steps.')},
 {id:'extra',title:t('Optional extras'),text:t('Only if you want them.')}];
var pillClass={'Keep':'good','Can be disabled':'warn','Optional':'info'};
var logEl=null,stateEl=null,trailEl=null,pawCount=0;

function el(tag,cls,text){var e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
function svgUse(id,cls){var ns='http://www.w3.org/2000/svg',s=document.createElementNS(ns,'svg'),u=document.createElementNS(ns,'use');
 u.setAttribute('href','#'+id);s.appendChild(u);s.setAttribute('class',cls);s.setAttribute('aria-hidden','true');return s}
function button(text,cls,onclick){var b=el('button',cls,text);b.type='button';b.onclick=onclick;return b}
function note(cls,text){return el('div','note '+cls,text)}
function api(method,path,body){
 var o={method:method,headers:{}};
 if(method==='POST'){o.headers['X-PCTK-Token']=cfg.token;o.headers['Content-Type']='application/json';o.body=JSON.stringify(body||{})}
 return fetch('/'+cfg.token+'/'+path,o).then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.Error||t('Error {0}',r.status));return j})})}
function selected(){return Array.prototype.map.call(panel.querySelectorAll('input[type=checkbox]:checked'),function(i){return i.value})}
function update(){var b=document.getElementById('fix-btn');if(!b)return;var n=selected().length;
 b.textContent=n?t('Fix selected ({0})',n):t('Select something to fix');if(canFix)b.disabled=!n}

function renderForm(){
 panel.innerHTML='';logEl=null;
 if(data.driveBlocked){panel.appendChild(note('bad',data.driveMessage));return}
 if(!live)panel.appendChild(note('info',t('This is a saved copy of the report, so nothing can be fixed from here. To fix problems, double-click "Starta Spårkollen" in the PC Toolkit folder.')));
 else if(!canFix)panel.appendChild(note('warn',t('PC Toolkit was not given administrator permission, so it cannot fix anything. Close the PC Toolkit window, start it again and click Yes when Windows asks.')));
 else if(cfg.dryRun)panel.appendChild(note('info',t('Test mode: nothing will actually be changed.')));
 groups.forEach(function(g){
  var items=data.options.filter(function(o){return o.Group===g.id});if(!items.length)return;
  if(g.id==='startup'){var rank={'Can be disabled':0,'Optional':1,'Keep':3};
   items.sort(function(a,b){var ra=a.Tag in rank?rank[a.Tag]:2,rb=b.Tag in rank?rank[b.Tag]:2;return ra-rb||a.Title.localeCompare(b.Title)})}
  var box=el('div','fix-group'),head=el('div','fix-head');head.appendChild(el('h3',null,g.title));
  if(g.bulk&&canFix){
   head.appendChild(button(t('Select suggested'),'link',function(){box.querySelectorAll('input').forEach(function(i){i.checked=i.getAttribute('data-default')==='1'});update()}));
   head.appendChild(button(t('Select none'),'link',function(){box.querySelectorAll('input').forEach(function(i){i.checked=false});update()}))}
  box.appendChild(head);box.appendChild(el('p','hint',g.text));
  items.forEach(function(o){
   var row=el('label','opt'),cb=el('input');cb.type='checkbox';cb.value=o.Id;cb.checked=!!o.Default;cb.disabled=!canFix;
   cb.setAttribute('data-default',o.Default?'1':'0');cb.onchange=update;
   var body=el('div','opt-body'),title=el('div','opt-title',o.Title);
   if(o.Tag){title.appendChild(document.createTextNode(' '));title.appendChild(el('span','pill '+(pillClass[o.Tag]||'muted'),t(o.Tag.replace(/\s*\(.*\)$/,''))))}
   body.appendChild(title);if(o.Description)body.appendChild(el('div','opt-desc'+(g.id==='startup'?' mono':''),o.Description));
   row.appendChild(cb);row.appendChild(body);if(o.Duration)row.appendChild(el('span','opt-time',o.Duration));box.appendChild(row)});
  panel.appendChild(box)});
 if(!live)return;
 var bar=el('div','fix-bar'),fix=button(t('Fix selected'),'primary',start);fix.id='fix-btn';fix.disabled=!canFix;bar.appendChild(fix);
 bar.appendChild(el('span','hint grow',t('Close games and save your work first. You can follow the progress here.')));
 bar.appendChild(button(t('Close without fixing'),'',finish));
 panel.appendChild(bar);update()}

function start(){var s=selected();if(!s.length)return;
 if(!confirm(t('Fix the {0} selected item(s) now?',s.length)+'\n\n'+t('A restore point is created first. Close games and save your work.')))return;
 api('POST','repair',{Options:s}).then(function(){showProgress();poll()}).catch(function(e){alert(e.message)})}

function showProgress(){panel.innerHTML='';var h=el('div','progress-head');h.appendChild(el('span','spinner'));
 stateEl=el('strong',null,t('Fixing problems...'));h.appendChild(stateEl);panel.appendChild(h);
 if(sparkollen){trailEl=el('div','trail');trailEl.appendChild(svgUse('dog-tracker','runner'));panel.appendChild(trailEl);pawCount=0}
 panel.appendChild(el('p','hint',t('Do not turn off the computer. Uninstall windows may open; follow their steps. Some steps take a long time without visible progress.')));
 logEl=el('pre','log');panel.appendChild(logEl)}
/* The dog follows the track: one more paw print per status update, starting over at the end. */
function stepTrail(){if(!trailEl)return;
 if(pawCount>=24){Array.prototype.slice.call(trailEl.querySelectorAll('.paw')).forEach(function(p){p.remove()});pawCount=0}
 var left=2+pawCount*4,paw=svgUse('paw','paw');paw.style.left=left+'%';paw.style.bottom=(pawCount%2?10:3)+'px';
 trailEl.insertBefore(paw,trailEl.firstChild);trailEl.querySelector('.runner').style.left=(left+4)+'%';pawCount++}
function duration(s){var m=Math.floor(s/60);return m?t('{0} min {1} s',m,s%60):t('{0} s',s)}
function poll(){api('GET','status').then(function(st){
  if(st.State==='idle')return;
  if(!logEl)showProgress();
  var bottom=logEl.scrollTop+logEl.clientHeight>=logEl.scrollHeight-20;
  logEl.textContent=(st.Log||[]).join('\n');if(bottom)logEl.scrollTop=logEl.scrollHeight;
  if(st.State==='running'){stateEl.textContent=t('Fixing problems... ({0})',duration(st.ElapsedSeconds));stepTrail();setTimeout(poll,1500)}
  else showResult(st.Result)
 }).catch(function(){if(stateEl){stateEl.textContent=t('Lost contact with PC Toolkit. Is its window still open?');setTimeout(poll,5000)}})}

function list(title,items,cls){if(!items||!items.length)return null;var d=el('div','res '+cls);d.appendChild(el('h3',null,title));
 var ul=el('ul');items.forEach(function(i){ul.appendChild(el('li',null,i))});d.appendChild(ul);return d}
function confetti(){if(window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches)return;
 var box=el('div','confetti');box.setAttribute('aria-hidden','true');for(var i=0;i<36;i++){var b=svgUse('bone','');b.style.left=Math.random()*100+'%';
  b.style.animationDuration=(2.2+Math.random()*2)+'s';b.style.animationDelay=(Math.random()*.8)+'s';box.appendChild(b)}
 document.body.appendChild(box);setTimeout(function(){box.remove()},5500)}
function showResult(r){
 var log=logEl;panel.innerHTML='';trailEl=null;
 if(sparkollen&&!r.Stopped)panel.appendChild(svgUse('dog-sitter','result-dog dog-sitter'));
 var h=el('div','progress-head');h.appendChild(el('span',r.Stopped?'icon bad':'icon good',r.Stopped?'!':'\u2713'));
 h.appendChild(el('strong',null,r.Stopped||(r.DryRun?t('Test run finished - nothing was changed'):t('Done!'))));panel.appendChild(h);
 var would=r.Planned||[];
 [list(t('What was done'),r.Completed,'good'),list(t('Would be done (test mode)'),would,'good'),list(t('Skipped'),r.Skipped,'warn'),list(t('Things to do yourself'),r.Manual,'info')].forEach(function(x){if(x)panel.appendChild(x)});
 var bar=el('div','fix-bar');
 if(r.RestartRecommended){
  panel.appendChild(note('warn',t('Restart the computer to finish. Choose Restart, not Shut down. Run PC Toolkit again afterwards to see the difference.')));
  bar.appendChild(button(t('Restart now'),'primary',function(){if(!confirm(t('Restart the computer in 30 seconds? Save your work first.')))return;
   api('POST','restart').then(function(x){panel.innerHTML='';panel.appendChild(note('info',x.DryRun?t('Test mode: the computer would restart now.'):t('The computer restarts in 30 seconds. Run PC Toolkit again afterwards to see the difference.')))}).catch(function(e){alert(e.message)})}))}
 bar.appendChild(button(t('Finish'),r.RestartRecommended?'':'primary',finish));
 bar.appendChild(button(t('Open report folder'),'',function(){api('POST','open-folder').catch(function(){})}));
 panel.appendChild(bar);
 if(log){var d=el('details','sub');d.appendChild(el('summary',null,t('Show full log')));d.appendChild(log);panel.appendChild(d)}
 if(sparkollen&&!r.Stopped)confetti()}
function finish(){api('POST','shutdown').then(function(){panel.innerHTML='';panel.appendChild(note('good',t('PC Toolkit has closed. You can close this tab.')))}).catch(function(e){alert(e.message)})}

renderForm();
if(live){poll();setInterval(function(){if(!logEl)api('GET','status').catch(function(){})},60000)}
})();