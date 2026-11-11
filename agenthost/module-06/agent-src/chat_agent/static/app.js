'use strict';
const $ = id => document.getElementById(id);
let conversation = crypto.randomUUID(), history = [], lastAction = null;
let busy = false, questionIndex = null, questionDraft = '';
let connectedWorkspace = null;
function resetQuestionNavigation() { questionIndex = null; questionDraft = ''; }
let scrollPending = false;
function scrollToLatest() {
  if (scrollPending) return;
  scrollPending = true;
  requestAnimationFrame(() => {
    scrollPending = false;
    $('progress').scrollTop = $('progress').scrollHeight;
    // Include progress and the sticky composer's normal-flow space, not just the last message.
    const scroller = document.scrollingElement;
    scroller.scrollTop = scroller.scrollHeight;
  });
}
function renderMarkdown(container, text) {
  let code = null;
  for (const line of String(text).split('\n')) {
    if (line.startsWith('```')) {
      if (code) { container.append(code); code = null; }
      else code = document.createElement('pre');
      continue;
    }
    if (code) { code.textContent += line + '\n'; continue; }
    const heading = line.match(/^#{1,6}\s+(.*)/);
    const element = document.createElement(heading ? 'h3' : 'p');
    element.textContent = heading ? heading[1] : line;
    container.append(element);
  }
  if (code) container.append(code);
}
function add(role, text, run, charts = run?.charts, chartErrors = run?.errors) {
  const div = document.createElement('article'); div.className = 'msg ' + role;
  const label = document.createElement('div'); label.className = 'role'; label.textContent = role === 'user' ? 'You' : 'Agent';
  div.append(label); renderMarkdown(div, text);
  StudioCharts.render(div, charts);
  for (const error of chartErrors || []) {
    if (error.worker !== 'prepare_charts') continue;
    const warning = document.createElement('p'); warning.className = 'chart-error';
    warning.setAttribute('role', 'alert'); warning.textContent = error.code + ': ' + error.message;
    div.append(warning);
  }
  if (run) {
    const detail = document.createElement('details'), summary = document.createElement('summary');
    summary.textContent = 'Evidence, SQL and execution plan'; detail.append(summary);
    const pre = document.createElement('pre');
    pre.textContent = JSON.stringify({mode:run.mode, plan:run.plan, documents:run.rag_result,
      query:run.sql_result, review:run.review, errors:run.errors}, null, 2);
    detail.append(pre); div.append(detail);
  }
  $('chat').append(div); scrollToLatest();
}
function storageKey() { return 'studio-history-' + connectedWorkspace; }
function saveHistory() {
  history = history.slice(-30);
  try { sessionStorage.setItem(storageKey(), JSON.stringify({conversation,history})); }
  catch { $('error').textContent = 'History could not be saved in this browser. Completed runs remain on the server.'; }
}
function loadHistory() {
  resetQuestionNavigation();
  lastAction = null; $('retry').hidden = true; $('upload-queue').replaceChildren(); $('file').value = '';
  try {
    const saved = JSON.parse(sessionStorage.getItem(storageKey()) || 'null');
    conversation = saved?.conversation || crypto.randomUUID();
    history = Array.isArray(saved?.history) ? saved.history.slice(-30) : [];
    $('chat').replaceChildren();
    history.forEach(h => add(h.role,h.text,undefined,h.charts,h.chartErrors));
  } catch {
    history = []; conversation = crypto.randomUUID(); $('chat').replaceChildren();
    $('error').textContent = 'Local history is invalid or unavailable. Start a new conversation.';
  }
}
async function api(path, options = {}) {
  const response = await fetch('/api' + path, options);
  const result = await response.json();
  if (!response.ok) throw Object.assign(new Error(result.message || 'Request failed'), {
    code:result.code, retryable:result.retryable === true
  });
  return result;
}
function updateControls() {
  document.querySelectorAll('button,select,#file').forEach(control => control.disabled = busy);
  for (const id of ['clear','sources','upload','file','send'])
    $(id).disabled = busy || !connectedWorkspace;
  $('q').disabled = !connectedWorkspace;
  $('connect').disabled = busy || !$('workspace').value;
}
async function action(fn) {
  if (busy) return;
  busy = true;
  lastAction = fn; $('error').textContent = ''; $('retry').hidden = true;
  updateControls();
  try { await fn(); } catch (error) {
    $('error').textContent = error.message; $('retry').hidden = false;
    if (!connectedWorkspace) $('connection').textContent = 'Not connected.';
  }
  finally {
    busy = false;
    updateControls();
    scrollToLatest();
  }
}
function workspacePath() {
  if (!connectedWorkspace || connectedWorkspace !== $('workspace').value)
    throw new Error('Select a session and click Connect first.');
  return '/workspaces/' + connectedWorkspace;
}
const progressAgents = {
  receive_request:'Orchestrator', classify_and_plan:'Orchestrator', direct_llm:'Orchestrator',
  process_uploaded_file:'Orchestrator → Data Processing Agent',
  rag_search:'Orchestrator → RAG Agent', sql_query:'Orchestrator → SQL Agent',
  extract:'Data Processing Agent', chunking:'Data Processing Agent', embedding:'Data Processing Agent',
  storage:'Data Processing Agent', retrieve:'RAG Agent', query:'SQL Agent',
  aggregate_results:'Orchestrator', prepare_charts:'Orchestrator', generate_final_response:'Orchestrator',
  review_evidence:'Orchestrator', revision:'Orchestrator', handle_error:'Orchestrator',
  emit_response:'Orchestrator',
};
function formatProgress(event) {
  const agent = Object.hasOwn(progressAgents,event.stage) ? progressAgents[event.stage] : 'Workflow';
  return `[${agent}] ${event.message}`;
}
async function monitor(path, started, label = '') {
  const seconds = Number(started.poll_timeout_seconds);
  const deadline = Date.now() + (Number.isFinite(seconds) && seconds > 0 ? seconds : 660) * 1000;
  let reconnects = 0;
  while (Date.now() < deadline) {
    let run;
    try {
      run = await api(path + '/runs/' + started.run_id);
      reconnects = 0;
    } catch (error) {
      if (!error.retryable || reconnects >= 3 || Date.now() >= deadline) throw error;
      reconnects++;
      $('progress').textContent = [label,
        `[Chat Agent → Orchestrator] Status connection interrupted; retrying (${reconnects}/3)...`]
        .filter(Boolean).join('\n');
      scrollToLatest();
      await new Promise(resolve => setTimeout(resolve,Math.min(reconnects*1000,deadline-Date.now())));
      continue;
    }
    const progress = [label, ...(run.progress_events || []).map(formatProgress)].filter(Boolean).join('\n');
    if ($('progress').textContent !== progress) {
      $('progress').textContent = progress;
      scrollToLatest();
    }
    if (run.status !== 'running') {
      if (run.error) throw Object.assign(new Error(run.error.message), {runEnded:true});
      let text;
      if (run.processing_result) text = JSON.stringify(run.processing_result,null,2);
      else text = ['retrieved_evidence','calculated_facts','interpretation','recommendations','limitations']
        .filter(k => run.answer?.[k]).map(k => '## ' + k.replaceAll('_',' ') + '\n' + run.answer[k]).join('\n\n');
      if (!text) throw Object.assign(new Error('Workflow ended without an answer.'), {runEnded:true});
      add('bot',text,run);
      history.push({role:'bot',text,charts:run.charts,
        chartErrors:(run.errors || []).filter(e => e.worker === 'prepare_charts')}); saveHistory();
      $('meta').textContent = 'Status: ' + run.status + (run.mode ? ' | ' + run.mode : '');
      if (run.status === 'failed') throw Object.assign(
        new Error('Evidence review or required data operations failed. See evidence details.'), {runEnded:true});
      return run;
    }
    await new Promise(resolve => setTimeout(resolve,1000));
  }
  throw new Error('Polling timed out. The run may still be processing; run ID: ' + started.run_id);
}
function disconnect(forgetRetry = true) {
  connectedWorkspace = null; history = []; conversation = crypto.randomUUID();
  resetQuestionNavigation();
  if (forgetRetry) { lastAction = null; $('retry').hidden = true; $('error').textContent = ''; }
  $('chat').replaceChildren(); $('upload-queue').replaceChildren();
  $('file').value = ''; $('q').value = ''; $('progress').textContent = ''; $('meta').textContent = '';
  $('connection').textContent = 'Select a session and click Connect.';
  updateControls();
}
async function refresh(selectedId = '') {
  disconnect(false);
  $('connection').textContent = 'Loading sessions...';
  const items = await api('/workspaces'); $('workspace').replaceChildren();
  items.forEach(w => { const o = document.createElement('option'); o.value=w.id; o.textContent=w.name; $('workspace').append(o); });
  $('workspace').value = items.some(w => w.id === selectedId) ? selectedId : items[0]?.id || '';
  $('connection').textContent = items.length ? 'Select a session and click Connect.' : 'No sessions yet. Create one to begin.';
}
async function connectWorkspace() {
  const id = $('workspace').value;
  disconnect(false);
  if (!id) throw new Error('Create or select a session first.');
  const workspace = await api('/workspaces/' + id);
  if (workspace.id !== id) throw new Error('The server returned a different session. Refresh and retry.');
  connectedWorkspace = id;
  loadHistory();
  $('connection').textContent = 'Connected: ' + workspace.name;
}
$('connect').onclick = () => action(connectWorkspace);
$('create').onclick = () => action(async () => {
  const workspace = await api('/workspaces',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:$('name').value})});
  await refresh(workspace.id);
});
$('workspace').onchange = () => disconnect();
$('clear').onclick = () => { sessionStorage.removeItem(storageKey()); loadHistory(); };
$('sources').onclick = () => action(async () => add('bot',JSON.stringify(await api(workspacePath()+'/sources'),null,2)));
$('upload').onclick = () => {
  const entries = Array.from($('file').files).map(file => ({file,started:null,done:false,status:'Pending'}));
  let path, uploadConversation;
  const renderQueue = () => {
    $('upload-queue').replaceChildren();
    entries.forEach(entry => {
      const item = document.createElement('li');
      item.textContent = entry.file.name + ' — ' + entry.status;
      $('upload-queue').append(item);
    });
  };
  return action(async () => {
    if (!entries.length) throw new Error('Select one or more files first.');
    if (!path) { path = workspacePath(); uploadConversation = conversation; }
    if (path !== workspacePath() || uploadConversation !== conversation)
      throw new Error('The session or conversation changed. Select the files again.');
    for (const [index,entry] of entries.entries()) {
      if (entry.done) continue;
      const label = `File ${index+1}/${entries.length}: ${entry.file.name}`;
      $('progress').textContent = '[Chat UI → Chat Agent] ' + label;
      entry.status = entry.started ? 'Processing' : 'Uploading'; renderQueue(); scrollToLatest();
      try {
        if (!entry.started) {
          const form = new FormData(); form.append('file',entry.file); form.append('conversation_id',uploadConversation);
          entry.started = await api(path+'/files',{method:'POST',body:form});
        }
        entry.status = 'Processing'; renderQueue();
        const run = await monitor(path,entry.started,'[Chat Agent → Orchestrator] ' + label);
        entry.done = true; entry.status = run.status === 'partial' ? 'Completed with warnings' : 'Completed';
        renderQueue();
      } catch (error) {
        if (error.runEnded) entry.started = null;
        entry.status = 'Needs retry'; renderQueue();
        throw new Error(label + ': ' + error.message);
      }
    }
    $('meta').textContent = `Upload queue completed: ${entries.length}/${entries.length}`;
    $('file').value = '';
  });
};
function send() {
  if (busy) return;
  const message = $('q').value.trim();
  if (!message) return;
  return action(async () => {
    const path = workspacePath();
    const context = history.slice(-6).map(h=>h.text.slice(0,3000));
    add('user',message); history.push({role:'user',text:message}); saveHistory(); $('q').value='';
    resetQuestionNavigation();
    $('progress').textContent = '[Chat UI → Chat Agent] Sending your request...'; scrollToLatest();
    await monitor(path,await api(path+'/chat',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({message,conversation_id:conversation,recent_context:context})}),
    '[Chat Agent → Orchestrator] Request accepted.');
  });
}
$('send').onclick = send;
$('q').oninput = resetQuestionNavigation;
$('q').onkeydown = e => {
  if (e.isComposing) return;
  if (e.key==='Enter'&&!e.shiftKey&&!$('send').disabled) { e.preventDefault(); return send(); }
  if (!['ArrowUp','ArrowDown'].includes(e.key) || e.shiftKey || e.ctrlKey || e.altKey || e.metaKey) return;
  const input = $('q'), up = e.key === 'ArrowUp';
  if (input.selectionStart !== input.selectionEnd) return;
  if (up ? input.value.slice(0,input.selectionStart).includes('\n') : input.value.slice(input.selectionEnd).includes('\n')) return;
  const questions = history.filter(h => h.role === 'user').map(h => h.text);
  if (!questions.length || (!up && questionIndex === null)) return;
  e.preventDefault();
  if (questionIndex === null) { questionDraft = input.value; questionIndex = questions.length; }
  questionIndex = Math.max(0, Math.min(questions.length, questionIndex + (up ? -1 : 1)));
  input.value = questionIndex === questions.length ? questionDraft : questions[questionIndex];
  input.setSelectionRange(input.value.length,input.value.length);
  if (questionIndex === questions.length) resetQuestionNavigation();
};
$('retry').onclick = () => { if(lastAction) return action(lastAction); };
updateControls();
document.addEventListener('DOMContentLoaded', () => action(refresh), {once:true});
