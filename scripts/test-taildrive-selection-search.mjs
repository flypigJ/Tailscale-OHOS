import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const entry = name => ({ name, path: `/tailnet/device/share/${name}`, kind: 'file', size: 1, modifiedAtMs: 0 });

function fixture() {
  const state = {
    entries: [entry('Report.DOC'), entry('photo.png'), entry('notes.doc')],
    selectedPaths: [],
    searchQuery: '',
    sortMode: 'name',
    sortDescending: false,
    selectionMode: true,
    dragSelecting: false
  };
  const controller = new TaildriveSessionController({
    getEntries: () => state.entries,
    getSelectedPaths: () => state.selectedPaths,
    setSelectedPaths: paths => { state.selectedPaths = paths; },
    getSearchQuery: () => state.searchQuery,
    getSortMode: () => state.sortMode,
    isSortDescending: () => state.sortDescending,
    isSelectionMode: () => state.selectionMode,
    setSelectionMode: value => { state.selectionMode = value; },
    isDragSelecting: () => state.dragSelecting,
    setDragSelecting: value => { state.dragSelecting = value; },
    vibrateTouch() {},
    rebuildListDataSource() {},
    publishUiBackState() {},
    stopDragAutoScroll() {}
  });
  for (const name of [
    'displayEntries', 'matchesSearchQuery', 'hiddenSelectedCount', 'selectedEntries',
    'isSelected', 'toggleEntrySelection', 'allVisibleEntriesSelected', 'toggleSelectAll'
  ]) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
}
const paths = state => Array.from(state.selectedPaths).sort();

test('search selection uses case-insensitive trimmed results and leaves source order intact', () => {
  const state = fixture(); const original = state.entries.map(value => value.path);
  state.searchQuery = '  DOC  '; state.toggleSelectAll();
  assert.deepEqual(paths(state), [entry('Report.DOC').path, entry('notes.doc').path].sort());
  assert.equal(state.hiddenSelectedCount(), 0);
  assert.equal(state.allVisibleEntriesSelected(), true);
  assert.deepEqual(state.entries.map(value => value.path), original);
});

test('selecting and deselecting search results preserves and counts earlier hidden selections', () => {
  const state = fixture(); state.toggleEntrySelection(entry('photo.png'));
  state.searchQuery = 'doc'; assert.equal(state.hiddenSelectedCount(), 1);
  state.toggleSelectAll(); assert.equal(state.selectedEntries().length, 3);
  assert.equal(state.hiddenSelectedCount(), 1);
  state.toggleSelectAll();
  assert.deepEqual(paths(state), [entry('photo.png').path]);
  assert.equal(state.hiddenSelectedCount(), 1);
});

test('switching filters updates the scope count without discarding selected files', () => {
  const state = fixture(); state.toggleEntrySelection(entry('photo.png'));
  state.searchQuery = 'doc'; assert.equal(state.hiddenSelectedCount(), 1);
  state.searchQuery = ' PHOTO '; assert.equal(state.hiddenSelectedCount(), 0);
  state.searchQuery = 'missing'; const before = paths(state); state.toggleSelectAll();
  assert.equal(state.hiddenSelectedCount(), 1);
  assert.equal(state.allVisibleEntriesSelected(), false);
  assert.deepEqual(paths(state), before);
});

test('removed or unknown paths do not inflate the selected scope summary', () => {
  const state = fixture(); state.selectedPaths = [entry('Report.DOC').path, '/removed'];
  state.searchQuery = 'photo';
  assert.equal(state.selectedEntries().length, 1);
  assert.equal(state.hiddenSelectedCount(), 1);
  state.entries = state.entries.filter(value => value.name !== 'Report.DOC');
  assert.equal(state.hiddenSelectedCount(), 0);
});

test('clearing a query reveals existing selections without changing them', () => {
  const state = fixture(); state.searchQuery = 'doc'; state.toggleSelectAll(); const before = paths(state);
  state.searchQuery = ''; assert.equal(state.hiddenSelectedCount(), 0);
  assert.deepEqual(paths(state), before);
  assert.equal(state.allVisibleEntriesSelected(), false);
});
