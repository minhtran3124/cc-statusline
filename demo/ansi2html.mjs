// Minimal ANSI -> HTML for statusline.sh output: 24-bit foreground, dim, reset.
import { readFileSync } from 'node:fs';

const escapeHtml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
// Emoji a terminal draws two cells wide; pinned to 2ch so columns line up.
const wide = /(\p{Emoji_Presentation}|\p{Extended_Pictographic}️)/gu;

let style = {};
let html = '';
for (const part of readFileSync(0, 'utf8').split(/(\x1b\[[0-9;]*m)/)) {
  const sgr = part.match(/^\x1b\[([0-9;]*)m$/);
  if (sgr) {
    const codes = sgr[1].split(';').map(Number);
    if (codes[0] === 0) style = {};
    else if (codes[0] === 2) style.dim = true;
    else if (codes[0] === 38 && codes[1] === 2) style.color = `rgb(${codes[2]},${codes[3]},${codes[4]})`;
    continue;
  }
  if (!part) continue;
  const css = [style.color && `color:${style.color}`, style.dim && 'opacity:.5'].filter(Boolean).join(';');
  html += `<span style="${css}">${escapeHtml(part).replace(wide, '<span class="w2">$1</span>')}</span>`;
}
process.stdout.write(html);
