#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('gateway/web/app.js', 'utf8');
const start = source.indexOf('function workspaceHostsFrom(');
const end = source.indexOf('const workspaces = {', start);
assert(start >= 0 && end > start);
const context = vm.createContext({});
vm.runInContext(source.slice(start, end), context);

const hosts = context.workspaceHostsFrom({hosts: [
  {host_id: 'local', kind: 'local', label: 'This Mac', detail: null, connected: true, projects: [
    {project_id: 'p1', host_id: 'local', paths: ['/Users/dev/zedlink'], name: 'zedlink', open: true, threads: [
      {thread_id: 't1', title: 'Fix CI', agent: 'Zed Agent', updated_at: '2026-11-26T10:00:00Z', loaded: true},
      {thread_id: null, title: 'Draft', agent: 'Zed Agent', updated_at: '2026-11-26T09:00:00Z', loaded: false},
      {thread_id: 't2', title: null, agent: 'Codex', updated_at: '2026-11-20T09:00:00Z', loaded: false},
    ]},
  ]},
  {host_id: 'ssh-1', kind: 'ssh', label: 'hotbot2', detail: 'dev0@hotbot2:2222', connected: false, projects: [
    {project_id: 'p2', host_id: 'ssh-1', paths: ['/home/dev0/prj'], name: '', open: false, threads: []},
  ]},
  {kind: 'ssh', label: 'missing id'},
]});
assert.equal(hosts.length, 2);
assert.deepEqual(hosts[0].projects[0].threads.map((thread) => thread.thread_id), ['t1', 't2']);
assert.equal(hosts[0].projects[0].threads[1].title, '');
assert.equal(hosts[1].detail, 'dev0@hotbot2:2222');
assert.equal(hosts[1].projects[0].name, '/home/dev0/prj');
assert.equal(context.findWorkspaceProject(hosts, 'ssh-1', ['/home/dev0/prj']).project_id, 'p2');
assert.equal(context.findWorkspaceProject(hosts, 'ssh-1', ['/home/dev0']), null);
assert.throws(() => context.workspaceHostsFrom({}));

assert.deepEqual(context.sortedDirectoryEntries([
  {name: 'b.txt', is_dir: false}, {name: 'src', is_dir: true}, {name: '..', is_dir: true}, {name: 'Apps', is_dir: true},
]).map((entry) => entry.name), ['Apps', 'src', 'b.txt']);

assert.equal(context.parentDirectory('/home/dev0/prj'), '/home/dev0');
assert.equal(context.parentDirectory('/home/'), '/');
assert.equal(context.parentDirectory('/home'), '/');
assert.equal(context.parentDirectory('/'), null);
assert.equal(context.parentDirectory('C:\\Users\\dev'), 'C:\\Users');
assert.equal(context.parentDirectory('C:\\Users'), 'C:\\');
assert.equal(context.parentDirectory('C:\\'), null);
assert.equal(context.childDirectory('/', 'home'), '/home');
assert.equal(context.childDirectory('/home/dev0', 'prj'), '/home/dev0/prj');
assert.equal(context.childDirectory('C:\\Users', 'dev'), 'C:\\Users\\dev');

assert.equal(context.sshCommandFrom('  ssh dev0@hotbot2 -p 2222 '), 'ssh dev0@hotbot2 -p 2222');
assert.equal(context.sshCommandFrom('ssh'), '');
assert.equal(context.sshCommandFrom('dev0@hotbot2'), 'ssh dev0@hotbot2');
assert.equal(context.sshCommandFrom('   '), '');

const now = Date.parse('2026-11-26T12:00:00Z');
assert.equal(context.historyAge('2026-11-26T11:30:00Z', now), '30m ago');
assert.equal(context.historyAge('2026-11-26T02:00:00Z', now), '10h ago');
assert.equal(context.historyAge('2026-11-20T12:00:00Z', now), '6d ago');
assert.equal(context.historyAge('not a date', now), '');
console.log('PASS: workspace list normalization skips drafts and invalid hosts, folder entries sort directories first, parent/child paths handle POSIX and Windows roots, SSH commands are normalized');
