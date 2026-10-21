// Usage: node render-check.cjs <decisions.html>, run from a directory whose node_modules holds puppeteer.
const path = require("node:path"), fs = require("node:fs");
if (!process.argv[2]) { console.error("usage: node render-check.cjs <decisions.html>"); process.exit(2); }
const local = path.join(process.cwd(), "node_modules", "puppeteer");
const puppeteer = require(fs.existsSync(local) ? local : "puppeteer");
(async () => {
  const browser = await puppeteer.launch({ headless: true, args: ["--no-sandbox"] });
  const page = await browser.newPage();
  const errs = []; page.on("pageerror", e => errs.push("PAGEERROR " + e.message)); page.on("console", m => { if (m.type() === "error") errs.push("CONSOLE " + m.text()); });
  await page.goto("file://" + path.resolve(process.argv[2]), { waitUntil: "load", timeout: 60000 });
  await new Promise(r => setTimeout(r, 1500));
  const info = await page.evaluate(() => ({ items: document.querySelectorAll("article.item").length, toc: document.querySelectorAll("#toc a").length, pages: document.querySelectorAll("[id^=page-]").length, hidden: [...document.querySelectorAll("[id^=page-]")].filter(e => e.hidden).length, cnt: document.getElementById("cnt")?.textContent, bodyLen: document.body.innerHTML.length }));
  console.log(JSON.stringify(info)); console.log(errs.slice(0, 5).join("\n")); await browser.close();
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
