// fat32.test.js -- the card's file system, on a RAM card
import test from 'node:test'
import assert from 'node:assert/strict'
import { Fat32, memoryDevice, mkfs } from '../src/fat32.js'

const card = async () => new Fat32(memoryDevice(mkfs(8 * 1024 * 1024))).mount()
const bytes = (n, v) => new Uint8Array(n).fill(v)

test('uploading the same name twice replaces the file, it does not duplicate it', async () => {
  const fs = await card()
  for (const name of ['GAME.TAP', 'Manic Miner (1983).tap']) {
    await fs.create(name, bytes(3000, 1))
    await fs.create(name, bytes(5000, 2))
  }
  const files = await fs.list()
  assert.deepEqual(files.map((f) => [f.name, f.size]), [['GAME.TAP', 5000], ['Manic Miner (1983).tap', 5000]])
  const f = await fs.find('Manic Miner (1983).tap')
  assert.equal(f.short, 'MANICM~1TAP')
  assert.deepEqual(await fs.readFile(f), bytes(5000, 2))
  // the first copy's clusters went back to the free pool
  assert.ok(await fs.extent(f))
})

test('remove deletes by the 8.3 name the board lists, LFN entries and clusters too', async () => {
  const fs = await card()
  await fs.create('Jetpac.tap', bytes(2000, 3))
  await fs.create('KEEP.TAP', bytes(600, 4))
  const f = await fs.find('JETPAC.TAP')   // the board's 8.3 form
  const first = f.cluster
  await fs.remove(f)
  assert.deepEqual((await fs.list()).map((x) => x.name), ['KEEP.TAP'])
  assert.equal(await fs.next(first), 0)
})
