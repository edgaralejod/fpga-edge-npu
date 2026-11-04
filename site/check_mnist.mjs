// Checks the site's in-browser network (public/mnist.js) against the
// bit-exact model: every one of the 10 000 test predictions must match.
//
//   node site/check_mnist.mjs [build/mnist]
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { join } from "node:path";
import { parseModel, infer } from "./public/mnist.js";

const dir = process.argv[2] || "build/mnist";
const buf = readFileSync(join(dir, "model.bin"));
const m = parseModel(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const imgs = gunzipSync(readFileSync(join(dir, "t10k-images-idx3-ubyte.gz")));
const labels = gunzipSync(readFileSync(join(dir, "t10k-labels-idx1-ubyte.gz")));
const expected = readFileSync(join(dir, "expected.bin"));

let diff = 0, correct = 0;
for (let i = 0; i < 10000; i++) {
  const { pred } = infer(m, imgs.subarray(16 + i * 784, 16 + (i + 1) * 784));
  if (pred !== expected[i]) diff++;
  if (pred === labels[8 + i]) correct++;
}
console.log(`browser network: ${diff} of 10000 predictions differ from the bit-exact model, accuracy ${(correct / 100).toFixed(2)} %`);
process.exit(diff ? 1 : 0);
